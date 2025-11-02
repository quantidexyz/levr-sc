// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrTreasury_v1} from '../../src/interfaces/ILevrTreasury_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/**
 * @title LevrTreasury Complete Branch Coverage Test
 * @notice Tests all branches in LevrTreasury_v1 to achieve 80% branch coverage
 * @dev Focuses on missing failure mode branches: transfer failures, boost failures, zero amount handling
 */
/// @notice Mock token that returns false on transfer (non-standard ERC20)
contract NonStandardToken is MockERC20 {
    bool public shouldRevert;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldRevert) revert('Transfer failed');
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (shouldRevert) revert('TransferFrom failed');
        return super.transferFrom(from, to, amount);
    }
}

contract LevrTreasury_CompleteBranchCoverage_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    address internal governor;

    address protocolTreasury = address(0xDEAD);
    address alice = address(0x1111);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = project.governor;
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);

        underlying.mint(address(treasury), 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    TRANSFER FAILURE MODE BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: transfer() with non-standard token that reverts
    /// @dev Verifies SafeERC20 handles transfer failures correctly
    function test_transfer_maliciousTokenReverts_handled() public {
        NonStandardToken badToken = new NonStandardToken('Bad', 'BAD');
        badToken.mint(address(treasury), 100 ether);
        badToken.setShouldRevert(true);

        vm.prank(governor);
        vm.expectRevert('Transfer failed');
        treasury.transfer(address(badToken), alice, 100 ether);
    }

    /// @notice Test: transfer() with insufficient balance
    /// @dev Verifies SafeERC20 detects insufficient balance
    function test_transfer_insufficientBalance_reverts() public {
        uint256 balance = underlying.balanceOf(address(treasury));

        vm.prank(governor);
        vm.expectRevert();
        treasury.transfer(address(underlying), alice, balance + 1 ether);
    }

    /// @notice Test: transfer() succeeds with valid inputs
    /// @dev Verifies the success path (already tested elsewhere, but explicit here)
    function test_transfer_validInputs_succeeds() public {
        uint256 amount = 100 ether;
        uint256 aliceBefore = underlying.balanceOf(alice);

        vm.prank(governor);
        treasury.transfer(address(underlying), alice, amount);

        uint256 aliceAfter = underlying.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, amount, 'Transfer should succeed');
    }

    /*//////////////////////////////////////////////////////////////
                    BOOST FAILURE MODE BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: applyBoost() with zero amount reverts
    /// @dev Verifies require(amount != 0) branch
    function test_boost_amountZero_reverts() public {
        vm.prank(governor);
        vm.expectRevert(ILevrTreasury_v1.InvalidAmount.selector);
        treasury.applyBoost(address(underlying), 0);
    }

    /// @notice Test: applyBoost() succeeds with valid amount
    /// @dev Verifies the success path
    function test_boost_validAmount_succeeds() public {
        uint256 amount = 1000 ether;
        uint256 stakingBefore = underlying.balanceOf(address(staking));

        vm.prank(governor);
        treasury.applyBoost(address(underlying), amount);

        uint256 stakingAfter = underlying.balanceOf(address(staking));
        assertGt(stakingAfter - stakingBefore, 0, 'Boost should succeed');
    }

    /// @notice Test: applyBoost() with token zero address reverts
    /// @dev Verifies require(token != address(0)) branch
    function test_boost_tokenZeroAddress_reverts() public {
        vm.prank(governor);
        vm.expectRevert(ILevrTreasury_v1.ZeroAddress.selector);
        treasury.applyBoost(address(0), 1000 ether);
    }

    /// @notice Test: applyBoost() when staking has insufficient balance (should not happen in practice)
    /// @dev Note: applyBoost pulls from treasury, so this tests edge case where treasury doesn't have enough
    ///      This would be caught by SafeERC20, but we test the branch anyway
    function test_boost_insufficientTreasuryBalance_reverts() public {
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));
        uint256 excessiveAmount = treasuryBalance + 1 ether;

        vm.prank(governor);
        // SafeERC20 should revert when trying to transfer more than balance
        vm.expectRevert();
        treasury.applyBoost(address(underlying), excessiveAmount);
    }
}
