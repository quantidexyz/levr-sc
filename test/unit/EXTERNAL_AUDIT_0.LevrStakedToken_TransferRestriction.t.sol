// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @title EXTERNAL_AUDIT_0 CRITICAL-1: Staked Token Transfer Restriction Tests
/// @notice Tests for [CRITICAL-1] Staked Token Transferability Breaks Unstaking Mechanism
/// @dev Issue: LevrStakedToken allows transfers, which desynchronizes internal accounting
contract EXTERNAL_AUDIT_0_LevrStakedTokenTransferRestrictionTest is Test {
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    LevrFactory_v1 factory;
    LevrForwarder_v1 forwarder;
    MockERC20 underlying;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address tokenAdmin = address(0x3333);

    function setUp() public {
        // Create factory config
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
            maxRewardTokens: 50
        });

        // Deploy forwarder
        forwarder = new LevrForwarder_v1('Levr Forwarder');

        // Deploy factory with correct constructor
        factory = new LevrFactory_v1(
            config,
            address(this),
            address(forwarder),
            address(0),
            address(0)
        );

        // Deploy underlying token
        underlying = new MockERC20('Underlying', 'UND');

        // Create staking and staked token directly
        staking = new LevrStaking_v1(address(forwarder));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(factory),
            address(factory)
        );

        // Mint underlying tokens
        underlying.mint(alice, 10000 ether);
        underlying.mint(bob, 10000 ether);
    }

    /// @notice Test that basic staking mints staked tokens correctly
    function test_stakedToken_basicMinting() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Verify tokens were minted
        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Staked tokens should be minted');
        assertEq(staking.stakedBalanceOf(alice), 1000 ether, 'Internal accounting should match');
    }

    /// @notice Test that transfers are blocked (if fix is implemented)
    /// @dev This test assumes the transfer restriction fix is in place
    function test_stakedToken_transferBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Attempt transfer - should fail with transfer restriction
        vm.expectRevert();
        stakedToken.transfer(bob, 1000 ether);
    }

    /// @notice Test that transferFrom is also blocked
    function test_stakedToken_transferFromBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        stakedToken.approve(bob, 1000 ether);

        vm.startPrank(bob);
        vm.expectRevert();
        stakedToken.transferFrom(alice, bob, 1000 ether);
    }

    /// @notice Test that mint and burn still function after transfer restriction
    function test_stakedToken_mintBurnStillWork() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Stake should mint tokens');

        // Unstake should burn tokens
        staking.unstake(1000 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 0, 'Unstake should burn tokens');
    }

    /// @notice Test that transfer of 0 tokens is also blocked
    function test_stakedToken_transferZeroAmountBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Even transferring 0 should be blocked
        vm.expectRevert();
        stakedToken.transfer(bob, 0);
    }

    /// @notice Test the attack scenario from the audit report
    /// @dev This demonstrates what happens without the fix
    function test_stakedToken_attackScenario_desyncAccountingAndTokenBalance() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Verify initial state
        assertEq(staking.stakedBalanceOf(alice), 1000 ether, 'Alice has staked 1000');
        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Alice has 1000 staked tokens');

        // Attempt to transfer staked tokens to Bob
        // If transfers are blocked (correct behavior), this should revert
        vm.expectRevert();
        stakedToken.transfer(bob, 1000 ether);

        // If transfers were allowed (bug), the state would become:
        // _staked[Alice] = 1000 (unchanged)
        // stakedToken.balanceOf(Alice) = 0 (transferred)
        // stakedToken.balanceOf(Bob) = 1000 (received)
        // _staked[Bob] = 0 (never staked)
        // Result: Alice's underlying tokens become locked, Bob cannot unstake
    }

    /// @notice Test that partial unstaking still works normally
    function test_stakedToken_partialUnstakingWorks() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Unstake partial amount
        staking.unstake(400 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 600 ether, 'Should have 600 staked tokens left');
        assertEq(staking.stakedBalanceOf(alice), 600 ether, 'Should have 600 staked internally');
        assertEq(underlying.balanceOf(alice), 400 ether, 'Should have received 400 underlying');
    }

    /// @notice Test that full unstaking burns all staked tokens
    function test_stakedToken_fullUnstakingBurnsAll() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        staking.unstake(1000 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 0, 'All staked tokens should be burned');
        assertEq(staking.stakedBalanceOf(alice), 0, 'Internal accounting should be zero');
        assertEq(
            underlying.balanceOf(alice),
            1000 ether,
            'Should have received all underlying back'
        );
    }

    /// @notice Test approvals don't bypass transfer restriction
    function test_stakedToken_approvalDoesntBypassRestriction() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Approve maximum amount
        stakedToken.approve(bob, type(uint256).max);

        // Bob still cannot transfer
        vm.startPrank(bob);
        vm.expectRevert();
        stakedToken.transferFrom(alice, bob, 1000 ether);
    }

    /// @notice Test that multiple users can stake independently
    function test_stakedToken_multipleUsers_independentStakes() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 2000 ether);
        staking.stake(2000 ether);

        assertEq(stakedToken.balanceOf(alice), 1000 ether);
        assertEq(stakedToken.balanceOf(bob), 2000 ether);
        assertEq(stakedToken.totalSupply(), 3000 ether);

        // Neither can transfer
        vm.expectRevert();
        stakedToken.transfer(alice, 1000 ether);
    }

    /// @notice Test that decimals are preserved
    function test_stakedToken_decimalsPreserved() public {
        uint8 expectedDecimals = underlying.decimals();
        assertEq(stakedToken.decimals(), expectedDecimals, 'Decimals should match underlying');
    }

    /// @notice Test that staking with dust amounts works
    function test_stakedToken_dustAmounts() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 100 wei);
        staking.stake(100 wei);

        assertEq(stakedToken.balanceOf(alice), 100 wei);

        // Should not be able to transfer even dust
        vm.expectRevert();
        stakedToken.transfer(bob, 1 wei);
    }
}
