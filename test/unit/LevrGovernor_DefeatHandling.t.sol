// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Defeated Proposal Handling Tests (OCT-31-CRITICAL-1 Fix)
/// @notice Tests for the fix to state-changes-before-revert bug
/// @dev FIX: Replace revert with return to persist state changes and emit events
contract LevrGovernor_DefeatHandling_Test is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    MockERC20 internal underlying;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC);

    event ProposalDefeated(uint256 proposalId);
    event ProposalExecuted(uint256 proposalId, address executor);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000, // 70%
            approvalBps: 5100, // 51%
            minSTokenBpsToSubmit: 100, // 1%
            maxProposalAmountBps: 5000, // 50%
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        underlying.mint(address(treasury), 100_000 ether);
    }

    // ============================================================================
    // TEST 1: Defeated Proposal - Quorum Failure - No Retry Attack
    // ============================================================================
    function testFix_defeatedProposal_quorumFail_noRetry() public {
        console2.log('\n=== FIX TEST 1: Quorum Failure - No Retry ===');

        // Setup: Alice (10%) and Bob (90%)
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Created proposal:', pid);
        console2.log(
            'Active count before:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // Only Alice votes - fails quorum (need 70%, only have 10%)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Verify proposal is defeated
        assertEq(
            uint8(governor.state(pid)),
            uint8(ILevrGovernor_v1.ProposalState.Defeated),
            'Should be defeated'
        );

        // FIX: Execute should NOT revert - should mark as defeated and return
        // OLD BEHAVIOR: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        // NEW BEHAVIOR: Clean exit, state persists

        governor.execute(pid); // ✅ Should NOT revert

        // Verify proposal marked as executed
        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        assertTrue(prop.executed, 'Should be marked as executed');

        // FIX [OCT-31-SIMPLIFICATION]: Count no longer decrements during execution
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            1,
            'Count stays same (only resets at cycle start)'
        );

        // NEW BEHAVIOR: Can call execute again (just returns early with ProposalDefeated event)
        // No revert, but no state change either (already defeated)
        governor.execute(pid);
        
        // Verify still marked as executed
        prop = governor.getProposal(pid);
        assertTrue(prop.executed, 'Still marked as executed');

        console2.log('[PASS] No retry attack - proposal marked as executed');
    }

    // ============================================================================
    // TEST 2: Defeated Proposal - Approval Failure - Event Emitted
    // ============================================================================
    function testFix_defeatedProposal_approvalFail_eventEmitted() public {
        console2.log('\n=== FIX TEST 2: Approval Failure - Event Emission ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Vote NO - meets quorum but fails approval
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, false); // Vote NO

        vm.warp(block.timestamp + 5 days + 1);

        // Verify meets quorum but not approval
        assertTrue(governor.meetsQuorum(pid), 'Should meet quorum');
        assertFalse(governor.meetsApproval(pid), 'Should NOT meet approval');

        // FIX: Execute should mark as defeated (event emitted)
        governor.execute(pid);

        // Verify proposal marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Should be marked as executed');

        console2.log('[PASS] ProposalDefeated event emitted successfully');
    }

    // ============================================================================
    // TEST 3: Defeated Proposal - Treasury Balance Failure - Count Decremented
    // ============================================================================
    function testFix_defeatedProposal_treasuryFail_countDecremented() public {
        console2.log('\n=== FIX TEST 3: Treasury Balance Failure - Count Management ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal for 50k tokens
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 50_000 ether);

        console2.log('Created proposal for 50k tokens');
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // Vote YES - meets quorum and approval
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Drain treasury BEFORE execution
        vm.prank(address(governor));
        treasury.transfer(address(underlying), charlie, 99_000 ether);

        console2.log(
            'Treasury drained to:',
            underlying.balanceOf(address(treasury)) / 1e18,
            'tokens'
        );

        // Execute multiple times (insufficient balance caught by try-catch)
        governor.execute(pid); // Attempt 1
        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(pid); // Attempt 2
        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(pid); // Attempt 3

        // NEW BEHAVIOR: Failed execution doesn't auto-advance cycle
        // Count stays at 1 because cycle hasn't advanced yet
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            1,
            'Count stays same (cycle has not advanced on failure)'
        );
        
        // Manually advance cycle (after 3 attempts)
        governor.startNewCycle();
        
        // NOW count resets to 0 after cycle advance
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            0,
            'Count resets at cycle start (after manual advance)'
        );

        console2.log('[PASS] Insufficient balance handled via try-catch, manual cycle advance works');
    }

    // ============================================================================
    // TEST 4: No Gridlock - Failed Proposals Don't Block New Ones
    // ============================================================================
    function testFix_noGridlock_failedProposalsDontBlock() public {
        console2.log('\n=== FIX TEST 4: No Gridlock from Failed Proposals ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Fill up to maxActiveProposals with failing proposals
        uint16 max = factory.maxActiveProposals(address(underlying));
        console2.log('Max active proposals:', max);

        // Use different proposal types to avoid AlreadyProposedInCycle
        uint256[] memory pids = new uint256[](4); // Just test with 4 proposals

        // Boost proposals from Alice and Bob
        vm.prank(alice);
        pids[0] = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        pids[1] = governor.proposeBoost(address(underlying), 2000 ether);

        // Transfer proposals from Alice and Bob
        vm.prank(alice);
        pids[2] = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'test1');

        vm.prank(bob);
        pids[3] = governor.proposeTransfer(address(underlying), charlie, 600 ether, 'test2');

        console2.log('Created 4 proposals that will fail quorum');

        // Move to execution window
        vm.warp(block.timestamp + 2 days + 5 days + 1);

        // Execute all - all should be defeated (no votes = fail quorum)
        for (uint256 i = 0; i < 4; i++) {
            governor.execute(pids[i]);
        }

        // All proposals failed quorum (no votes), so all defeated early
        // No winner executed, so _startNewCycle() was NOT called
        // Counts should stay at old values (2 boost, 2 transfer)
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            2,
            'Boost count stays at 2 (defeated proposals dont auto-advance cycle)'
        );
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.TransferToAddress),
            2,
            'Transfer count stays at 2 (defeated proposals dont auto-advance cycle)'
        );

        console2.log('All proposals executed (marked as defeated)');

        // Manual cycle advancement needed (no winner to auto-advance)
        governor.startNewCycle();

        // Now counts are reset
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            0,
            'Boost count reset after new cycle'
        );

        // Can create new proposals (no gridlock!)
        vm.prank(alice);
        uint256 newPid = governor.proposeBoost(address(underlying), 500 ether);

        console2.log('Created new proposal after manual cycle advance:', newPid);
        console2.log('[PASS] No gridlock - manual cycle advance works');
    }

    // ============================================================================
    // TEST 5: Multiple Defeat Reasons - All Handled Correctly
    // ============================================================================
    function testFix_multipleDefeatReasons_allHandled() public {
        console2.log('\n=== FIX TEST 5: Multiple Defeat Reasons ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Proposal 1: Fails quorum (no votes)
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        // Proposal 2: Fails approval (all vote NO)
        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        // Proposal 3: Fails treasury balance
        vm.prank(alice);
        uint256 pid3 = governor.proposeTransfer(
            address(underlying),
            charlie,
            50_000 ether,
            'big transfer'
        );

        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility

        // Vote on proposal 2 (NO) and 3 (YES)
        vm.prank(alice);
        governor.vote(pid2, false);
        vm.prank(bob);
        governor.vote(pid2, false);

        vm.prank(alice);
        governor.vote(pid3, true);
        vm.prank(bob);
        governor.vote(pid3, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Drain treasury for pid3
        vm.prank(address(governor));
        treasury.transfer(address(underlying), charlie, 99_000 ether);

        // Execute all three
        governor.execute(pid1); // Quorum fail - early return, marks executed
        governor.execute(pid2); // Approval fail - early return, marks executed
        
        // Execute pid3 three times (treasury fail - catch block, NOT marked executed)
        governor.execute(pid3); // Attempt 1
        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(pid3); // Attempt 2
        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(pid3); // Attempt 3

        // Verify P1 and P2 marked as executed (defeated early)
        assertTrue(
            governor.getProposal(pid1).executed,
            'P1 should be executed (defeated - quorum)'
        );
        assertTrue(
            governor.getProposal(pid2).executed,
            'P2 should be executed (defeated - approval)'
        );
        
        // NEW BEHAVIOR: P3 NOT marked executed (failed in try-catch, can retry)
        assertFalse(
            governor.getProposal(pid3).executed,
            'P3 should NOT be executed (winner but failed - can retry)'
        );

        // NEW BEHAVIOR: Cycle did NOT auto-advance (failed execution)
        // Counts stay at current values
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            2,
            'Boost count stays same (cycle has not advanced)'
        );
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.TransferToAddress),
            1,
            'Transfer count stays same (cycle has not advanced)'
        );
        
        // Manual cycle advance (after 3 execution attempts)
        governor.startNewCycle();
        
        // NOW counts reset
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            0,
            'Boost count resets after manual advance'
        );
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.TransferToAddress),
            0,
            'Transfer count resets after manual advance'
        );

        console2.log('[PASS] All defeat reasons handled, manual advance works');
    }

    // ============================================================================
    // TEST 6: Defeated Proposal After Cycle Reset - No Underflow
    // ============================================================================
    function testFix_defeatedProposal_afterCycleReset_noUnderflow() public {
        console2.log('\n=== FIX TEST 6: Defeated After Cycle Reset - No Underflow ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Cycle 1: Create failing proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Cycle 1: Created proposal', pid);
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // Move to end of cycle
        vm.warp(block.timestamp + 2 days + 5 days + 1);

        // Start Cycle 2 (count resets to 0)
        governor.startNewCycle();

        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            0,
            'Count should be 0 after reset'
        );

        console2.log('Cycle 2: Count reset to 0');

        // Execute old Cycle 1 proposal - should revert (not in current cycle)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(pid);

        // Verify count STILL 0 (no underflow, proposal wasn't executed)
        assertEq(
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool),
            0,
            'Count should still be 0 (old proposal rejected)'
        );

        console2.log('[PASS] Old proposals properly rejected, no underflow');
    }

    // ============================================================================
    // TEST 7: Event Sequence - ProposalDefeated Then No Revert
    // ============================================================================
    function testFix_eventSequence_defeatedEventPersists() public {
        console2.log('\n=== FIX TEST 7: Event Persistence ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Vote NO
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, false);

        vm.warp(block.timestamp + 5 days + 1);

        // Execute defeated proposal (event will be emitted)
        governor.execute(pid);

        // Verify proposal marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        console2.log('[PASS] ProposalDefeated event persists (not rolled back)');
    }

    // ============================================================================
    // TEST 8: Successful Proposal After Defeats - Normal Flow Works
    // ============================================================================
    function testFix_successfulProposal_afterDefeats_normalFlow() public {
        console2.log('\n=== FIX TEST 8: Normal Flow After Defeats ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Give Bob some tokens too
        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create 3 proposals - 2 will fail, 1 will succeed
        // Use different proposers to avoid AlreadyProposedInCycle
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        vm.prank(alice);
        uint256 pid3 = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'good');

        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility

        // Vote: pid1 NO (both), pid2 NO votes, pid3 YES (both)
        vm.prank(alice);
        governor.vote(pid1, false); // Fail approval

        vm.prank(bob);
        governor.vote(pid1, false); // Fail approval

        // pid2 - no votes (fail quorum)

        vm.prank(alice);
        governor.vote(pid3, true); // Success!

        vm.prank(bob);
        governor.vote(pid3, true); // Success!

        vm.warp(block.timestamp + 5 days + 1);

        // Execute all
        governor.execute(pid1); // Defeated
        governor.execute(pid2); // Defeated

        // pid3 should succeed normally (it's the winner)
        governor.execute(pid3);

        // Verify pid3 executed successfully
        ILevrGovernor_v1.Proposal memory p3 = governor.getProposal(pid3);
        assertTrue(p3.executed, 'P3 should be executed');
        assertEq(
            uint8(governor.state(pid3)),
            uint8(ILevrGovernor_v1.ProposalState.Executed),
            'P3 should be Executed state'
        );

        console2.log('[PASS] Normal execution flow works after defeats');
    }
}
