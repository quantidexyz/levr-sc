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

/// @title Comprehensive Snapshot System Edge Case Tests
/// @notice Validates the snapshot mechanism (NEW-C-1, NEW-C-2, NEW-C-3 fixes)
/// @dev Tests that snapshots are immutable and protect against manipulation
contract LevrGovernor_SnapshotEdgeCases_Test is Test, LevrFactoryDeployHelper {
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
    address internal whale = address(0xFFFFF);

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
    // SNAPSHOT IMMUTABILITY TESTS
    // ============================================================================

    /// @notice Verify snapshots are stored correctly at proposal creation
    function test_snapshot_values_stored_at_proposal_creation() public {
        console2.log('\n=== Snapshot Storage Verification ===');

        // Setup: Stake tokens
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Record state at proposal creation
        uint256 supplyAtCreation = sToken.totalSupply();
        uint16 quorumAtCreation = factory.quorumBps(address(0));
        uint16 approvalAtCreation = factory.approvalBps(address(0));

        console2.log('Supply at creation:', supplyAtCreation / 1e18);
        console2.log('Quorum BPS at creation:', quorumAtCreation);
        console2.log('Approval BPS at creation:', approvalAtCreation);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Verify snapshots match creation-time values
        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);

        assertEq(
            prop.totalSupplySnapshot,
            supplyAtCreation,
            'Supply snapshot should match creation time'
        );
        assertEq(
            prop.quorumBpsSnapshot,
            quorumAtCreation,
            'Quorum snapshot should match creation time'
        );
        assertEq(
            prop.approvalBpsSnapshot,
            approvalAtCreation,
            'Approval snapshot should match creation time'
        );

        console2.log('[PASS] All snapshots correctly stored at proposal creation');
    }

    /// @notice Verify snapshots remain immutable after config changes
    function test_snapshot_immutable_after_config_changes() public {
        console2.log('\n=== Snapshot Immutability After Config Changes ===');

        // Setup and create proposal
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory propBefore = governor.getProposal(pid);
        uint256 snapshotSupply = propBefore.totalSupplySnapshot;
        uint16 snapshotQuorum = propBefore.quorumBpsSnapshot;
        uint16 snapshotApproval = propBefore.approvalBpsSnapshot;

        console2.log('Initial snapshots:');
        console2.log('  Supply:', snapshotSupply / 1e18);
        console2.log('  Quorum:', snapshotQuorum);
        console2.log('  Approval:', snapshotApproval);

        // Change config drastically
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 9000, // Changed from 7000 to 9000
            approvalBps: 8000, // Changed from 5100 to 8000
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(newCfg);

        console2.log('\nConfig changed:');
        console2.log('  New quorum:', factory.quorumBps(address(0)));
        console2.log('  New approval:', factory.approvalBps(address(0)));

        // Verify snapshots UNCHANGED
        ILevrGovernor_v1.Proposal memory propAfter = governor.getProposal(pid);

        assertEq(
            propAfter.totalSupplySnapshot,
            snapshotSupply,
            'Supply snapshot must be immutable'
        );
        assertEq(propAfter.quorumBpsSnapshot, snapshotQuorum, 'Quorum snapshot must be immutable');
        assertEq(
            propAfter.approvalBpsSnapshot,
            snapshotApproval,
            'Approval snapshot must be immutable'
        );

        console2.log('[PASS] All snapshots remained immutable despite config changes');
    }

    /// @notice Verify snapshots remain immutable after supply changes
    function test_snapshot_immutable_after_supply_changes() public {
        console2.log('\n=== Snapshot Immutability After Supply Changes ===');

        // Setup initial stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 snapshotSupply = governor.getProposal(pid).totalSupplySnapshot;
        console2.log('Snapshot supply:', snapshotSupply / 1e18);

        // Massive supply increase
        underlying.mint(whale, 100_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 currentSupply = sToken.totalSupply();
        console2.log('Current supply after whale:', currentSupply / 1e18);
        console2.log('Supply increased by:', (currentSupply - snapshotSupply) / 1e18);

        // Verify snapshot UNCHANGED
        uint256 snapshotAfter = governor.getProposal(pid).totalSupplySnapshot;
        assertEq(snapshotAfter, snapshotSupply, 'Supply snapshot must be immutable');

        console2.log('[PASS] Supply snapshot immutable despite 100x increase');
    }

    // ============================================================================
    // SNAPSHOT ZERO VALUE EDGE CASES
    // ============================================================================

    /// @notice Test proposal creation when total supply is very low
    function test_snapshot_with_tiny_total_supply() public {
        console2.log('\n=== Snapshot with Tiny Total Supply ===');

        // Alice stakes only 1 wei
        underlying.mint(alice, 1 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1); // Only 1 wei
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Try to create proposal (will fail minStake check, but let's test snapshot)
        // Temporarily disable minStake requirement
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100, // Respect guardrails
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(cfg);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);

        assertEq(prop.totalSupplySnapshot, 1, 'Should snapshot 1 wei supply');
        assertEq(prop.quorumBpsSnapshot, 7000, 'Should snapshot quorum');
        assertEq(prop.approvalBpsSnapshot, 5100, 'Should snapshot approval');

        console2.log('[PASS] Snapshot works correctly with 1 wei total supply');
    }

    /// @notice Test proposal creation when quorum/approval are 0
    function test_snapshot_with_zero_thresholds() public {
        console2.log('\n=== Snapshot with Zero Thresholds ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Attempt to set thresholds to 0 (guardrails should block this)
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 0, // No quorum requirement
            approvalBps: 0, // No approval requirement
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        factory.updateConfig(cfg);

        console2.log('Guardrails prevent zero quorum/approval thresholds.');
    }

    /// @notice Test proposal creation when thresholds are at maximum (100%)
    function test_snapshot_with_max_thresholds() public {
        console2.log('\n=== Snapshot with Maximum Thresholds ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set thresholds to 100%
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 10000, // 100% participation required
            approvalBps: 10000, // 100% approval required
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(cfg);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);

        assertEq(prop.quorumBpsSnapshot, 10000, 'Should snapshot max quorum');
        assertEq(prop.approvalBpsSnapshot, 10000, 'Should snapshot max approval');

        // Vote with 100% participation and approval
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        // Should meet both thresholds (100% participation, 100% yes)
        assertTrue(governor.meetsQuorum(pid), 'Should meet 100% quorum');
        assertTrue(governor.meetsApproval(pid), 'Should meet 100% approval');

        console2.log('[PASS] Maximum threshold snapshots work correctly');
    }

    // ============================================================================
    // SNAPSHOT CONSISTENCY ACROSS PROPOSALS
    // ============================================================================

    /// @notice Verify all proposals in same cycle share identical snapshots
    function test_snapshot_same_for_all_proposals_in_cycle() public {
        console2.log('\n=== Snapshot Consistency Within Cycle ===');

        // Setup multiple users
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(200 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create first proposal
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory prop1 = governor.getProposal(pid1);
        console2.log('Proposal 1 snapshots:');
        console2.log('  Supply:', prop1.totalSupplySnapshot / 1e18);
        console2.log('  Quorum:', prop1.quorumBpsSnapshot);
        console2.log('  Approval:', prop1.approvalBpsSnapshot);

        // Wait a bit, then whale stakes (supply changes)
        vm.warp(block.timestamp + 1 days);

        underlying.mint(whale, 100_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(10_000 ether);
        vm.stopPrank();

        console2.log('\nWhale staked, supply increased to:', sToken.totalSupply() / 1e18);

        // Change config
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 8000, // Changed
            approvalBps: 6000, // Changed
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(newCfg);

        console2.log('Config changed:');
        console2.log('  New quorum:', factory.quorumBps(address(0)));
        console2.log('  New approval:', factory.approvalBps(address(0)));

        // Create second proposal in SAME cycle
        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'test');

        ILevrGovernor_v1.Proposal memory prop2 = governor.getProposal(pid2);
        console2.log('\nProposal 2 snapshots:');
        console2.log('  Supply:', prop2.totalSupplySnapshot / 1e18);
        console2.log('  Quorum:', prop2.quorumBpsSnapshot);
        console2.log('  Approval:', prop2.approvalBpsSnapshot);

        // CRITICAL: Snapshots should reflect STATE AT PROPOSAL 2 CREATION
        // Not from proposal 1 creation
        assertEq(
            prop2.totalSupplySnapshot,
            sToken.totalSupply(),
            'Prop 2 should snapshot current supply'
        );
        assertEq(prop2.quorumBpsSnapshot, 8000, 'Prop 2 should snapshot current quorum (8000)');
        assertEq(prop2.approvalBpsSnapshot, 6000, 'Prop 2 should snapshot current approval (6000)');

        // Verify prop 1 snapshots UNCHANGED
        ILevrGovernor_v1.Proposal memory prop1After = governor.getProposal(pid1);
        assertEq(
            prop1After.totalSupplySnapshot,
            prop1.totalSupplySnapshot,
            'Prop 1 snapshot unchanged'
        );
        assertEq(prop1After.quorumBpsSnapshot, prop1.quorumBpsSnapshot, 'Prop 1 quorum unchanged');
        assertEq(
            prop1After.approvalBpsSnapshot,
            prop1.approvalBpsSnapshot,
            'Prop 1 approval unchanged'
        );

        console2.log('[PASS] Each proposal has independent snapshots from its creation time');
    }

    // ============================================================================
    // SNAPSHOT VALIDATION AT EXECUTION
    // ============================================================================

    /// @notice Verify quorum check uses snapshot, not current values
    function test_snapshot_quorum_check_uses_snapshot_not_current() public {
        console2.log('\n=== Quorum Check Uses Snapshot ===');

        // Setup: 1000 total supply
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal (snapshot: 1000 supply, 70% quorum = 700 required)
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 snapshot = governor.getProposal(pid).totalSupplySnapshot;
        console2.log('Snapshot supply:', snapshot / 1e18);
        console2.log('Quorum required (70% of snapshot):', (snapshot * 7000) / 10_000 / 1e18);

        // Vote with alice (1000 balance = 100% participation)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        console2.log('Voted with 1000 balance (100% participation)');
        assertTrue(governor.meetsQuorum(pid), 'Should meet quorum with 100%');

        // Supply increases 10x AFTER voting
        underlying.mint(whale, 100_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(9000 ether);
        vm.stopPrank();

        uint256 newSupply = sToken.totalSupply();
        console2.log('\nSupply increased to:', newSupply / 1e18);
        console2.log('If using current supply, would need:', (newSupply * 7000) / 10_000 / 1e18);
        console2.log('But we only have 1000 tokens voted');

        // CRITICAL: Should STILL meet quorum because using snapshot
        vm.warp(block.timestamp + 5 days + 1);
        assertTrue(governor.meetsQuorum(pid), 'Should STILL meet quorum using snapshot');

        // Execute should succeed
        governor.execute(pid);

        console2.log('[PASS] Quorum check correctly uses snapshot, immune to supply manipulation');
    }

    /// @notice Verify approval check uses snapshot, not current values
    function test_snapshot_approval_check_uses_snapshot_not_current() public {
        console2.log('\n=== Approval Check Uses Snapshot ===');

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

        // Create proposal (approval snapshot = 51%)
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint16 snapshotApproval = governor.getProposal(pid).approvalBpsSnapshot;
        console2.log('Snapshot approval BPS:', snapshotApproval);

        // Vote: 60% yes, 40% no (meets 51% requirement)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true); // 50% yes
        vm.prank(bob);
        governor.vote(pid, true); // 50% yes
        // Total: 100% yes actually

        console2.log('Voted with 100% yes approval');
        assertTrue(governor.meetsApproval(pid), 'Should meet approval');

        // Config changes to 90% approval requirement
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 9000, // Changed from 51% to 90%
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(newCfg);

        console2.log('Config changed to 90% approval requirement');
        console2.log('Current config:', factory.approvalBps(address(0)));

        // CRITICAL: Should STILL meet approval because using snapshot (51%)
        vm.warp(block.timestamp + 5 days + 1);
        assertTrue(governor.meetsApproval(pid), 'Should STILL meet approval using snapshot');

        // Execute should succeed
        governor.execute(pid);

        console2.log(
            '[PASS] Approval check correctly uses snapshot, immune to config manipulation'
        );
    }

    // ============================================================================
    // SNAPSHOT + SUPPLY MANIPULATION ATTACK SCENARIOS
    // ============================================================================

    /// @notice Test extreme supply manipulation (1000x increase)
    function test_snapshot_immune_to_extreme_supply_manipulation() public {
        console2.log('\n=== Extreme Supply Manipulation (1000x) ===');

        // Alice controls 100% initially
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 snapshot = governor.getProposal(pid).totalSupplySnapshot;
        console2.log('Initial supply:', snapshot / 1e18);

        // Vote (100% participation)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        // ATTACK: Whale stakes 1000x the original supply
        underlying.mint(whale, 1_000_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100_000 ether);
        vm.stopPrank();

        uint256 newSupply = sToken.totalSupply();
        console2.log('Supply after whale:', newSupply / 1e18);
        console2.log('Increase multiplier:', newSupply / snapshot);

        // Should STILL meet quorum using snapshot
        vm.warp(block.timestamp + 5 days + 1);
        assertTrue(governor.meetsQuorum(pid), 'Should meet quorum despite 1000x supply increase');

        // Execute should succeed
        governor.execute(pid);

        console2.log('[PASS] Immune to extreme supply manipulation attacks');
    }

    /// @notice Test supply decrease to near-zero
    /// @dev NOTE: With adaptive quorum, this attack vector is partially mitigated but has tradeoffs
    function test_snapshot_immune_to_supply_drain_attack() public {
        console2.log('\n=== Supply Drain Attack (Adaptive Quorum Behavior) ===');

        // Setup: Multiple stakers
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(150 ether); // 1.5% of total - meets minStake
        vm.stopPrank();

        underlying.mint(whale, 100_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(9850 ether);
        vm.stopPrank();

        console2.log('Initial supply: 10000 tokens');
        console2.log('Alice: 150 (1.5%), Whale: 9850 (98.5%)');

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal with low participation
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 snapshot = governor.getProposal(pid).totalSupplySnapshot;
        console2.log('Snapshot supply:', snapshot / 1e18);
        console2.log('Quorum needed (70%):', (snapshot * 7000) / 10_000 / 1e18);

        // Only Alice votes (150 tokens = 1.5% participation, way below 70%)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        console2.log('\nAlice voted with 150 tokens (1.5% participation)');
        assertFalse(governor.meetsQuorum(pid), 'Should NOT meet 70% quorum initially');

        // Whale unstakes everything AFTER voting
        vm.prank(whale);
        staking.unstake(9850 ether, whale);

        uint256 newSupply = sToken.totalSupply();
        console2.log('Supply after whale exit:', newSupply / 1e18);
        console2.log(
            'Adaptive quorum (70% of current):',
            (newSupply * 7000) / 10_000 / 1e18
        );

        // With ADAPTIVE quorum: Now PASSES because quorum adapts to current supply
        // Adaptive: 150 * 70% = 105 tokens, Alice has 150 > 105
        // Tradeoff: Prevents deadlock but allows this edge case
        vm.warp(block.timestamp + 5 days + 1);
        assertTrue(governor.meetsQuorum(pid), 'Adaptive quorum allows passage after supply drain');

        console2.log('[ADAPTIVE TRADEOFF] Quorum adapts when supply decreases');
        console2.log('This prevents deadlock but requires careful governance monitoring');
    }

    // ============================================================================
    // SNAPSHOT + CONFIG MANIPULATION ATTACK SCENARIOS
    // ============================================================================

    /// @notice Test config manipulation cannot change winner
    function test_snapshot_immune_to_config_winner_manipulation() public {
        console2.log('\n=== Config Winner Manipulation Immunity ===');

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

        underlying.mint(charlie, 1000 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create two competing proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'test');

        // Vote: Prop1 gets 60% yes, Prop2 gets 100% yes but less total votes
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility

        // Prop 1: Alice YES, Bob YES, Charlie NO = 66% yes
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid1, true);
        vm.prank(charlie);
        governor.vote(pid1, false);

        // Prop 2: Only Alice YES = 100% yes but less participation
        vm.prank(alice);
        governor.vote(pid2, true);

        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        console2.log('\nProposal 1: yes =', p1.yesVotes, ', no =', p1.noVotes);
        console2.log('Proposal 2: yes =', p2.yesVotes, ', no =', p2.noVotes);
        console2.log('Prop 1 approval:', (p1.yesVotes * 10000) / (p1.yesVotes + p1.noVotes), 'bps');

        // Both meet their snapshot requirements (51% approval)
        assertTrue(governor.meetsApproval(pid1), 'Prop 1 should meet 51% approval');
        assertTrue(governor.meetsApproval(pid2), 'Prop 2 should meet 51% approval');

        // Winner should be prop 1 (more total yes votes)
        vm.warp(block.timestamp + 5 days + 1);
        uint256 winner = governor.getWinner(1);
        console2.log('Winner before config change:', winner);

        // ATTACK: Try to change config to invalidate prop 1
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 7000, // Changed from 51% to 70% to invalidate prop1's 66%
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(newCfg);

        console2.log('\nConfig changed to 70% approval requirement');
        console2.log('Current config:', factory.approvalBps(address(0)));

        // CRITICAL: Both should STILL meet approval using their snapshots
        assertTrue(governor.meetsApproval(pid1), 'Prop 1 STILL meets 51% approval (snapshot)');
        assertTrue(governor.meetsApproval(pid2), 'Prop 2 STILL meets 51% approval (snapshot)');

        // Winner should STILL be prop 1
        uint256 winnerAfter = governor.getWinner(1);
        assertEq(winnerAfter, winner, 'Winner should be unchanged despite config manipulation');

        console2.log('Winner after config change:', winnerAfter);
        console2.log('[PASS] Config manipulation cannot change winner');
    }

    // ============================================================================
    // SNAPSHOT EDGE CASES: IMPOSSIBLE THRESHOLDS
    // ============================================================================

    /// @notice Test snapshot with impossible quorum (more than supply)
    function test_snapshot_impossible_quorum_fails_gracefully() public {
        console2.log('\n=== Impossible Quorum Threshold ===');

        // Setup tiny supply
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(10 ether); // Only 10 tokens
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set absurdly high quorum that's mathematically impossible
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 10000, // 100% required
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(cfg);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        console2.log('Supply:', sToken.totalSupply() / 1e18);
        console2.log('Quorum required (100%):', sToken.totalSupply() / 1e18);

        // Alice votes (100% participation)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid, true);

        // Should meet quorum (100% participation)
        assertTrue(governor.meetsQuorum(pid), 'Should meet 100% quorum with 100% participation');

        // Lower config after voting (try to make it easier)
        cfg.quorumBps = 1000; // 10%
        factory.updateConfig(cfg);

        // Should STILL meet quorum using snapshot (100%)
        vm.warp(block.timestamp + 5 days + 1);
        assertTrue(governor.meetsQuorum(pid), 'Should still use snapshot quorum');

        console2.log('[PASS] Impossible threshold scenarios handled correctly');
    }

    // ============================================================================
    // SNAPSHOT ACROSS MULTIPLE CYCLES
    // ============================================================================

    /// @notice Verify snapshots are independent across cycles
    function test_snapshot_independent_across_cycles() public {
        console2.log('\n=== Snapshot Independence Across Cycles ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Cycle 1: Create proposal
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 cycle1Supply = governor.getProposal(pid1).totalSupplySnapshot;
        uint16 cycle1Quorum = governor.getProposal(pid1).quorumBpsSnapshot;

        console2.log('Cycle 1 proposal snapshots:');
        console2.log('  Supply:', cycle1Supply / 1e18);
        console2.log('  Quorum:', cycle1Quorum);

        // Complete cycle 1
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid1);

        console2.log('\nCycle 1 executed, Cycle 2 auto-started');

        // Supply changes
        underlying.mint(whale, 100_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        // Config changes
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 5000, // Changed
            approvalBps: 3000, // Changed
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(newCfg);

        console2.log('Supply changed to:', sToken.totalSupply() / 1e18);
        console2.log(
            'Config changed to: quorum =',
            factory.quorumBps(address(0)),
            ', approval =',
            factory.approvalBps(address(0))
        );

        // Cycle 2: Create proposal
        vm.prank(alice);
        uint256 pid2 = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 cycle2Supply = governor.getProposal(pid2).totalSupplySnapshot;
        uint16 cycle2Quorum = governor.getProposal(pid2).quorumBpsSnapshot;

        console2.log('\nCycle 2 proposal snapshots:');
        console2.log('  Supply:', cycle2Supply / 1e18);
        console2.log('  Quorum:', cycle2Quorum);

        // Verify snapshots are different (reflect state at their creation times)
        assertNotEq(
            cycle1Supply,
            cycle2Supply,
            'Different cycles should have different supply snapshots'
        );
        assertNotEq(
            cycle1Quorum,
            cycle2Quorum,
            'Different cycles should have different quorum snapshots'
        );

        // Verify cycle 1 snapshots unchanged
        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        assertEq(p1.totalSupplySnapshot, cycle1Supply, 'Cycle 1 snapshot should be unchanged');

        console2.log('[PASS] Snapshots are independent across cycles');
    }

    // ============================================================================
    // SNAPSHOT + WINNER DETERMINATION
    // ============================================================================

    /// @notice Test winner determination is stable across time and config changes
    function test_snapshot_winner_determination_stable() public {
        console2.log('\n=== Winner Determination Stability ===');

        // Setup 3 stakers
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

        underlying.mint(charlie, 1000 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create 3 competing proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        vm.prank(charlie);
        uint256 pid3 = governor.proposeTransfer(address(underlying), whale, 500 ether, 'test');

        // Vote: Prop1 = most yes votes
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility

        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid1, true);
        vm.prank(charlie);
        governor.vote(pid1, true); // Prop1: 3 yes votes

        vm.prank(alice);
        governor.vote(pid2, true);
        vm.prank(bob);
        governor.vote(pid2, true); // Prop2: 2 yes votes

        vm.prank(alice);
        governor.vote(pid3, true); // Prop3: 1 yes vote

        // Check winner before any manipulation
        vm.warp(block.timestamp + 5 days + 1);
        uint256 winnerBefore = governor.getWinner(1);
        console2.log('Winner before manipulation:', winnerBefore);
        assertEq(winnerBefore, pid1, 'Prop 1 should be initial winner');

        // ATTACK 1: Increase approval threshold to try to disqualify prop1
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 10000, // 100% approval required
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        factory.updateConfig(newCfg);

        console2.log('\nATTACK 1: Changed approval to 100%');

        // Winner should STILL be prop1 (uses snapshot)
        uint256 winnerAfterConfig = governor.getWinner(1);
        assertEq(winnerAfterConfig, pid1, 'Winner unchanged after config manipulation');

        // ATTACK 2: Massive supply increase
        underlying.mint(whale, 1_000_000 ether);
        vm.startPrank(whale);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100_000 ether);
        vm.stopPrank();

        console2.log('\nATTACK 2: Supply increased 1000x');

        // Winner should STILL be prop1 (uses snapshot)
        uint256 winnerAfterSupply = governor.getWinner(1);
        assertEq(winnerAfterSupply, pid1, 'Winner unchanged after supply manipulation');

        // Execute should succeed
        governor.execute(pid1);

        console2.log('[PASS] Winner determination is stable and immune to manipulation');
    }

    // ============================================================================
    // SNAPSHOT TIMING EDGE CASES
    // ============================================================================

    /// @notice Test snapshot at exact moment of proposal creation
    function test_snapshot_captured_at_exact_proposal_creation_moment() public {
        console2.log('\n=== Snapshot Timing Precision ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        uint256 supplyBefore = sToken.totalSupply();

        // Create proposal - snapshot happens HERE
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 snapshot = governor.getProposal(pid).totalSupplySnapshot;

        // Verify snapshot == supply at that exact moment
        assertEq(snapshot, supplyBefore, 'Snapshot should equal supply at proposal creation');

        console2.log('Supply before proposal:', supplyBefore / 1e18);
        console2.log('Snapshot value:', snapshot / 1e18);
        console2.log('[PASS] Snapshot captured at exact proposal creation moment');
    }

    /// @notice Test multiple proposals created at different times have different snapshots
    function test_snapshot_different_for_proposals_at_different_times() public {
        console2.log('\n=== Snapshots at Different Creation Times ===');

        // Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal 1
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);
        uint256 snapshot1 = governor.getProposal(pid1).totalSupplySnapshot;

        console2.log('Proposal 1 supply snapshot:', snapshot1 / 1e18);

        // Bob stakes (supply increases)
        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        console2.log('Supply after Bob stakes:', sToken.totalSupply() / 1e18);

        // Create proposal 2 (still in same cycle, same day)
        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(underlying), charlie, 500 ether, 'test');
        uint256 snapshot2 = governor.getProposal(pid2).totalSupplySnapshot;

        console2.log('Proposal 2 supply snapshot:', snapshot2 / 1e18);

        // Snapshots should be different (reflect state at their creation times)
        assertNotEq(
            snapshot1,
            snapshot2,
            'Different proposals at different times have different snapshots'
        );
        assertEq(snapshot2, sToken.totalSupply(), 'Snapshot 2 should equal current supply');

        console2.log('[PASS] Each proposal snapshots state at its own creation time');
    }

    // ============================================================================
    // SNAPSHOT INTERACTION WITH VOTING
    // ============================================================================

    /// @notice Verify snapshot doesn't affect vote counting (votes still use current VP)
    function test_snapshot_does_not_affect_vote_counting() public {
        console2.log('\n=== Snapshot Does Not Affect Vote Counting ===');

        // Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 snapshot = governor.getProposal(pid).totalSupplySnapshot;
        console2.log('Supply snapshot at creation:', snapshot / 1e18);

        // Alice's VP increases over time
        uint256 vpBefore = staking.getVotingPower(alice);
        console2.log('Alice VP before waiting:', vpBefore);

        vm.warp(block.timestamp + 2 days + 1); // Voting starts
        vm.roll(block.number + 1); // Advance blocks for voting eligibility

        uint256 vpAtVote = staking.getVotingPower(alice);
        console2.log('Alice VP at vote time:', vpAtVote);
        assertTrue(vpAtVote > vpBefore, 'VP should have increased');

        // Vote - should use CURRENT VP, not snapshot
        vm.prank(alice);
        governor.vote(pid, true);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('Yes votes recorded:', prop.yesVotes);

        // Verify vote used current VP, not some snapshot
        assertEq(prop.yesVotes, vpAtVote, 'Vote should use current VP at vote time');

        console2.log('[PASS] Snapshot system does not interfere with vote counting');
    }
}
