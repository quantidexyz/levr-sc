// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrStakedToken Complete Branch Coverage Test
 * @notice Tests all branches in LevrStakedToken_v1 to achieve 100% branch coverage
 * @dev Focuses on untested branches: approve/increaseAllowance/decreaseAllowance behavior,
 *      and mint/burn authorization edge cases
 */
contract LevrStakedToken_CompleteBranchCoverage_Test is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address nonStaking = address(0x9999);

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        factory = new LevrFactory_v1(
            config,
            address(this),
            address(0),
            address(0),
            new address[](0)
        );
        underlying = new MockERC20('Underlying', 'UND');

        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(this),
            address(factory),
            new address[](0)
        );

        underlying.mint(alice, 10000 ether);
        underlying.mint(bob, 10000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    APPROVE / ALLOWANCE BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: approve() succeeds but transferFrom() still blocked
    /// @dev Verifies that approve() works but transferFrom() reverts due to _update()
    function test_approve_allowsApprovalButTransferStillBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // approve() should succeed (ERC20 standard function)
        stakedToken.approve(bob, 500 ether);
        assertEq(stakedToken.allowance(alice, bob), 500 ether, 'Allowance should be set');

        // But transferFrom() should still revert (transfer blocking)
        vm.startPrank(bob);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transferFrom(alice, bob, 500 ether);
    }

    /// @notice Test: increaseAllowance() equivalent (approve with increased amount) succeeds but transferFrom() still blocked
    /// @dev Verifies that allowance can be increased, but transferFrom() reverts
    function test_increaseAllowance_allowsIncreaseButTransferStillBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Set initial allowance
        stakedToken.approve(bob, 200 ether);
        assertEq(stakedToken.allowance(alice, bob), 200 ether, 'Initial allowance should be set');

        // increaseAllowance() should succeed (ERC20 standard function)
        // Note: This tests that allowance can be increased, but transferFrom is still blocked
        // We test by manually calculating expected allowance since increaseAllowance may not be directly callable
        uint256 initialAllowance = stakedToken.allowance(alice, bob);
        stakedToken.approve(bob, initialAllowance + 300 ether); // Equivalent to increaseAllowance
        assertEq(stakedToken.allowance(alice, bob), 500 ether, 'Allowance should be increased');

        // But transferFrom() should still revert
        vm.startPrank(bob);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transferFrom(alice, bob, 500 ether);
    }

    /// @notice Test: decreaseAllowance() equivalent (approve with decreased amount) succeeds but transferFrom() still blocked
    /// @dev Verifies that allowance can be decreased, but transferFrom() reverts
    function test_decreaseAllowance_allowsDecreaseButTransferStillBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Set initial allowance
        stakedToken.approve(bob, 500 ether);
        assertEq(stakedToken.allowance(alice, bob), 500 ether, 'Initial allowance should be set');

        // decreaseAllowance() should succeed (ERC20 standard function)
        // We test by manually calculating expected allowance since decreaseAllowance may not be directly callable
        uint256 currentAllowance = stakedToken.allowance(alice, bob);
        stakedToken.approve(bob, currentAllowance - 200 ether); // Equivalent to decreaseAllowance
        assertEq(stakedToken.allowance(alice, bob), 300 ether, 'Allowance should be decreased');

        // But transferFrom() should still revert
        vm.startPrank(bob);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transferFrom(alice, bob, 300 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    MINT / BURN AUTHORIZATION BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: mint() reverts when called by non-staking contract
    /// @dev Verifies require(msg.sender == staking) branch
    function test_mint_nonStakingCaller_reverts() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Try to mint from non-staking address
        vm.startPrank(nonStaking);
        vm.expectRevert('ONLY_STAKING');
        stakedToken.mint(bob, 100 ether);
    }

    /// @notice Test: mint() succeeds when called by staking contract
    /// @dev Verifies the success path (already tested in other tests, but explicit here)
    function test_mint_stakingCaller_succeeds() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Mint should succeed when called via staking contract
        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Tokens should be minted');
    }

    /// @notice Test: burn() reverts when called by non-staking contract
    /// @dev Verifies require(msg.sender == staking) branch
    function test_burn_nonStakingCaller_reverts() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Try to burn from non-staking address
        vm.startPrank(nonStaking);
        vm.expectRevert('ONLY_STAKING');
        stakedToken.burn(alice, 100 ether);
    }

    /// @notice Test: burn() succeeds when called by staking contract
    /// @dev Verifies the success path (already tested in other tests, but explicit here)
    function test_burn_stakingCaller_succeeds() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Burn should succeed when called via staking contract
        staking.unstake(400 ether, alice);
        assertEq(stakedToken.balanceOf(alice), 600 ether, 'Tokens should be burned');
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES: APPROVE TO ZERO ADDRESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: approve() with zero address spender reverts (ERC20 standard)
    /// @dev OpenZeppelin ERC20 reverts on zero address spender
    function test_approve_zeroAddressSpender_reverts() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.expectRevert();
        stakedToken.approve(address(0), 500 ether);
    }
}
