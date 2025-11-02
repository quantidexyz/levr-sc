// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {LevrFeeSplitterFactory_v1} from '../../src/LevrFeeSplitterFactory_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockClankerToken} from '../mocks/MockClankerToken.sol';
import {MockRewardToken} from '../mocks/MockRewardToken.sol';
import {MockStaking} from '../mocks/MockStaking.sol';
import {MockFactory} from '../mocks/MockFactory.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrFeeSplitter Complete Branch Coverage Test
 * @notice Tests all branches in LevrFeeSplitter_v1 to achieve 100% branch coverage
 * @dev Focuses on missing branches: distribution failures, dust recovery edge cases, extreme configurations
 */
/// @notice Mock token that reverts on transfer
contract RevertingToken is MockERC20 {
    constructor() MockERC20('Reverting', 'REV') {}

    function transfer(address, uint256) public pure override returns (bool) {
        revert('Transfer failed');
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert('TransferFrom failed');
    }
}

contract LevrFeeSplitter_CompleteBranchCoverage_Test is Test {
    LevrFeeSplitterFactory_v1 public factory;
    LevrFeeSplitter_v1 public splitter;
    MockClankerToken public clankerToken;
    MockRewardToken public rewardToken;
    MockStaking public staking;
    MockFactory public mockFactory;
    LevrForwarder_v1 public forwarder;

    address public tokenAdmin = address(0xADDD);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    RevertingToken internal revertingToken;

    function setUp() public {
        clankerToken = new MockClankerToken('Mock Clanker', 'MCLK', tokenAdmin);
        rewardToken = new MockRewardToken();
        staking = new MockStaking();
        mockFactory = new MockFactory();
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        MockERC20 clankerERC20 = clankerToken.token();
        mockFactory.setProject(address(clankerERC20), address(staking), address(0));

        factory = new LevrFeeSplitterFactory_v1(address(mockFactory), address(forwarder));
        splitter = LevrFeeSplitter_v1(factory.deploy(address(clankerToken)));

        staking.whitelistToken(address(rewardToken));
        revertingToken = new RevertingToken();
    }

    /*//////////////////////////////////////////////////////////////
                    DUST RECOVERY EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: recoverDust with zero dust (balance == 0)
    /// @dev Verifies if (balance > 0) branch when balance is zero
    function test_recoverDust_zeroDust_noOp() public {
        // No tokens minted to splitter
        assertEq(rewardToken.balanceOf(address(splitter)), 0, 'Should have zero balance');

        // Recover should succeed but not transfer anything
        vm.prank(tokenAdmin);
        splitter.recoverDust(address(rewardToken), alice);

        // Alice should still have zero (no transfer occurred)
        assertEq(rewardToken.balanceOf(alice), 0, 'No transfer should occur');
    }

    /// @notice Test: recoverDust with massive dust amount
    /// @dev Verifies handling of large dust amounts
    function test_recoverDust_massiveDust_handled() public {
        uint256 massiveAmount = 1_000_000 ether;
        rewardToken.mint(address(splitter), massiveAmount);

        uint256 aliceBefore = rewardToken.balanceOf(alice);

        vm.prank(tokenAdmin);
        splitter.recoverDust(address(rewardToken), alice);

        uint256 aliceAfter = rewardToken.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, massiveAmount, 'Should recover all dust');
    }

    /*//////////////////////////////////////////////////////////////
                    CONFIGURATION VALIDATION BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: configureSplits with BPS exceeding 10000 reverts
    /// @dev Note: This is validated in _validateSplits via InvalidTotalBps
    ///      But we test extreme individual BPS values that could cause issues
    function test_configureSplits_extremeBpsValues_reverts() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);

        // Individual BPS can't exceed 10000, but if it did, total would exceed
        // Actually, validation checks totalBps == BPS_DENOMINATOR, so individual > 10000 would fail
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({
            receiver: alice,
            bps: 10_001 // Exceeds max BPS
        });

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.InvalidTotalBps.selector);
        splitter.configureSplits(splits);
    }

    /*//////////////////////////////////////////////////////////////
                    DISTRIBUTION FAILURE MODES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: distribute with receiver that reverts on transfer
    /// @dev Verifies SafeERC20 handles transfer failures
    function test_distribute_receiverReverts_handled() public {
        staking.whitelistToken(address(revertingToken));
        revertingToken.mint(address(splitter), 100 ether);

        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({
            receiver: address(revertingToken), // Will revert on transfer
            bps: 10_000
        });

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Distribution should revert when trying to transfer
        vm.expectRevert('Transfer failed');
        splitter.distribute(address(revertingToken));
    }

    /// @notice Test: distributeBatch with empty array
    /// @dev Verifies edge case with zero tokens
    function test_distributeBatch_emptyArray_succeeds() public {
        address[] memory tokens = new address[](0);

        // Should succeed without doing anything
        splitter.distributeBatch(tokens);
    }

    /// @notice Test: distribute with tiny amount tests rounding behavior
    /// @dev Verifies if (amount > 0) branch when amount rounds to zero for some receivers
    function test_distribute_zeroAmount_splitHandling() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({
            receiver: alice,
            bps: 9_999 // Very high BPS
        });
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({
            receiver: bob,
            bps: 1 // Tiny BPS
        });

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Mint tiny amount that might round to zero for bob
        rewardToken.mint(address(splitter), 1); // 1 wei

        // Distribute should handle rounding correctly
        splitter.distribute(address(rewardToken));

        // With 1 wei total:
        // - Alice: (1 * 9999) / 10000 = 0 wei (rounds down)
        // - Bob: (1 * 1) / 10000 = 0 wei (rounds down)
        // Both round to 0, so no transfers occur (amount > 0 check fails)
        // But the balance was still processed (totalDistributed updated)
        uint256 aliceReceived = rewardToken.balanceOf(alice);
        uint256 bobReceived = rewardToken.balanceOf(bob);

        // Both should receive 0 due to rounding, balance stays in splitter
        assertEq(aliceReceived, 0, 'Alice should receive 0 due to rounding');
        assertEq(bobReceived, 0, 'Bob should receive 0 due to rounding');
        assertEq(rewardToken.balanceOf(address(splitter)), 1, 'Balance should remain in splitter');
    }
}
