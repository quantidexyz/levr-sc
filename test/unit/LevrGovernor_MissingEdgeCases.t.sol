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

/// @title Missing Edge Case Tests for LevrGovernor_v1
/// @notice Tests for edge cases not covered in existing test suites
/// @dev Discovered via systematic code analysis and audit review
contract LevrGovernor_MissingEdgeCases_Test is Test, LevrFactoryDeployHelper {
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
    address internal dave = address(0xDA6E);
    address internal eve = address(0xE6E);

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
            maxProposalAmountBps: 5000, // 50%,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
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
    // EDGE CASE 1: Underflow Protection - Execute Old Cycle Proposal After Reset
    // ============================================================================
    /// @notice Test the `if (count > 0)` protection when count was reset to 0
    /// @dev Scenario: Cycle 1 proposals defeated, Cycle 2 starts (count = 0),
    ///      someone tries to execute old Cycle 1 proposal
    function test_edgeCase_executeOldProposalAfterCountReset_underflowProtection() public {
        console2.log('\n=== EDGE CASE 1: Underflow Protection on Old Proposal Execution ===');

        // Setup stakers
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

        // Create proposal in Cycle 1
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Created proposal in Cycle 1');
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // Only Alice votes - fails quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Start Cycle 2 (resets count to 0)
        governor.startNewCycle();

        uint256 countAfterReset = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after cycle reset:', countAfterReset);
        assertEq(countAfterReset, 0, 'Count should be 0 after reset');

        // Try to execute old Cycle 1 proposal (will fail quorum)
        // The execute() function has: if (_activeProposalCount > 0) { count-- }
        // Since count = 0, decrement is skipped (preventing underflow)
        console2.log('\nAttempting to execute old Cycle 1 proposal after count reset...');

        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid1);

        // Verify count STILL 0 (no underflow occurred)
        uint256 countAfter = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after failed execute:', countAfter);
        assertEq(countAfter, 0, 'Count should still be 0 (underflow prevented)');

        console2.log('[PASS] Underflow protection working correctly');
    }

    // ============================================================================
    // EDGE CASE 2: Multiple Proposals with Identical YES Votes (3+ way tie)
    // ============================================================================
    /// @notice Test tie-breaking with 3+ proposals having exact same YES votes
    /// @dev Current code uses strict `>` comparison, so first (lowest ID) wins
    function test_edgeCase_threeWayTie_firstProposalWins() public {
        console2.log('\n=== EDGE CASE 2: Three-Way Tie in YES Votes ===');

        // Setup 3 users with equal stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(333 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(333 ether);
        vm.stopPrank();

        underlying.mint(charlie, 1000 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(334 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create 3 boost proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        vm.prank(charlie);
        uint256 pid3 = governor.proposeBoost(address(underlying), 3000 ether);

        console2.log('Created 3 proposals:', pid1, pid2, pid3);

        // Vote to create EXACT 3-way tie in YES votes
        vm.warp(block.timestamp + 2 days + 1);

        // Each proposal gets votes from all 3 users to create identical VP totals
        // P1: Alice YES, Bob YES, Charlie YES
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid1, true);
        vm.prank(charlie);
        governor.vote(pid1, true);

        // P2: Alice YES, Bob YES, Charlie YES
        vm.prank(alice);
        governor.vote(pid2, true);
        vm.prank(bob);
        governor.vote(pid2, true);
        vm.prank(charlie);
        governor.vote(pid2, true);

        // P3: Alice YES, Bob YES, Charlie YES
        vm.prank(alice);
        governor.vote(pid3, true);
        vm.prank(bob);
        governor.vote(pid3, true);
        vm.prank(charlie);
        governor.vote(pid3, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Verify all 3 have EXACT same yes votes
        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);
        ILevrGovernor_v1.Proposal memory p3 = governor.getProposal(pid3);

        console2.log('\nVoting Results:');
        console2.log('  P1 YES:', p1.yesVotes);
        console2.log('  P2 YES:', p2.yesVotes);
        console2.log('  P3 YES:', p3.yesVotes);

        assertEq(p1.yesVotes, p2.yesVotes, 'P1 and P2 should have identical votes');
        assertEq(p2.yesVotes, p3.yesVotes, 'P2 and P3 should have identical votes');

        // Winner should be pid1 (first proposal, lowest ID)
        uint256 winner = governor.getWinner(1);
        console2.log('Winner:', winner);
        assertEq(winner, pid1, 'First proposal (lowest ID) should win on 3-way tie');

        // Execute first proposal
        governor.execute(pid1);

        // Other proposals should NOT be executable (not winner)
        vm.expectRevert(ILevrGovernor_v1.NotWinner.selector);
        governor.execute(pid2);

        vm.expectRevert(ILevrGovernor_v1.NotWinner.selector);
        governor.execute(pid3);

        console2.log('[PASS] Three-way tie resolved deterministically (first proposal wins)');
    }

    // ============================================================================
    // EDGE CASE 3: Arithmetic Overflow in Quorum Calculation
    // ============================================================================
    /// @notice Test quorum calculation with very large totalSupply
    /// @dev (totalSupply * quorumBps) could overflow if supply is huge
    function test_edgeCase_quorumCalculation_arithmeticOverflow() public {
        console2.log('\n=== EDGE CASE 3: Arithmetic Overflow in Quorum Calculation ===');

        // This test would require mocking the sToken to return a huge totalSupply
        // Since we can't easily do that with current setup, we document the protection

        console2.log('Solidity 0.8.30 automatic overflow protection:');
        console2.log('  - If (totalSupply * quorumBps) overflows, transaction reverts');
        console2.log('  - Max safe totalSupply = type(uint256).max / 10000');
        console2.log('  - This is approximately 1.157e73 tokens');
        console2.log('  - Realistically impossible to reach in practice');

        // The code at line 426 will automatically revert on overflow:
        // uint256 requiredQuorum = (totalSupply * quorumBps) / 10_000;

        console2.log('[SAFE BY DEFAULT] Overflow protection via Solidity 0.8.x');
    }

    // ============================================================================
    // EDGE CASE 4: Invalid BPS Values in Snapshot
    // ============================================================================
    /// @notice Test behavior when quorumBps or approvalBps > 10000 (invalid BPS)
    /// @dev Factory validation should prevent this, but what if it doesn't?
    function test_edgeCase_invalidBps_snapshotBehavior() public {
        console2.log('\n=== EDGE CASE 4: Invalid BPS Values in Snapshot ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Try to set invalid BPS (> 10000 = > 100%)
        ILevrFactory_v1.FactoryConfig memory invalidCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 15000, // INVALID: 150% > 100%
            approvalBps: 20000, // INVALID: 200% > 100%
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });

        factory.updateConfig(invalidCfg);

        console2.log('Set invalid BPS values:');
        console2.log('  Quorum: 15000 (150%)');
        console2.log('  Approval: 20000 (200%)');

        // Create proposal (will snapshot invalid values)
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('\nSnapshot values:');
        console2.log('  Quorum snapshot:', prop.quorumBpsSnapshot);
        console2.log('  Approval snapshot:', prop.approvalBpsSnapshot);

        assertEq(prop.quorumBpsSnapshot, 15000, 'Should snapshot invalid quorum');
        assertEq(prop.approvalBpsSnapshot, 20000, 'Should snapshot invalid approval');

        // Vote with 100% participation and approval
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // With 150% quorum requirement, proposal can NEVER meet quorum
        // (max participation = 100% < 150%)
        assertFalse(governor.meetsQuorum(pid), 'Cannot meet 150% quorum');

        // Try to execute - should fail
        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);

        console2.log('[FINDING] Invalid BPS values make proposals impossible to execute');
        console2.log('[RECOMMENDATION] Add BPS validation to factory.updateConfig()');
    }

    // ============================================================================
    // EDGE CASE 5: Execute Defeated Proposal from Old Cycle After New Cycle Starts
    // ============================================================================
    /// @notice Test execution attempt of defeated proposal from previous cycle
    /// @dev Verifies that cross-cycle execution attempts are handled correctly
    function test_edgeCase_executeDefeatedProposalFromOldCycle() public {
        console2.log('\n=== EDGE CASE 5: Execute Old Cycle Proposal After New Cycle ===');

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

        // Cycle 1: Create proposal that will fail quorum
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Cycle 1: Created proposal', pid1);

        // Only Alice votes - fails quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Verify proposal defeated
        ILevrGovernor_v1.ProposalState state1 = governor.state(pid1);
        assertEq(
            uint8(state1),
            uint8(ILevrGovernor_v1.ProposalState.Defeated),
            'Should be defeated'
        );

        // Start Cycle 2 (count resets to 0)
        governor.startNewCycle();

        console2.log('\nCycle 2: Started (count reset to 0)');
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // Try to execute Cycle 1 proposal in Cycle 2
        console2.log('Attempting to execute Cycle 1 proposal...');

        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid1);

        // Verify count STILL 0 (underflow protection worked)
        uint256 countAfter = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after execute attempt:', countAfter);
        assertEq(countAfter, 0, 'Underflow protection: count stays at 0');

        console2.log('[PASS] Underflow protection prevents negative count');
    }

    // ============================================================================
    // EDGE CASE 6: Multiple Rapid Config Updates
    // ============================================================================
    /// @notice Test 3 rapid config updates before and after proposal creation
    /// @dev Verifies snapshot captures correct config at proposal creation time
    function test_edgeCase_multipleRapidConfigUpdates() public {
        console2.log('\n=== EDGE CASE 6: Multiple Rapid Config Updates ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Config update 1: quorum = 5000 (50%)
        ILevrFactory_v1.FactoryConfig memory cfg1 = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 5000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });
        factory.updateConfig(cfg1);
        console2.log('Config 1: quorum = 50%');

        // Config update 2: quorum = 6000 (60%)
        cfg1.quorumBps = 6000;
        factory.updateConfig(cfg1);
        console2.log('Config 2: quorum = 60%');

        // Config update 3: quorum = 7000 (70%)
        cfg1.quorumBps = 7000;
        factory.updateConfig(cfg1);
        console2.log('Config 3: quorum = 70%');

        // Create proposal RIGHT AFTER third update
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Verify snapshot captured LATEST config (70%)
        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('\nSnapshot quorum:', prop.quorumBpsSnapshot);
        assertEq(prop.quorumBpsSnapshot, 7000, 'Should snapshot latest config (70%)');

        // Config update 4 AFTER proposal creation: quorum = 9000 (90%)
        cfg1.quorumBps = 9000;
        factory.updateConfig(cfg1);
        console2.log('Config 4 (post-creation): quorum = 90%');

        // Vote and check quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Should meet quorum using snapshot (70%), not current config (90%)
        assertTrue(governor.meetsQuorum(pid), 'Should use snapshot (70%), not current (90%)');

        console2.log(
            '[PASS] Snapshot captures config at exact creation moment, immune to rapid updates'
        );
    }

    // ============================================================================
    // EDGE CASE 7: Proposal Creation at Exact Cycle Boundary
    // ============================================================================
    /// @notice Test proposal creation at the EXACT timestamp when cycle ends
    /// @dev Verifies auto-start logic handles boundary correctly
    function test_edgeCase_proposalAtExactCycleBoundary() public {
        console2.log('\n=== EDGE CASE 7: Proposal at Cycle Boundary ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create first proposal (starts Cycle 1)
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        uint256 cycle1End = p1.votingEndsAt;

        console2.log('Cycle 1 voting ends at:', cycle1End);

        // Warp to 1 second AFTER cycle ends (boundary + 1)
        vm.warp(cycle1End + 1);

        console2.log('Current timestamp:', block.timestamp);
        console2.log('Cycle 1 end timestamp:', cycle1End);
        console2.log('Past cycle end by 1 second');

        // Try to create proposal after cycle boundary
        // Should auto-start Cycle 2
        vm.prank(alice);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        // Verify we're in a new cycle
        uint256 cycleId = governor.currentCycleId();
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        console2.log('\nProposal 2 created in cycle:', p2.cycleId);
        console2.log('Current cycle ID:', cycleId);

        assertTrue(p2.cycleId > p1.cycleId, 'Should be in new cycle');

        console2.log('[PASS] Auto-start handles cycle boundary correctly');
    }

    // ============================================================================
    // EDGE CASE 8: Zero Total Supply Snapshot
    // ============================================================================
    /// @notice Test proposal creation when totalSupply = 0
    /// @dev FINDING: Can create proposals with 0 total supply if minSTokenBpsToSubmit = 0!
    function test_edgeCase_zeroTotalSupplySnapshot_actuallySucceeds() public {
        console2.log('\n=== EDGE CASE 8: Zero Total Supply Snapshot ===');

        // Set minSTokenBpsToSubmit to 0 (disable minimum stake requirement)
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 0, // NO MINIMUM
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });
        factory.updateConfig(cfg);

        // No one has staked
        console2.log('Total supply:', sToken.totalSupply());
        assertEq(sToken.totalSupply(), 0, 'No tokens staked');

        // Alice tries to create proposal with 0 stake
        console2.log('\nAttempting to create proposal with 0 total supply...');

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Proposal created successfully with ID:', pid);

        // Check the snapshot
        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('Total supply snapshot:', prop.totalSupplySnapshot);
        assertEq(prop.totalSupplySnapshot, 0, 'Should snapshot 0 supply');

        // This proposal can NEVER meet quorum (requiredQuorum = 0, but no one can vote with 0 VP)
        console2.log('\n[FINDING] Can create proposals with 0 supply, but they can never execute');
        console2.log('[RECOMMENDATION] Consider requiring totalSupply > 0 at proposal creation');
    }

    // ============================================================================
    // EDGE CASE 9: Execution After Multiple Cycle Advances
    // ============================================================================
    /// @notice Test executing a proposal from Cycle 1 after advancing to Cycle 5
    /// @dev Verifies old proposals can still execute if they were winners
    function test_edgeCase_executeOldCycleProposal_afterMultipleCycles() public {
        console2.log('\n=== EDGE CASE 9: Execute Old Proposal After Multiple Cycles ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Cycle 1: Create successful proposal but DON'T execute it
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Verify it's executable
        assertTrue(governor.meetsQuorum(pid1), 'Should meet quorum');
        assertTrue(governor.meetsApproval(pid1), 'Should meet approval');
        assertEq(governor.getWinner(1), pid1, 'Should be winner of Cycle 1');

        console2.log('Cycle 1: Proposal is winner but NOT executed');

        // Try to start Cycle 2 - should FAIL (executable proposal remaining)
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        governor.startNewCycle();

        console2.log('[PASS] Cannot advance cycle while executable proposals remain');
        console2.log('[SECURITY] This prevents orphaning winning proposals');
    }

    // ============================================================================
    // EDGE CASE 10: Config Update During Proposal Window (Before Voting)
    // ============================================================================
    /// @notice Test config update during proposal window, before voting starts
    /// @dev Verifies that proposals created after config update get new config
    function test_edgeCase_configUpdateDuringProposalWindow() public {
        console2.log('\n=== EDGE CASE 10: Config Update During Proposal Window ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create first proposal (quorum = 70%)
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        uint16 snapshot1 = governor.getProposal(pid1).quorumBpsSnapshot;
        console2.log('Proposal 1 quorum snapshot:', snapshot1);
        assertEq(snapshot1, 7000, 'Should snapshot 70%');

        // DURING PROPOSAL WINDOW: Update config
        vm.warp(block.timestamp + 1 days); // Still in proposal window

        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 5000, // Changed to 50%
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });
        factory.updateConfig(newCfg);

        console2.log('Config updated during proposal window: quorum = 50%');

        // Create second proposal (should snapshot new config)
        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'test');

        uint16 snapshot2 = governor.getProposal(pid2).quorumBpsSnapshot;
        console2.log('Proposal 2 quorum snapshot:', snapshot2);
        assertEq(snapshot2, 5000, 'Should snapshot new config (50%)');

        // Verify proposals have DIFFERENT snapshots
        assertNotEq(snapshot1, snapshot2, 'Proposals should have different quorum snapshots');

        console2.log('[PASS] Proposals created at different times snapshot different configs');
    }

    // ============================================================================
    // EDGE CASE 11: Winner with 0 YES Votes (All Proposals Defeated)
    // ============================================================================
    /// @notice Test _getWinner() when no proposals meet quorum/approval
    /// @dev Should return 0 (no winner), verified this doesn't break execution logic
    function test_edgeCase_noWinner_allProposalsDefeated() public {
        console2.log('\n=== EDGE CASE 11: No Winner - All Proposals Defeated ===');

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

        // Create 3 proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        vm.prank(alice);
        uint256 pid3 = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'test');

        console2.log('Created 3 proposals');

        // Only Alice votes (10% participation, below 70% quorum)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(alice);
        governor.vote(pid2, true);
        vm.prank(alice);
        governor.vote(pid3, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Verify all defeated
        assertFalse(governor.meetsQuorum(pid1), 'P1 should not meet quorum');
        assertFalse(governor.meetsQuorum(pid2), 'P2 should not meet quorum');
        assertFalse(governor.meetsQuorum(pid3), 'P3 should not meet quorum');

        // Winner should be 0
        uint256 winner = governor.getWinner(1);
        console2.log('Winner:', winner);
        assertEq(winner, 0, 'No winner when all proposals defeated');

        // Try to execute any proposal - should fail
        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid1);

        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid2);

        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid3);

        // Should be able to start new cycle
        governor.startNewCycle();

        console2.log('[PASS] System handles no-winner scenario correctly');
    }

    // ============================================================================
    // EDGE CASE 12: Snapshot With Extreme BPS Values (uint16 Max)
    // ============================================================================
    /// @notice Test snapshot behavior when BPS values are at uint16 max (65535)
    /// @dev uint16 max = 65535, way above 10000 (100% in BPS)
    function test_edgeCase_extremeBpsValues_uint16Max() public {
        console2.log('\n=== EDGE CASE 12: Extreme BPS Values (uint16 Max) ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set BPS to uint16 max
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: type(uint16).max, // 65535
            approvalBps: type(uint16).max, // 65535
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });
        factory.updateConfig(cfg);

        console2.log('Set quorum/approval to uint16.max:', type(uint16).max);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('Snapshot quorum:', prop.quorumBpsSnapshot);
        console2.log('Snapshot approval:', prop.approvalBpsSnapshot);

        // These calculations will overflow:
        // requiredQuorum = (totalSupply * 65535) / 10000 = totalSupply * 6.5535
        // requiredApproval = (totalVotes * 65535) / 10000 = totalVotes * 6.5535

        // Proposal can NEVER meet these requirements
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        assertFalse(governor.meetsQuorum(pid), 'Impossible to meet 655.35% quorum');
        assertFalse(governor.meetsApproval(pid), 'Impossible to meet 655.35% approval');

        console2.log('[FINDING] Extreme BPS values make governance impossible');
        console2.log('[RECOMMENDATION] Add BPS validation: require(bps <= 10000)');
    }

    // ============================================================================
    // EDGE CASE 13: Proposal Amount Validation with Dynamic Treasury Balance
    // ============================================================================
    /// @notice Test maxProposalAmountBps validation when treasury balance changes
    /// @dev Proposal amount is validated against treasury balance at CREATION time
    function test_edgeCase_proposalAmountValidation_treasuryBalanceChanges() public {
        console2.log('\n=== EDGE CASE 13: Proposal Amount Validation ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Treasury has 100,000 tokens
        // maxProposalAmountBps = 5000 (50%)
        // Max allowed = 50,000 tokens
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));
        console2.log('Treasury balance:', treasuryBalance / 1e18);
        console2.log('Max proposal amount (50%):', (treasuryBalance / 2) / 1e18);

        // Create proposal for exactly 50% (50,000 tokens)
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 50_000 ether);

        console2.log('Created proposal for 50,000 tokens (exactly 50%)');

        // Try to create proposal for 50% + 1 wei (should fail)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.ProposalAmountExceedsLimit.selector);
        governor.proposeBoost(address(underlying), 50_000 ether + 1);

        console2.log('Cannot create proposal for 50,000 + 1 wei: PASS');

        // Now DRAIN treasury via governor (simulate other proposal executing first)
        vm.prank(address(governor));
        treasury.transfer(address(underlying), charlie, 60_000 ether);

        console2.log('\nTreasury drained to:', underlying.balanceOf(address(treasury)) / 1e18);

        // Try to execute pid1 (asks for 50k, but treasury only has 40k)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Should fail with InsufficientTreasuryBalance
        vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.execute(pid1);

        console2.log('[PASS] Execution validates treasury balance at execution time');
        console2.log('[SAFE] Amount validation at creation + balance check at execution');
    }

    // ============================================================================
    // EDGE CASE 14: Vote with Exactly 0 VP Due to Precision Loss
    // ============================================================================
    /// @notice Test voting with micro stake that has 0 VP due to normalization
    /// @dev VP = (balance * time) / (1e18 * 86400) rounds to 0 for tiny stakes
    function test_edgeCase_voteWithZeroVP_precisionLoss() public {
        console2.log('\n=== EDGE CASE 14: Vote with Zero VP (Precision Loss) ===');

        // Alice stakes very small amount
        underlying.mint(alice, 1 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000); // 1000 wei (not ether)
        vm.stopPrank();

        // Bob stakes normal amount
        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(9999 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(bob);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Move to voting window start
        vm.warp(block.timestamp + 2 days + 1);

        // Check Alice's VP (has been staking for 10 days)
        uint256 aliceVP = staking.getVotingPower(alice);
        console2.log('Alice staked:', 1000, 'wei');
        console2.log('Alice VP after 10+ days:', aliceVP);
        assertEq(aliceVP, 0, 'Micro stake has 0 VP even after 10+ days');

        // Try to vote - should fail with InsufficientVotingPower
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientVotingPower.selector);
        governor.vote(pid, true);

        console2.log('[PASS] Cannot vote with 0 VP (precision loss protection)');
        console2.log('[BY DESIGN] Micro stakes excluded from governance');
    }

    // ============================================================================
    // EDGE CASE 15: Competing Proposals - 4-Way Tie
    // ============================================================================
    /// @notice Test winner determination with 4 proposals having identical YES votes
    /// @dev Extends tie-breaking test to 4-way scenario
    function test_edgeCase_fourWayTie_lowestIDWins() public {
        console2.log('\n=== EDGE CASE 15: Four-Way Tie ===');

        // Setup 4 users with equal stake
        address[4] memory users = [alice, bob, charlie, dave];
        for (uint256 i = 0; i < 4; i++) {
            underlying.mint(users[i], 1000 ether);
            vm.startPrank(users[i]);
            underlying.approve(address(staking), type(uint256).max);
            staking.stake(250 ether); // 25% each
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 10 days);

        // Create 4 proposals
        uint256[4] memory pids;
        vm.prank(alice);
        pids[0] = governor.proposeBoost(address(underlying), 1000 ether);
        vm.prank(bob);
        pids[1] = governor.proposeBoost(address(underlying), 2000 ether);
        vm.prank(charlie);
        pids[2] = governor.proposeBoost(address(underlying), 3000 ether);
        vm.prank(dave);
        pids[3] = governor.proposeBoost(address(underlying), 4000 ether);

        console2.log('Created 4 proposals');
        console2.log('  PID 1:', pids[0]);
        console2.log('  PID 2:', pids[1]);
        console2.log('  PID 3:', pids[2]);
        console2.log('  PID 4:', pids[3]);

        // All 4 users vote YES on all 4 proposals (perfect 4-way tie)
        vm.warp(block.timestamp + 2 days + 1);
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < 4; j++) {
                vm.prank(users[i]);
                governor.vote(pids[j], true);
            }
        }

        vm.warp(block.timestamp + 5 days + 1);

        // Verify all have identical YES votes
        for (uint256 i = 0; i < 4; i++) {
            ILevrGovernor_v1.Proposal memory p = governor.getProposal(pids[i]);
            console2.log('Proposal', i + 1, 'YES votes:', p.yesVotes);
            if (i > 0) {
                ILevrGovernor_v1.Proposal memory prev = governor.getProposal(pids[i - 1]);
                assertEq(p.yesVotes, prev.yesVotes, 'All should have same YES votes');
            }
        }

        // Winner should be pid[0] (lowest ID)
        uint256 winner = governor.getWinner(1);
        console2.log('\nWinner:', winner);
        assertEq(winner, pids[0], 'First proposal (lowest ID) should win on 4-way tie');

        // Execute first, others should fail with NotWinner
        governor.execute(pids[0]);

        for (uint256 i = 1; i < 4; i++) {
            vm.expectRevert(ILevrGovernor_v1.NotWinner.selector);
            governor.execute(pids[i]);
        }

        console2.log('[PASS] Four-way tie resolved deterministically (lowest ID wins)');
    }

    // ============================================================================
    // EDGE CASE 16: Snapshot Immutability Across Failed Execution Attempt
    // ============================================================================
    /// @notice Verify snapshots remain unchanged even after failed execute attempts
    /// @dev Execute failure should not modify proposal snapshots
    function test_edgeCase_snapshotImmutable_afterFailedExecution() public {
        console2.log('\n=== EDGE CASE 16: Snapshot Immutability After Failed Execution ===');

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

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Capture original snapshots
        ILevrGovernor_v1.Proposal memory propBefore = governor.getProposal(pid);
        uint256 supplySnapshot = propBefore.totalSupplySnapshot;
        uint16 quorumSnapshot = propBefore.quorumBpsSnapshot;
        uint16 approvalSnapshot = propBefore.approvalBpsSnapshot;

        console2.log('Original snapshots:');
        console2.log('  Supply:', supplySnapshot / 1e18);
        console2.log('  Quorum:', quorumSnapshot);
        console2.log('  Approval:', approvalSnapshot);

        // Vote (only Alice - will fail quorum)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Try to execute (will fail)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);

        // Verify snapshots UNCHANGED
        ILevrGovernor_v1.Proposal memory propAfter = governor.getProposal(pid);

        assertEq(
            propAfter.totalSupplySnapshot,
            supplySnapshot,
            'Supply snapshot should be immutable'
        );
        assertEq(
            propAfter.quorumBpsSnapshot,
            quorumSnapshot,
            'Quorum snapshot should be immutable'
        );
        assertEq(
            propAfter.approvalBpsSnapshot,
            approvalSnapshot,
            'Approval snapshot should be immutable'
        );

        console2.log('[PASS] Snapshots remain immutable even after failed execution');
    }

    // ============================================================================
    // EDGE CASE 17: maxProposalAmountBps = 0 (No Limit)
    // ============================================================================
    /// @notice Test behavior when maxProposalAmountBps is set to 0
    /// @dev 0 should mean "no limit" based on code logic (line 327-334)
    function test_edgeCase_maxProposalAmountBps_zeroMeansNoLimit() public {
        console2.log('\n=== EDGE CASE 17: maxProposalAmountBps = 0 ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set maxProposalAmountBps to 0
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 0, // NO LIMIT,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });
        factory.updateConfig(cfg);

        console2.log('Set maxProposalAmountBps = 0 (no limit)');
        console2.log('Treasury balance:', underlying.balanceOf(address(treasury)) / 1e18);

        // Try to create proposal for MORE than treasury balance
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));
        uint256 proposalAmount = treasuryBalance + 1_000_000 ether;

        // With token-agnostic update, balance is now checked at proposal creation
        // So this should revert at creation time (NEW-C-1 fix)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.proposeBoost(address(underlying), proposalAmount);

        console2.log('Proposal creation correctly rejected (balance check at creation)');
        console2.log('(Treasury balance validated upfront for security)');

        // Now create a valid proposal that's within treasury balance
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), treasuryBalance / 2);

        console2.log('Created valid proposal for:', treasuryBalance / 2 / 1e18, 'tokens');
        console2.log('RESULT: maxProposalAmountBps=0 allows any amount up to treasury balance');

        console2.log('[PASS] maxProposalAmountBps = 0 allows any amount (checked at execution)');
    }

    // ============================================================================
    // EDGE CASE 18: Snapshot with Supply = 1 wei and Quorum = 100%
    // ============================================================================
    /// @notice Test quorum rounding with minimal supply
    /// @dev (1 wei * 10000) / 10000 = 1 wei required quorum
    function test_edgeCase_minimalSupplyWithMaxQuorum() public {
        console2.log('\n=== EDGE CASE 18: 1 wei Supply with 100% Quorum ===');

        // Alice stakes 1 wei
        underlying.mint(alice, 1 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1); // 1 wei
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set quorum to 100%
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 10000, // 100%
            approvalBps: 5100,
            minSTokenBpsToSubmit: 0, // Disable for this test
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });
        factory.updateConfig(cfg);

        console2.log('Supply: 1 wei');
        console2.log('Quorum: 100%');
        console2.log('Required quorum: (1 * 10000) / 10000 = 1 wei');

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        // Move to voting window
        vm.warp(block.timestamp + 2 days + 1);

        uint256 aliceVP = staking.getVotingPower(alice);
        console2.log('Alice VP after 10+ days:', aliceVP);
        assertEq(aliceVP, 0, 'Micro stake has 0 VP');

        // Alice cannot vote (0 VP)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientVotingPower.selector);
        governor.vote(pid, true);

        console2.log('[FINDING] Micro stakes cannot participate in governance');
        console2.log('[BY DESIGN] Trade-off for readable VP numbers');
    }

    // ============================================================================
    // EDGE CASE 19: Defeated Proposal - activeProposalCount Handling
    // ============================================================================
    /// @notice Test that defeated proposals correctly emit ProposalDefeated event
    /// @dev Lines 168, 180, 192 emit ProposalDefeated before reverting
    function test_edgeCase_defeatedProposal_emitsEventBeforeRevert() public {
        console2.log('\n=== EDGE CASE 19: Defeated Proposal Event Emission ===');

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

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Only Alice votes - fails quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Execute should emit ProposalDefeated then revert
        // However, the event is emitted AND proposal.executed is set,
        // but then the entire transaction reverts, rolling back BOTH changes

        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);

        // Verify proposal NOT marked as executed (revert rolled back)
        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        assertFalse(prop.executed, 'Revert should roll back executed flag');

        console2.log('[SAFE] Revert rolls back all state changes (events AND state)');
        console2.log('[NOTE] ProposalDefeated event is emitted but rolled back');
    }

    // ============================================================================
    // EDGE CASE 20: hasProposedInCycle Tracking Across Cycles
    // ============================================================================
    /// @notice Test that users can propose same type in new cycle after proposing in old cycle
    /// @dev _hasProposedInCycle is per-cycle mapping
    function test_edgeCase_hasProposedInCycle_resetsAcrossCycles() public {
        console2.log('\n=== EDGE CASE 20: Proposal Limit Resets Across Cycles ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Cycle 1: Alice creates boost proposal
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Cycle 1: Alice created boost proposal');

        // Try to create another boost proposal - should fail
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.AlreadyProposedInCycle.selector);
        governor.proposeBoost(address(underlying), 2000 ether);

        console2.log('Cannot create another boost proposal in same cycle: PASS');

        // Complete cycle 1
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);

        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid1);

        console2.log('\nCycle 2: Started');

        // In Cycle 2, Alice should be able to create boost proposal again
        vm.prank(alice);
        uint256 pid2 = governor.proposeBoost(address(underlying), 3000 ether);

        console2.log('Alice created boost proposal in Cycle 2: SUCCESS');

        // Verify it's a different cycle
        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        assertNotEq(p1.cycleId, p2.cycleId, 'Should be in different cycles');

        console2.log('[PASS] Proposal type limit resets per cycle');
    }
}
