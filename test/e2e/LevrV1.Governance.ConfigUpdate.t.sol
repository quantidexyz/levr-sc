// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Tests for governance config updates during active cycles
/// @dev Verifies that factory config updates don't break in-progress governance flows

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrTreasury_v1} from '../../src/interfaces/ILevrTreasury_v1.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IClankerAirdrop} from '../../src/interfaces/external/IClankerAirdrop.sol';
import {MerkleAirdropHelper} from '../utils/MerkleAirdropHelper.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrV1_Governance_ConfigUpdateE2E is BaseForkTest, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;

    address internal protocolTreasury = address(0xFEE);
    address internal clankerToken;
    address internal governor;
    address internal treasury;
    address internal staking;
    address internal stakedToken;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC4A511E);
    address internal factoryOwner = address(0x0FFFF);

    address constant CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
    address constant AIRDROP_EXTENSION = 0xf652B3610D75D81871bf96DB50825d9af28391E0;

    function setUp() public override {
        super.setUp();

        // Create factory with governance parameters (factory owner is deployer)
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000, // 70% participation required
            approvalBps: 5100, // 51% approval required
            minSTokenBpsToSubmit: 100, // 1% of supply required to propose
            maxProposalAmountBps: 1000, // 10% of supply max proposal amount
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        (factory, forwarder, levrDeployer) = deployFactory(cfg, factoryOwner, CLANKER_FACTORY);

        // Deploy complete Levr ecosystem with Clanker token + airdrop to treasury
        _deployCompleteEcosystem(50_000 ether);
    }

    function _deployCompleteEcosystem(uint256 treasuryAirdropAmount) internal {
        (treasury, staking) = factory.prepareForDeployment();

        bytes32 merkleRoot = MerkleAirdropHelper.singleLeafRoot(treasury, treasuryAirdropAmount);
        bytes memory airdropData = abi.encode(address(this), merkleRoot, 1 days, 0);

        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFullWithOptions({
            clankerFactory: CLANKER_FACTORY,
            tokenAdmin: address(this),
            name: 'Governance Config Test Token',
            symbol: 'GCFG',
            clankerFeeBps: 100,
            pairedFeeBps: 100,
            enableAirdrop: true,
            airdropAdmin: address(this),
            airdropBps: 5000,
            airdropData: airdropData,
            enableDevBuy: false,
            devBuyBps: 0,
            devBuyEthAmount: 0,
            devBuyRecipient: address(0)
        });

        ILevrFactory_v1.Project memory project = factory.register(clankerToken);
        treasury = project.treasury;
        governor = project.governor;
        staking = project.staking;
        stakedToken = project.stakedToken;

        vm.warp(block.timestamp + 1 days + 1);
        bytes32[] memory proof = new bytes32[](0);
        IClankerAirdrop(AIRDROP_EXTENSION).claim(
            clankerToken,
            treasury,
            treasuryAirdropAmount,
            proof
        );

        assertEq(
            IERC20(clankerToken).balanceOf(treasury),
            treasuryAirdropAmount,
            'treasury should have airdrop'
        );
    }

    function _acquireTokens(address to, uint256 amount) internal {
        uint256 treasuryBal = IERC20(clankerToken).balanceOf(treasury);
        uint256 amountToTransfer = amount > treasuryBal ? treasuryBal : amount;
        require(amountToTransfer > 0, 'no tokens in treasury');
        vm.prank(treasury);
        IERC20(clankerToken).transfer(to, amountToTransfer);
    }

    function _stakeFor(address user, uint256 amount) internal {
        _acquireTokens(user, amount);
        uint256 actualBalance = IERC20(clankerToken).balanceOf(user);
        vm.startPrank(user);
        IERC20(clankerToken).approve(staking, actualBalance);
        ILevrStaking_v1(staking).stake(actualBalance);
        vm.stopPrank();
    }

    // ============ Test 1: Quorum Change Mid-Cycle (Before Voting Ends) ============

    function test_e2e_config_update_quorum_increase_mid_cycle_fails_execution() public {
        // Setup: 3 users stake
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 5 ether); // Total: 20 ether

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance block for flash loan protection

        // Alice and Bob vote (15 of 20 = 75% participation - meets 70% quorum)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, true);

        // At this point, proposal meets quorum with 75% participation
        assertTrue(
            ILevrGovernor_v1(governor).meetsQuorum(pid),
            'Should meet 70% quorum with 75% participation'
        );

        // Factory owner increases quorum to 80% mid-cycle
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 8000, // INCREASED from 70% to 80%
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] Quorum increased from 70% to 80% mid-cycle');

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // FIX [NEW-C-3]: With snapshot fix, proposal STILL meets quorum
        // because it uses the 70% threshold from when it was created, not the new 80%
        // This is the CORRECT, SECURE behavior - prevents config manipulation
        assertTrue(
            ILevrGovernor_v1(governor).meetsQuorum(pid),
            'Should still meet 70% quorum (snapshot) even though config changed to 80%'
        );

        // Execution should succeed because snapshot protects against config changes
        ILevrGovernor_v1(governor).execute(pid);

        console2.log(
            '[RESULT] Proposal succeeded - snapshot protects against mid-cycle config changes'
        );
    }

    // ============ Test 2: Quorum Decrease Mid-Cycle (Allows Previously Failing Proposal) ============

    function test_e2e_config_update_quorum_decrease_mid_cycle_allows_execution() public {
        // Setup: 3 users stake
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 10 ether); // Total: 25 ether

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance block for flash loan protection

        // Only Alice votes (5 of 25 = 20% participation - doesn't meet 70% quorum)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        // At this point, proposal doesn't meet quorum
        assertFalse(
            ILevrGovernor_v1(governor).meetsQuorum(pid),
            'Should NOT meet 70% quorum with 20% participation'
        );

        // Factory owner decreases quorum to 10% mid-cycle
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 1000, // DECREASED from 70% to 10%
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] Quorum decreased from 70% to 10% mid-cycle');

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // FIX [NEW-C-3]: With snapshot fix, proposal STILL does NOT meet quorum
        // because it uses the 70% threshold from when it was created, not the new 10%
        // This is the CORRECT, SECURE behavior - prevents config manipulation
        assertFalse(
            ILevrGovernor_v1(governor).meetsQuorum(pid),
            'Should NOT meet 70% quorum (snapshot) even though config changed to 10%'
        );

        // Execution should fail because snapshot protects against config changes
        // FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        ILevrGovernor_v1(governor).execute(pid);

        // Verify marked as executed
        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.executed, true, 'Proposal should be marked as executed');

        console2.log(
            '[RESULT] Proposal still defeated - snapshot protects against mid-cycle config changes'
        );
    }

    // ============ Test 3: Approval Threshold Change Mid-Cycle ============

    function test_e2e_config_update_approval_increase_mid_cycle_fails_execution() public {
        // Setup: 3 users stake
        _stakeFor(alice, 10 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 10 ether); // Total: 30 ether

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance block for flash loan protection

        // All vote: Alice YES, Bob YES, Charlie NO
        // 2/3 of votes = ~66% approval (meets 51% requirement)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid, false);

        // At this point, proposal meets approval with ~66%
        assertTrue(
            ILevrGovernor_v1(governor).meetsApproval(pid),
            'Should meet 51% approval with 66% yes votes'
        );

        // Factory owner increases approval to 70% mid-cycle
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 7000, // INCREASED from 51% to 70%
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] Approval increased from 51% to 70% mid-cycle');

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // FIX [NEW-C-3]: With snapshot fix, proposal STILL meets approval
        // because it uses the 51% threshold from when it was created, not the new 70%
        // This is the CORRECT, SECURE behavior - prevents config manipulation
        assertTrue(
            ILevrGovernor_v1(governor).meetsApproval(pid),
            'Should still meet 51% approval (snapshot) even though config changed to 70%'
        );

        // Execution should succeed because snapshot protects against config changes
        ILevrGovernor_v1(governor).execute(pid);

        console2.log(
            '[RESULT] Proposal succeeded - snapshot protects against mid-cycle config changes'
        );
    }

    // ============ Test 4: MaxActiveProposals Change Mid-Cycle ============

    function test_e2e_config_update_maxActiveProposals_affects_new_proposals_only() public {
        // Setup: Alice stakes enough to propose
        _stakeFor(alice, 15 ether);

        vm.warp(block.timestamp + 10 days);

        // Alice creates first proposal (maxActiveProposals = 7)
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);
        assertGt(pid1, 0, 'First proposal should succeed');

        // Factory owner reduces maxActiveProposals to 1
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 1, // REDUCED from 7 to 1
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] MaxActiveProposals reduced from 7 to 1 mid-cycle');

        // Existing proposal should NOT be affected
        ILevrGovernor_v1.Proposal memory proposal = ILevrGovernor_v1(governor).getProposal(pid1);
        assertEq(proposal.id, pid1, 'Existing proposal should still exist');

        // But alice cannot create ANOTHER BoostStakingPool proposal (limit = 1, count = 1)
        // Note: MaxProposalsReached is checked BEFORE AlreadyProposedInCycle
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
        ILevrGovernor_v1(governor).proposeBoost(clankerToken, 200 ether);

        console2.log(
            '[RESULT] New proposals blocked by reduced limit, existing proposals unaffected'
        );
    }

    // ============ Test 5: MinSTokenBpsToSubmit Change Mid-Cycle ============

    function test_e2e_config_update_minStake_affects_new_proposals_only() public {
        // Setup: Alice stakes 1.5% of supply, Bob stakes rest
        _stakeFor(bob, 15 ether);
        _stakeFor(alice, 5 ether); // Total: 20 ether, Alice has 25% (well above 1%)

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal (meets 1% requirement with 25%)
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);
        assertGt(pid, 0, 'First proposal should succeed');

        // Factory owner increases minStake to 30% (alice now has insufficient stake for NEW proposals)
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 3000, // INCREASED from 1% to 30%
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] MinStake increased from 1% to 30% mid-cycle');

        // Existing proposal should still be valid and executable
        vm.warp(block.timestamp + 2 days + 1); // voting window
        vm.roll(block.number + 1); // Advance block for flash loan protection
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1); // end of voting
        // Should execute successfully despite alice no longer meeting threshold
        ILevrGovernor_v1(governor).execute(pid);

        ILevrGovernor_v1.Proposal memory proposal = ILevrGovernor_v1(governor).getProposal(pid);
        assertTrue(proposal.executed, 'Existing proposal should execute');

        console2.log('[RESULT] Existing proposal executed despite new higher stake requirement');

        // Start new cycle
        vm.warp(block.timestamp + 1);

        // Alice tries to create new proposal in new cycle - should fail (25% < 30%)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientStake.selector);
        ILevrGovernor_v1(governor).proposeTransfer(clankerToken, address(0xBEEF), 50 ether, 'test');

        console2.log('[RESULT] New proposals blocked by increased stake requirement');
    }

    // ============ Test 6: CRITICAL - Two Proposals in Same Cycle After Config Update ============

    function test_e2e_config_update_two_proposals_same_cycle_different_configs() public {
        // Setup: Multiple users stake (need enough for 70% quorum)
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 5 ether); // 20 total - all 3 voting = 100% participation

        vm.warp(block.timestamp + 10 days);

        // Alice creates FIRST proposal with original config (2 day proposal, 5 day voting)
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory p1Before = ILevrGovernor_v1(governor).getProposal(pid1);
        uint256 cycleProposalEnd = p1Before.votingStartsAt; // Should be now + 2 days
        uint256 cycleVotingEnd = p1Before.votingEndsAt; // Should be now + 2 days + 5 days

        console2.log('[STATE] First proposal created:');
        console2.log('  Proposal window ends at:', cycleProposalEnd);
        console2.log('  Voting window ends at:', cycleVotingEnd);

        // Factory owner changes config to shorter windows
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 1 days, // REDUCED from 2 days to 1 day
            votingWindowSeconds: 3 days, // REDUCED from 5 days to 3 days
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] Config updated: proposal 2d->1d, voting 5d->3d');

        // Bob creates SECOND proposal in SAME cycle (still within original 2-day window)
        vm.warp(block.timestamp + 1 days); // Still within original proposal window
        vm.prank(bob);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeTransfer(
            clankerToken,
            address(0xBEEF),
            50 ether,
            'test'
        );

        ILevrGovernor_v1.Proposal memory p2 = ILevrGovernor_v1(governor).getProposal(pid2);

        console2.log('[STATE] Second proposal created after config change:');
        console2.log('  Proposal window ends at:', p2.votingStartsAt);
        console2.log('  Voting window ends at:', p2.votingEndsAt);

        // CRITICAL: Both proposals should use SAME cycle timestamps (original config)
        assertEq(
            p2.votingStartsAt,
            cycleProposalEnd,
            'Second proposal must use same cycle deadline as first'
        );
        assertEq(
            p2.votingEndsAt,
            cycleVotingEnd,
            'Second proposal must use same voting end as first'
        );

        // Also verify first proposal timestamps haven't changed
        ILevrGovernor_v1.Proposal memory p1After = ILevrGovernor_v1(governor).getProposal(pid1);
        assertEq(p1After.votingStartsAt, p1Before.votingStartsAt, 'First proposal unchanged');
        assertEq(p1After.votingEndsAt, p1Before.votingEndsAt, 'First proposal unchanged');

        console2.log('[RESULT] Both proposals share identical cycle-level timestamps');
        console2.log('[RESULT] Config update did NOT break same-cycle proposals');

        // Verify both proposals work with original timeline
        vm.warp(cycleProposalEnd + 1); // Start of voting window
        vm.roll(block.number + 1); // Advance block for flash loan protection

        // All users vote on both proposals (100% participation meets 70% quorum)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid1, false); // Alice+Bob YES wins (66% approval)

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid2, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid2, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid2, true); // All YES (100% approval)

        vm.warp(cycleVotingEnd + 1); // After voting ends

        // Execute winner (pid2 should win with more yes votes)
        uint256 winner = ILevrGovernor_v1(governor).getWinner(1);
        assertEq(winner, pid2, 'Proposal 2 should win (all YES votes)');

        ILevrGovernor_v1(governor).execute(winner);

        assertTrue(
            ILevrGovernor_v1(governor).getProposal(winner).executed,
            'Winner should execute successfully'
        );

        console2.log(
            '[RESULT] Governance flow completed successfully despite mid-cycle config change'
        );
    }

    // ============ Test 7: DETAILED TRACE - How Timestamps Work ============

    function test_e2e_detailed_trace_cycle_vs_proposal_timestamps() public {
        console2.log('\n=== DETAILED TRACE: How Timestamps Work ===\n');

        // Setup
        _stakeFor(alice, 15 ether);
        _stakeFor(bob, 10 ether);
        vm.warp(block.timestamp + 10 days);

        uint256 t0 = block.timestamp;
        console2.log('[T0] Starting time:', t0);
        console2.log('[CONFIG] proposalWindowSeconds: 2 days (172800s)');
        console2.log('[CONFIG] votingWindowSeconds: 5 days (432000s)\n');

        // STEP 1: First proposal auto-creates cycle
        console2.log('=== STEP 1: Alice proposes (auto-creates cycle 1) ===');
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory p1 = ILevrGovernor_v1(governor).getProposal(pid1);
        console2.log('Cycle 1 created at T0:', t0);
        console2.log('  proposalWindowEnd = T0 + 2 days =', p1.votingStartsAt);
        console2.log('  votingWindowEnd = T0 + 2d + 5d =', p1.votingEndsAt);
        console2.log('Proposal 1 timestamps:');
        console2.log('  votingStartsAt:', p1.votingStartsAt, '(from cycle.proposalWindowEnd)');
        console2.log('  votingEndsAt:', p1.votingEndsAt, '(from cycle.votingWindowEnd)\n');

        // STEP 2: Config changes mid-cycle
        console2.log('=== STEP 2: Config updated mid-cycle ===');
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 1 days, // CHANGED: 2d -> 1d
            votingWindowSeconds: 3 days, // CHANGED: 5d -> 3d
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] NEW proposalWindowSeconds: 1 days (86400s)');
        console2.log('[CONFIG] NEW votingWindowSeconds: 3 days (259200s)');
        console2.log('NOTE: Cycle 1 struct is UNCHANGED in storage\n');

        // STEP 3: Second proposal in SAME cycle
        console2.log('=== STEP 3: Bob proposes in same cycle (after config change) ===');
        vm.warp(t0 + 1 days);
        console2.log('Current time:', t0 + 1 days, '(T0 + 1 day)');

        vm.prank(bob);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeTransfer(
            clankerToken,
            address(0xBEEF),
            50 ether,
            'test'
        );

        ILevrGovernor_v1.Proposal memory p2 = ILevrGovernor_v1(governor).getProposal(pid2);
        console2.log('Proposal 2 created at T0 + 1 day');
        console2.log(
            'Proposal 2 reads FROM CYCLE 1 (line 280: Cycle memory cycle = _cycles[cycleId])'
        );
        console2.log('  votingStartsAt:', p2.votingStartsAt, '(from cycle.proposalWindowEnd)');
        console2.log('  votingEndsAt:', p2.votingEndsAt, '(from cycle.votingWindowEnd)');

        // CRITICAL ASSERTION
        console2.log('\n=== CRITICAL VERIFICATION ===');
        assertEq(
            p2.votingStartsAt,
            p1.votingStartsAt,
            'MUST BE EQUAL: Both copy from _cycles[1].proposalWindowEnd'
        );
        assertEq(
            p2.votingEndsAt,
            p1.votingEndsAt,
            'MUST BE EQUAL: Both copy from _cycles[1].votingWindowEnd'
        );
        console2.log('VERIFIED: Both proposals have IDENTICAL timestamps');
        console2.log('  Proposal 1 votingStartsAt:', p1.votingStartsAt);
        console2.log('  Proposal 2 votingStartsAt:', p2.votingStartsAt);
        console2.log(
            '  Difference:',
            p2.votingStartsAt > p1.votingStartsAt
                ? p2.votingStartsAt - p1.votingStartsAt
                : p1.votingStartsAt - p2.votingStartsAt,
            'seconds (should be 0)'
        );

        console2.log('\n=== WHY THIS WORKS ===');
        console2.log('1. _startNewCycle() reads config ONCE and stores in _cycles[cycleId]');
        console2.log('2. _propose() copies FROM _cycles[cycleId], NOT from config');
        console2.log('3. Config changes dont modify existing _cycles[cycleId] structs');
        console2.log('4. Result: All proposals in a cycle share cycle-level timestamps\n');

        // STEP 4: Verify execution works at original timeline
        console2.log('=== STEP 4: Execute at original timeline ===');
        _stakeFor(charlie, 5 ether);

        vm.warp(p1.votingStartsAt + 1);
        console2.log('Voting starts at:', p1.votingStartsAt);

        vm.roll(block.number + 1); // Advance block for flash loan protection
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid1, true);

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid2, false);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid2, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid2, true);

        vm.warp(p1.votingEndsAt + 1);
        console2.log('Voting ends at:', p1.votingEndsAt);

        uint256 winner = ILevrGovernor_v1(governor).getWinner(1);
        ILevrGovernor_v1(governor).execute(winner);

        console2.log('EXECUTED successfully at original cycle timeline');
        console2.log('\n=== Test Complete ===\n');
    }

    // ============ Test 8: Recovery From Failed Cycle (No Execution) ============

    function test_e2e_recovery_from_failed_cycle_manual() public {
        // Setup: Multiple users stake (alice alone won't meet 70% quorum)
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 10 ether); // Total: 25, alice has 20% (< 70% quorum)

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Vote but make it fail (low quorum - only alice votes = 20% < 70%)
        vm.warp(block.timestamp + 2 days + 1); // Voting window
        vm.roll(block.number + 1); // Advance block for flash loan protection
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Wait for voting to end
        vm.warp(block.timestamp + 5 days + 1);

        console2.log('[STATE] Voting window ended, proposal failed quorum (20% < 70%)');

        // Try to execute - will fail - FIX [OCT-31-CRITICAL-1]
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        ILevrGovernor_v1(governor).execute(pid);

        // Verify marked as executed
        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.executed, true, 'Proposal should be marked as executed');

        console2.log('[STATE] Proposal execution failed (as expected)');

        // CRITICAL: Cycle is now "stuck" - no execution triggered _startNewCycle()
        uint256 cycleIdBefore = ILevrGovernor_v1(governor).currentCycleId();
        assertEq(cycleIdBefore, 1, 'Still in cycle 1');

        // RECOVERY METHOD 1: Anyone can manually start new cycle
        vm.prank(bob); // Random user (not owner)
        ILevrGovernor_v1(governor).startNewCycle();

        uint256 cycleIdAfter = ILevrGovernor_v1(governor).currentCycleId();
        assertEq(cycleIdAfter, 2, 'Should be in cycle 2 after manual recovery');

        console2.log('[RECOVERY] Manual startNewCycle() succeeded - now in cycle 2');

        // Verify governance works in new cycle (bob already staked in setup)
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 50 ether);
        assertGt(pid2, 0, 'New proposal should work in cycle 2');

        console2.log('[RESULT] Governance recovered - new proposals work in cycle 2');
    }

    function test_e2e_recovery_from_failed_cycle_auto() public {
        // Setup: Multiple users stake (alice alone won't meet quorum)
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 10 ether); // Total: 25

        vm.warp(block.timestamp + 10 days);

        // Create proposal in cycle 1
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Vote but make it fail (only alice votes = 20% < 70% quorum)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance block for flash loan protection
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true);

        // Wait for voting to end
        vm.warp(block.timestamp + 5 days + 1);

        console2.log('[STATE] Cycle 1 voting ended, no execution happened');

        // Cycle 1 is now "done" but no execution
        assertEq(ILevrGovernor_v1(governor).currentCycleId(), 1, 'Still showing cycle 1');

        // RECOVERY METHOD 2: Auto-recovery when someone tries to propose
        // The _propose() function checks _needsNewCycle() and auto-starts cycle 2
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 50 ether);

        // This should have auto-created cycle 2!
        assertEq(ILevrGovernor_v1(governor).currentCycleId(), 2, 'Should auto-advance to cycle 2');

        ILevrGovernor_v1.Proposal memory p2 = ILevrGovernor_v1(governor).getProposal(pid2);
        assertEq(p2.cycleId, 2, 'New proposal should be in cycle 2');

        console2.log('[RECOVERY] Auto-recovery via next proposal - now in cycle 2');
        console2.log('[RESULT] Governance never gets stuck - always recoverable');
    }

    // ============ Test 9: Config Update Can Help Recovery ============

    function test_e2e_recovery_via_quorum_decrease() public {
        // Setup: Users stake
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 10 ether); // Total: 25

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Vote but insufficient participation (only alice votes = 20% < 70% quorum)
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance block for flash loan protection
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        console2.log('[STATE] Proposal has 20% participation, needs 70% quorum');

        // Initially fails
        assertFalse(ILevrGovernor_v1(governor).meetsQuorum(pid), 'Should not meet quorum');

        // Factory owner realizes quorum is too high, lowers it to help recovery
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 1000, // LOWERED from 70% to 10% to help recovery
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[RECOVERY] Quorum lowered from 70% to 10% to unblock proposal');

        // FIX [NEW-C-3]: With snapshot fix, proposal STILL does NOT meet quorum
        // Config changes can no longer be used for recovery (security improvement)
        // This is the CORRECT, SECURE behavior - prevents config manipulation
        assertFalse(
            ILevrGovernor_v1(governor).meetsQuorum(pid),
            'Should still not meet 70% quorum (snapshot)'
        );

        // Execution fails - config changes cannot unblock stuck proposals
        // FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        ILevrGovernor_v1(governor).execute(pid);

        // Verify marked as executed
        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.executed, true, 'Proposal should be marked as executed');

        console2.log('[RESULT] Snapshot protection prevents config-based recovery');
        console2.log('[RESULT] Must use manual startNewCycle() to recover instead');

        // Proper recovery: manually start new cycle
        ILevrGovernor_v1(governor).startNewCycle();
        assertEq(
            ILevrGovernor_v1(governor).currentCycleId(),
            2,
            'Should be in cycle 2 after manual restart'
        );
    }

    // ============ Test 10: Auto-Cycle Creation After Config Update ============

    function test_e2e_config_update_affects_auto_created_cycle() public {
        // Setup: Alice stakes
        _stakeFor(alice, 15 ether);

        vm.warp(block.timestamp + 10 days);

        // Update config BEFORE any cycle exists
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 1 days, // Short window
            votingWindowSeconds: 2 days, // Short window
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 1000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
        vm.prank(factoryOwner);
        factory.updateConfig(newCfg);

        console2.log('[CONFIG] Updated config before any cycles exist');

        // Alice creates proposal - this will AUTO-CREATE cycle 1 with NEW config
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Verify the auto-created cycle used the NEW config
        ILevrGovernor_v1.Proposal memory proposal = ILevrGovernor_v1(governor).getProposal(pid);

        uint256 expectedProposalEnd = block.timestamp + 1 days;
        uint256 expectedVotingEnd = expectedProposalEnd + 2 days;

        assertEq(
            proposal.votingStartsAt,
            expectedProposalEnd,
            'Auto-created cycle should use new config'
        );
        assertEq(
            proposal.votingEndsAt,
            expectedVotingEnd,
            'Auto-created cycle should use new config'
        );

        console2.log('[RESULT] Auto-created cycle correctly uses new config');
    }
}
