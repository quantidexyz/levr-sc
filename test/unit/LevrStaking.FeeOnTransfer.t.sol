// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrStakedToken_v1} from '../../src/interfaces/ILevrStakedToken_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';

/// @title LevrStaking Fee-on-Transfer Token Tests
/// @notice FIX [C-2]: Tests for fee-on-transfer token protection
contract LevrStakingFeeOnTransferTest is Test, LevrFactoryDeployHelper {
    LevrStaking_v1 staking;
    address stakedToken;
    FeeOnTransferToken feeToken;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        // Deploy factory and get project
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(address(this));
        (ILevrFactory_v1 factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        // Deploy fee-on-transfer token (1% fee)
        feeToken = new FeeOnTransferToken('FeeToken', 'FEE', 100); // 100 = 1% fee

        // Prepare and register
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(feeToken));

        staking = LevrStaking_v1(project.staking);
        stakedToken = project.stakedToken;

        // Fund alice and bob
        feeToken.mint(alice, 1000 ether);
        feeToken.mint(bob, 1000 ether);

        // Approve staking
        vm.prank(alice);
        feeToken.approve(address(staking), type(uint256).max);

        vm.prank(bob);
        feeToken.approve(address(staking), type(uint256).max);
    }

    /// @notice Helper function to whitelist a dynamically created reward token
    function _whitelistRewardToken(address token) internal {
        vm.prank(address(this)); // Test contract is admin of feeToken
        staking.whitelistToken(token);
    }

    /// @notice Test 1: Stake with fee token - receives correct amount
    function test_stakeWithFee_receivesCorrectAmount() public {
        console2.log('\n=== C-2 Test 1: Stake With Fee Token ===');

        uint256 stakeAmount = 100 ether;
        uint256 expectedFee = (stakeAmount * 100) / 10000; // 1% fee
        uint256 expectedReceived = stakeAmount - expectedFee;

        console2.log('Stake amount requested:', stakeAmount);
        console2.log('Expected fee (1%):', expectedFee);
        console2.log('Expected received:', expectedReceived);

        // Alice stakes
        vm.prank(alice);
        staking.stake(stakeAmount);

        // Verify alice received correct shares (based on actualReceived, not requested amount)
        uint256 aliceShares = ILevrStakedToken_v1(stakedToken).balanceOf(alice);
        assertEq(aliceShares, expectedReceived, 'Shares should equal actualReceived');
        console2.log('Alice shares minted:', aliceShares);

        // Verify total staked matches actualReceived
        uint256 totalStaked = staking.totalStaked();
        assertEq(totalStaked, expectedReceived, 'Total staked should equal actualReceived');
        console2.log('Total staked:', totalStaked);

        // Verify escrow balance matches actualReceived
        uint256 escrow = staking.escrowBalance(address(feeToken));
        assertEq(escrow, expectedReceived, 'Escrow should equal actualReceived');
        console2.log('Escrow balance:', escrow);

        console2.log('SUCCESS: Accounting uses actualReceived, not requested amount');
    }

    /// @notice Test 2: Multiple stakes with fee token
    function test_multipleStakes_correctAccounting() public {
        console2.log('\n=== C-2 Test 2: Multiple Stakes Correct Accounting ===');

        // Alice stakes 100
        vm.prank(alice);
        staking.stake(100 ether);

        uint256 aliceShares1 = ILevrStakedToken_v1(stakedToken).balanceOf(alice);
        uint256 expectedAlice = 100 ether - ((100 ether * 100) / 10000); // 99 ether
        assertEq(aliceShares1, expectedAlice, 'Alice shares correct');
        console2.log('Alice first stake shares:', aliceShares1);

        // Bob stakes 200
        vm.prank(bob);
        staking.stake(200 ether);

        uint256 bobShares = ILevrStakedToken_v1(stakedToken).balanceOf(bob);
        uint256 expectedBob = 200 ether - ((200 ether * 100) / 10000); // 198 ether
        assertEq(bobShares, expectedBob, 'Bob shares correct');
        console2.log('Bob stake shares:', bobShares);

        // Verify total
        uint256 totalStaked = staking.totalStaked();
        uint256 expectedTotal = expectedAlice + expectedBob;
        assertEq(totalStaked, expectedTotal, 'Total should be sum of actual received amounts');
        console2.log('Total staked:', totalStaked);
        console2.log('Expected total:', expectedTotal);

        console2.log('SUCCESS: Multiple stakes tracked correctly');
    }

    /// @notice Test 3: Unstake doesn't cause shortfall
    function test_unstake_noShortfall() public {
        console2.log('\n=== C-2 Test 3: Unstake No Shortfall ===');

        // Alice stakes 100
        vm.prank(alice);
        staking.stake(100 ether);

        uint256 aliceShares = ILevrStakedToken_v1(stakedToken).balanceOf(alice);
        uint256 expectedReceived = 100 ether - ((100 ether * 100) / 10000); // 99 ether
        assertEq(aliceShares, expectedReceived);
        console2.log('Alice shares:', aliceShares);

        uint256 escrowBefore = staking.escrowBalance(address(feeToken));
        console2.log('Escrow before unstake:', escrowBefore);

        // Alice unstakes all
        vm.prank(alice);
        staking.unstake(aliceShares, alice);

        // Verify alice received her shares worth of tokens
        uint256 aliceBalance = feeToken.balanceOf(alice);
        console2.log('Alice balance after unstake:', aliceBalance);

        // Note: Unstake will also charge fee on transfer out
        // So alice gets actualReceived - unstakeFee
        // But the important thing is escrow doesn't go negative
        uint256 escrowAfter = staking.escrowBalance(address(feeToken));
        console2.log('Escrow after unstake:', escrowAfter);
        assertEq(escrowAfter, 0, 'Escrow should be empty');

        console2.log('SUCCESS: No shortfall on unstake');
    }

    /// @notice Test 4: Fee token doesn't break reward calculations
    function test_feeToken_rewardsStillWork() public {
        console2.log('\n=== C-2 Test 4: Fee Token Rewards Still Work ===');

        // Alice stakes
        vm.prank(alice);
        staking.stake(100 ether);

        uint256 aliceShares = ILevrStakedToken_v1(stakedToken).balanceOf(alice);
        console2.log('Alice shares:', aliceShares);

        // Accrue some rewards (using normal token, not fee token)
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        _whitelistRewardToken(address(rewardToken));
        rewardToken.mint(address(staking), 10 ether);
        staking.accrueRewards(address(rewardToken));

        // Wait for stream
        vm.warp(block.timestamp + 3 days + 1);

        // Alice claims rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 aliceRewards = rewardToken.balanceOf(alice);
        console2.log('Alice rewards claimed:', aliceRewards);
        assertGt(aliceRewards, 0, 'Should have received rewards');

        console2.log("SUCCESS: Fee token doesn't break reward system");
    }
}

/// @notice Mock ERC20 token with transfer fee
contract FeeOnTransferToken is ERC20 {
    uint256 public feeBps; // Fee in basis points (100 = 1%)
    address private immutable _tokenAdmin;

    constructor(string memory name, string memory symbol, uint256 feeBps_) ERC20(name, symbol) {
        feeBps = feeBps_;
        _tokenAdmin = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function admin() external view returns (address) {
        return _tokenAdmin;
    }

    /// @notice Override transfer to apply fee
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Burn the fee
        _burn(_msgSender(), fee);

        // Transfer the rest
        return super.transfer(to, amountAfterFee);
    }

    /// @notice Override transferFrom to apply fee
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Burn the fee
        _burn(from, fee);

        // Transfer the rest
        _transfer(from, to, amountAfterFee);

        // Update allowance
        uint256 currentAllowance = allowance(from, _msgSender());
        require(currentAllowance >= amount, 'ERC20: insufficient allowance');
        _approve(from, _msgSender(), currentAllowance - amount);

        return true;
    }
}
