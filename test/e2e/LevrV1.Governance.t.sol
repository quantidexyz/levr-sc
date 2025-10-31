// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Comprehensive Governance E2E tests
/// @dev Tests complete governance flow including:
///      - Time-weighted voting power with VP snapshots
///      - Cycle management with configurable windows
///      - Anti-gaming protections (unstake resets, last-minute staking blocked)
///      - Concurrency limits per proposal type
///      - Quorum and approval thresholds
///      - Winner selection (highest yes votes)
///      - Treasury execution (boost & transfer)

import {BaseForkTest} from '../utils/BaseForkTest.sol';
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
import {console2} from 'forge-std/console2.sol';

contract LevrV1_GovernanceE2E is BaseForkTest, LevrFactoryDeployHelper {
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

    address constant CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
    address constant AIRDROP_EXTENSION = 0xf652B3610D75D81871bf96DB50825d9af28391E0;
    address constant LOCKER = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;

    function setUp() public override {
        super.setUp();

        // Create factory with governance parameters
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            // Governance parameters
            proposalWindowSeconds: 2 days, // 48 hour proposal window
            votingWindowSeconds: 5 days, // 5 day voting window
            maxActiveProposals: 7, // Max 7 proposals per type
            quorumBps: 7000, // 70% participation required
            approvalBps: 5100, // 51% approval required
            minSTokenBpsToSubmit: 100, // 1% of supply required to propose
            maxProposalAmountBps: 1000, // 10% of total supply allowed per proposal,
            minimumQuorumBps: 25, // 0.25% minimum quorum
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
        });

        (factory, forwarder, levrDeployer) = deployFactory(cfg, address(this), CLANKER_FACTORY);

        // Deploy complete Levr ecosystem with Clanker token + large airdrop to treasury
        _deployCompleteEcosystem(50_000 ether); // 50k token airdrop to treasury (50% of supply)
    }

    function _deployCompleteEcosystem(uint256 treasuryAirdropAmount) internal {
        // Step 1: Prepare infrastructure to get treasury address
        (treasury, staking) = factory.prepareForDeployment();

        // Step 2: Create merkle root with treasury address
        bytes32 merkleRoot = MerkleAirdropHelper.singleLeafRoot(treasury, treasuryAirdropAmount);

        bytes memory airdropData = abi.encode(
            address(this), // admin
            merkleRoot,
            1 days, // lockupDuration
            0 // vestingDuration
        );

        // Step 3: Deploy Clanker token with treasury in airdrop
        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFullWithOptions({
            clankerFactory: CLANKER_FACTORY,
            tokenAdmin: address(this),
            name: 'Governance Test Token',
            symbol: 'GOV',
            clankerFeeBps: 100,
            pairedFeeBps: 100,
            enableAirdrop: true,
            airdropAdmin: address(this),
            airdropBps: 5000, // 50% to airdrop for testing
            airdropData: airdropData,
            enableDevBuy: false,
            devBuyBps: 0,
            devBuyEthAmount: 0,
            devBuyRecipient: address(0)
        });

        // Step 4: Complete registration
        ILevrFactory_v1.Project memory project = factory.register(clankerToken);
        treasury = project.treasury;
        governor = project.governor;
        staking = project.staking;
        stakedToken = project.stakedToken;

        // Step 5: Claim airdrop for treasury
        vm.warp(block.timestamp + 1 days + 1);
        bytes32[] memory proof = new bytes32[](0);
        IClankerAirdrop(AIRDROP_EXTENSION).claim(
            clankerToken,
            treasury,
            treasuryAirdropAmount,
            proof
        );

        // Verify treasury has funds
        assertEq(
            IERC20(clankerToken).balanceOf(treasury),
            treasuryAirdropAmount,
            'treasury should have airdrop'
        );
    }

    function _acquireTokens(address to, uint256 amount) internal {
        // Transfer from treasury for testing (treasury has 50k from airdrop)
        uint256 treasuryBal = IERC20(clankerToken).balanceOf(treasury);
        uint256 amountToTransfer = amount > treasuryBal ? treasuryBal : amount;
        require(amountToTransfer > 0, 'no tokens in treasury');
        vm.prank(treasury);
        IERC20(clankerToken).transfer(to, amountToTransfer);
    }

    function _stakeFor(address user, uint256 amount) internal {
        _acquireTokens(user, amount);
        // Stake whatever balance user actually has
        uint256 actualBalance = IERC20(clankerToken).balanceOf(user);
        vm.startPrank(user);
        IERC20(clankerToken).approve(staking, actualBalance);
        ILevrStaking_v1(staking).stake(actualBalance);
        vm.stopPrank();
    }

    // ============ Test 1: Full Governance Cycle ============

    function test_FullGovernanceCycle() public {
        // Setup: 3 users stake different amounts at different times
        // Locker has ~22 ether, so use smaller amounts
        _stakeFor(alice, 5 ether); // Alice stakes at T0
        _stakeFor(bob, 10 ether); // Bob stakes at T0
        vm.warp(block.timestamp + 1 hours);
        _stakeFor(charlie, 2 ether); // Charlie stakes at T+1hr

        // Wait for some time to accrue VP
        vm.warp(block.timestamp + 10 days);

        // Create first proposal (auto-starts governance cycle - proposer pays gas)
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        uint256 cycleId = ILevrGovernor_v1(governor).currentCycleId();
        assertEq(cycleId, 1, 'cycle should be 1 after first proposal');

        // Create more proposals during proposal window

        vm.prank(bob);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeTransfer(
            clankerToken,
            address(0xBEEF),
            50 ether,
            'Team allocation'
        );

        vm.prank(charlie);
        uint256 pid3 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 200 ether);

        // Verify proposals created
        assertEq(pid1, 1);
        assertEq(pid2, 2);
        assertEq(pid3, 3);

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // All users vote
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true); // Alice votes YES on proposal 1

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid2, false); // Alice votes NO on proposal 2

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid3, true); // Alice votes YES on proposal 3

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid1, true); // Bob votes YES on proposal 1

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid2, true); // Bob votes YES on proposal 2

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid3, false); // Bob votes NO on proposal 3

        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid1, true); // Charlie votes YES on proposal 1

        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid2, true); // Charlie votes YES on proposal 2

        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid3, true); // Charlie votes YES on proposal 3

        // Warp to end of voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Check which proposal won (should be pid1 with most yes votes from alice + bob + charlie)
        uint256 winner = ILevrGovernor_v1(governor).getWinner(cycleId);
        assertTrue(winner > 0, 'should have a winner');

        // Execute winner
        ILevrGovernor_v1(governor).execute(winner);

        // Verify execution
        ILevrGovernor_v1.Proposal memory proposal = ILevrGovernor_v1(governor).getProposal(winner);
        assertTrue(proposal.executed, 'winner should be executed');

        // Verify only one proposal executed
        assertEq(
            ILevrGovernor_v1(governor).state(pid1) == ILevrGovernor_v1.ProposalState.Executed
                ? 1
                : 0,
            winner == pid1 ? 1 : 0
        );
    }

    // ============ Test 2: Anti-Gaming - Staking Reset ============

    function test_AntiGaming_StakingReset() public {
        // Alice stakes 5 tokens
        _stakeFor(alice, 5 ether);

        // Wait 30 days to accumulate VP
        vm.warp(block.timestamp + 30 days);

        // Check Alice's VP (should be 5 tokens × 30 days = 150 token-days)
        uint256 vpBefore = ILevrStaking_v1(staking).getVotingPower(alice);
        assertEq(vpBefore, 5 * 30, 'alice should have 150 token-days VP');

        // Alice unstakes 1 token (20% unstake → proportional time reduction)
        vm.prank(alice);
        ILevrStaking_v1(staking).unstake(1 ether, alice);

        // Check Alice's VP after unstake (should be 4 tokens × 24 days = 96 token-days)
        uint256 vpAfter = ILevrStaking_v1(staking).getVotingPower(alice);
        uint256 expectedVP = 4 * 24; // 80% of tokens, 80% of time
        assertEq(vpAfter, expectedVP, 'alice VP should be 96 token-days (20% loss)');

        // Alice stakes again (weighted average preserves VP)
        vm.prank(alice);
        IERC20(clankerToken).approve(staking, 1 ether);
        vm.prank(alice);
        ILevrStaking_v1(staking).stake(1 ether);

        // Weighted average: VP preserved at 96, time diluted
        // Before: 4 tokens × 24 days = 96 token-days
        // After: 5 tokens × (96/5) days = 5 × 19.2 = 96 token-days
        uint256 vpAfterRestake = ILevrStaking_v1(staking).getVotingPower(alice);
        assertEq(vpAfterRestake, 96, 'restake preserves VP at 96 token-days (weighted average)');

        // Wait 4.8 days to reach 24 days equivalent (19.2 + 4.8 = 24)
        vm.warp(block.timestamp + 4 days + 19 hours + 12 minutes);
        uint256 vpNew = ILevrStaking_v1(staking).getVotingPower(alice);
        // Should be approximately 5 × 24 = 120 token-days
        assertApproxEqAbs(vpNew, 5 * 24, 1, 'VP reaches 120 token-days after sufficient time');

        // Verify anti-gaming: can't recover lost time by unstake/restake cycling
        assertLt(vpNew, vpBefore, 'cannot recover lost time through cycling');
    }

    // ============ Test 3: Anti-Gaming - Time-Weighted VP Protects Against Late Staking ============

    function test_AntiGaming_LastMinuteStaking() public {
        // Alice stakes early
        _stakeFor(alice, 5 ether);

        // Wait some time
        vm.warp(block.timestamp + 10 days);

        // Create proposal (auto-starts cycle - proposer pays gas)
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Bob tries to stake AFTER proposal is created
        _stakeFor(bob, 10 ether); // Bob stakes 2x more than Alice

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Check current voting power (no snapshots - uses current VP from staking)
        uint256 aliceVP = ILevrStaking_v1(staking).getVotingPower(alice);
        uint256 bobVP = ILevrStaking_v1(staking).getVotingPower(bob);

        assertGt(aliceVP, 0, 'alice should have VP from long staking time');
        assertGt(bobVP, 0, 'bob has some VP from 2 days of staking');

        // CRITICAL: Time-weighted VP protects against late staking
        // Alice has MORE VP despite having FEWER tokens (5 vs 10)
        // because she staked for longer (12+ days vs 2 days)
        assertGt(aliceVP, bobVP, 'alice VP > bob VP (time-weighted protection)');

        // Both can vote, but Alice's vote carries more weight
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, false);

        // Check vote receipts - Alice's votes should be worth more
        ILevrGovernor_v1.VoteReceipt memory aliceReceipt = ILevrGovernor_v1(governor)
            .getVoteReceipt(pid, alice);
        ILevrGovernor_v1.VoteReceipt memory bobReceipt = ILevrGovernor_v1(governor).getVoteReceipt(
            pid,
            bob
        );

        assertGt(aliceReceipt.votes, bobReceipt.votes, 'alice votes > bob votes (time weighting)');
        assertTrue(bobReceipt.hasVoted, 'bob vote should be recorded');
    }

    // ============ Test 4: Concurrency Limits ============

    function test_ConcurrencyLimits() public {
        // Give alice enough tokens to meet minStake requirement
        _stakeFor(alice, 15 ether); // Use most of locker balance

        vm.warp(block.timestamp + 1 days);

        // Alice can only propose once per type per cycle
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 10 ether); // First auto-starts cycle
        assertGt(pid1, 0, 'should create first boost proposal');

        // Alice tries to create another BoostStakingPool in same cycle (should revert)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.AlreadyProposedInCycle.selector);
        ILevrGovernor_v1(governor).proposeBoost(clankerToken, 10 ether);

        // But alice can create TransferToAddress proposal (different type)
        vm.prank(alice);
        uint256 pidTransfer = ILevrGovernor_v1(governor).proposeTransfer(
            clankerToken,
            address(0xBEEF),
            10 ether,
            'test'
        );
        assertGt(pidTransfer, 0, 'should create transfer proposal');

        // Alice tries to create another TransferToAddress in same cycle (should revert)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.AlreadyProposedInCycle.selector);
        ILevrGovernor_v1(governor).proposeTransfer(clankerToken, address(0xBEEF), 10 ether, 'test');
    }

    // ============ Test 5: Quorum Not Met ============

    function test_QuorumNotMet() public {
        // Setup initial supply
        _stakeFor(bob, 10 ether);

        // Alice stakes (1% of supply to meet minStake)
        uint256 totalSupply = IERC20(stakedToken).totalSupply();
        uint256 minStake = (totalSupply * 100) / 10_000; // 1%
        _stakeFor(alice, minStake + 0.1 ether);

        // Charlie stakes a small amount
        _stakeFor(charlie, 0.5 ether);

        // Wait longer to accumulate sufficient VP (with token-days normalization)
        vm.warp(block.timestamp + 10 days);

        // Start cycle
        // Cycle auto-starts on first proposal

        // Create proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting
        vm.warp(block.timestamp + 2 days + 1);

        // Only Alice votes (not enough for 70% quorum)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Warp to end
        vm.warp(block.timestamp + 5 days + 1);

        // Check if meets quorum (should be false)
        bool meetsQuorum = ILevrGovernor_v1(governor).meetsQuorum(pid);
        assertFalse(meetsQuorum, 'should not meet quorum');

        // Try to execute (should revert)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        ILevrGovernor_v1(governor).execute(pid);

        // Check state is Defeated
        assertEq(
            uint256(ILevrGovernor_v1(governor).state(pid)),
            uint256(ILevrGovernor_v1.ProposalState.Defeated)
        );
    }

    // ============ Test 6: Approval Not Met ============

    function test_ApprovalNotMet() public {
        // Stake for alice, bob, charlie with equal amounts
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 5 ether);
        _stakeFor(charlie, 5 ether);

        vm.warp(block.timestamp + 1 days);

        // Start cycle
        // Cycle auto-starts on first proposal

        // Create proposal
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting
        vm.warp(block.timestamp + 2 days + 1);

        // All vote but majority vote NO
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, false); // NO

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, false); // NO

        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid, true); // YES

        // Warp to end
        vm.warp(block.timestamp + 5 days + 1);

        // Check if meets approval (should be false)
        bool meetsApproval = ILevrGovernor_v1(governor).meetsApproval(pid);
        assertFalse(meetsApproval, 'should not meet approval threshold');

        // Try to execute (should revert)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        ILevrGovernor_v1(governor).execute(pid);
    }

    // ============ Test 7: Only Winner Executes ============

    function test_OnlyWinnerExecutes() public {
        // Stake for users
        _stakeFor(alice, 4 ether);
        _stakeFor(bob, 6 ether);
        _stakeFor(charlie, 5 ether);

        vm.warp(block.timestamp + 1 days);

        // Start cycle
        // Cycle auto-starts on first proposal

        // Create 3 proposals
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        vm.prank(bob);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 200 ether);

        vm.prank(charlie);
        uint256 pid3 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 150 ether);

        // Warp to voting
        vm.warp(block.timestamp + 2 days + 1);

        // Voting pattern: pid2 gets most yes votes
        // pid1: Alice YES, Bob NO, Charlie NO -> low yes
        // pid2: Alice YES, Bob YES, Charlie YES -> highest yes
        // pid3: Alice YES, Bob YES, Charlie NO -> medium yes

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid1, false);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid1, false);

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid2, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid2, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid2, true);

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid3, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid3, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid3, false);

        // Warp to end
        vm.warp(block.timestamp + 5 days + 1);

        // Get winner (should be pid2)
        uint256 winner = ILevrGovernor_v1(governor).getWinner(1);
        assertEq(winner, pid2, 'pid2 should be winner');

        // Execute winner (should succeed)
        ILevrGovernor_v1(governor).execute(pid2);

        // Try to execute pid3 (should revert - not winner)
        vm.expectRevert(ILevrGovernor_v1.NotWinner.selector);
        ILevrGovernor_v1(governor).execute(pid3);
    }

    // ============ Test 8: Minimum Stake To Propose ============

    function test_MinimumStakeToPropose() public {
        // First, create some supply by having bob stake
        _stakeFor(bob, 10 ether);

        // minSTokenBpsToSubmit = 100 (1% of total supply)
        uint256 totalSupply = IERC20(stakedToken).totalSupply();
        uint256 minStake = (totalSupply * 100) / 10_000; // 1%

        // Alice has less than 1%
        uint256 aliceAmount = minStake > 0.01 ether ? minStake - 0.01 ether : 0.01 ether;
        _stakeFor(alice, aliceAmount);

        vm.warp(block.timestamp + 1 days);

        // Start cycle
        // Cycle auto-starts on first proposal

        // Alice tries to propose (should revert)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientStake.selector);
        ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Alice stakes more to meet threshold
        uint256 additionalStake = (minStake - aliceAmount) + 0.01 ether;
        _acquireTokens(alice, additionalStake);
        vm.prank(alice);
        IERC20(clankerToken).approve(staking, additionalStake);
        vm.prank(alice);
        ILevrStaking_v1(staking).stake(additionalStake);

        // Now Alice can propose
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);
        assertGt(pid, 0, 'proposal should be created');
    }

    // ============ Test 9: Proposal Window Timing & Auto-Cycle Management ============

    function test_ProposalWindowTiming() public {
        // Alice has enough stake
        _stakeFor(alice, 15 ether);

        vm.warp(block.timestamp + 1 days);

        // First proposal auto-starts cycle 1
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);
        assertEq(pid1, 1, 'First proposal should have ID 1');
        assertEq(ILevrGovernor_v1(governor).currentCycleId(), 1, 'Should be in cycle 1');

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Note: Intentionally NOT voting on pid1 so it fails quorum
        // This allows the next proposal to auto-start a new cycle without orphaning pid1

        // Warp past voting window (cycle ended)
        vm.warp(block.timestamp + 5 days + 1);

        // Try to vote after voting window (should revert)
        _stakeFor(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(ILevrGovernor_v1.VotingNotActive.selector);
        ILevrGovernor_v1(governor).vote(pid1, true);

        // New proposal after cycle ended auto-starts cycle 2
        // pid1 failed quorum so it's defeated and can be orphaned safely
        vm.prank(alice);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 200 ether);
        assertEq(pid2, 2, 'Second proposal should have ID 2');
        assertEq(
            ILevrGovernor_v1(governor).currentCycleId(),
            2,
            'Should be in cycle 2 after auto-start'
        );

        // Verify pid2 is in new cycle
        ILevrGovernor_v1.Proposal memory p2 = ILevrGovernor_v1(governor).getProposal(pid2);
        assertEq(p2.cycleId, 2, 'New proposal should be in cycle 2');
    }

    // ============ Test 10: Single Proposal State Bug - Meets Quorum & Approval ============
    // REGRESSION TEST: Validates fix for state contradiction where proposal meets both
    // quorum and approval but state enum shows Defeated instead of Succeeded
    //
    // Scenario:
    // - Single staker with votes
    // - Meets quorum (balance participation threshold)
    // - Meets approval (VP voting threshold)
    // - State should be "Succeeded" (2), NOT "Defeated" (3)
    //
    // Bug manifestation (user report):
    // - UI shows "Defeated" badge
    // - No execute button appears
    // - User warps time past voting, proposal has votes, meets both thresholds
    // - But getWinner() returns 0 or different ID
    // - state() returns 3 instead of 2
    //
    // Related: https://github.com/xxx/issues/xxx

    function test_SingleProposalStateConsistency_MeetsQuorumAndApproval() public {
        // Setup: Single staker with votes
        uint256 stakeAmount = 10 ether;
        _stakeFor(alice, stakeAmount);

        vm.warp(block.timestamp + 1 days);

        // Create single proposal (will auto-start cycle 1)
        vm.prank(alice);
        uint256 proposalId = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Get initial proposal state
        ILevrGovernor_v1.Proposal memory propAfterCreation = ILevrGovernor_v1(governor).getProposal(
            proposalId
        );
        assertEq(propAfterCreation.id, proposalId, 'Proposal should exist');
        assertEq(propAfterCreation.cycleId, 1, 'Should be in cycle 1');

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Vote YES with high voting power
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(proposalId, true);

        // Get proposal during voting
        ILevrGovernor_v1.Proposal memory propDuringVoting = ILevrGovernor_v1(governor).getProposal(
            proposalId
        );

        // State should be Active (1) during voting
        assertEq(uint256(propDuringVoting.state), 1, 'State should be Active (1) during voting');
        assertGt(propDuringVoting.yesVotes, 0, 'Should have yes votes');
        assertEq(propDuringVoting.noVotes, 0, 'Should have no votes');

        // Warp past voting window (4 days later as in user's scenario)
        vm.warp(block.timestamp + 5 days + 1);

        // Get final proposal state
        ILevrGovernor_v1.Proposal memory propAfterVoting = ILevrGovernor_v1(governor).getProposal(
            proposalId
        );

        // ===== KEY ASSERTIONS FOR BUG DETECTION =====

        // Votes should be preserved
        assertEq(
            propAfterVoting.yesVotes,
            propDuringVoting.yesVotes,
            'Yes votes should not change'
        );
        assertEq(propAfterVoting.noVotes, propDuringVoting.noVotes, 'No votes should not change');

        // Both thresholds should be met
        assertTrue(propAfterVoting.meetsQuorum, 'Should meet quorum');
        assertTrue(propAfterVoting.meetsApproval, 'Should meet approval');

        // ===== BUG: This is where the contradiction occurs =====
        // If meetsQuorum=true AND meetsApproval=true, state MUST be Succeeded (2)
        // If state is Defeated (3), it's a contract bug
        uint8 expectedState = 2; // ProposalState.Succeeded
        assertEq(
            uint256(propAfterVoting.state),
            uint256(expectedState),
            'CRITICAL BUG: state should be Succeeded (2) when both meetsQuorum and meetsApproval are true. '
            'Got Defeated (3). This causes UI to show wrong badge and no execute button.'
        );

        // Winner should be this proposal (it's the only one and meets all criteria)
        uint256 winner = ILevrGovernor_v1(governor).getWinner(1);
        assertEq(winner, proposalId, 'This proposal should be the cycle winner');

        // Should be executable (treasury has sufficient balance for the boost amount)
        uint256 treasuryBalance = IERC20(clankerToken).balanceOf(treasury);
        assertTrue(
            treasuryBalance >= propAfterVoting.amount,
            'Treasury should have sufficient balance for execution'
        );

        // Execute should succeed
        ILevrGovernor_v1(governor).execute(proposalId);

        // Verify execution
        ILevrGovernor_v1.Proposal memory propAfterExecution = ILevrGovernor_v1(governor)
            .getProposal(proposalId);
        assertTrue(propAfterExecution.executed, 'Proposal should be marked as executed');
        assertEq(
            uint256(propAfterExecution.state),
            4,
            'State should be Executed (4) after execution'
        );
    }

    // ============ Test 11: Cannot Start New Cycle With Executable Proposals ============

    function test_cannotStartNewCycleWithExecutableProposals() public {
        // Setup: Single user with sufficient voting power
        _stakeFor(alice, 10 ether);

        vm.warp(block.timestamp + 1 days);

        // Create proposal (auto-starts cycle 1)
        vm.prank(alice);
        uint256 proposalId = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes YES (100% yes votes = meets approval, 100% participation = meets quorum)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(proposalId, true);

        // Warp past voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Verify proposal is in Succeeded state
        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(proposalId);
        assertEq(uint256(prop.state), 2, 'Proposal should be in Succeeded state (2)');
        assertFalse(prop.executed, 'Proposal should not be executed yet');

        // CRITICAL: Try to start new cycle while proposal is in Succeeded state
        // This should REVERT to prevent orphaning the proposal
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        ILevrGovernor_v1(governor).startNewCycle();

        // Verify we're still in cycle 1
        assertEq(ILevrGovernor_v1(governor).currentCycleId(), 1, 'Should still be in cycle 1');

        // NOW: Execute the proposal
        ILevrGovernor_v1(governor).execute(proposalId);

        // Verify execution automatically started cycle 2
        assertEq(
            ILevrGovernor_v1(governor).currentCycleId(),
            2,
            'Should be in cycle 2 after execution'
        );

        // Verify we can no longer call startNewCycle until voting window of cycle 2 ends
        vm.expectRevert(ILevrGovernor_v1.CycleStillActive.selector);
        ILevrGovernor_v1(governor).startNewCycle();
    }

    // ============ Test 12: Can Start New Cycle After Executing All Proposals ============

    function test_canStartNewCycleAfterExecutingProposals() public {
        // Setup: Multiple proposals, only one is winner
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);

        vm.warp(block.timestamp + 10 days);

        // Create two proposals (auto-starts cycle 1)
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        vm.prank(bob);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeTransfer(
            clankerToken,
            address(0xBEEF),
            50 ether,
            'test'
        );

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes YES on pid1, NO on pid2
        // Bob votes YES on both (pid1 wins with more votes)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true);

        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid2, false);

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid1, true);

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid2, true);

        // Warp past voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Both proposals meet quorum and approval, but only pid1 is winner
        ILevrGovernor_v1.Proposal memory p1 = ILevrGovernor_v1(governor).getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = ILevrGovernor_v1(governor).getProposal(pid2);

        assertEq(uint256(p1.state), 2, 'pid1 should be in Succeeded state');
        assertEq(
            uint256(p2.state),
            2,
            'pid2 should be in Succeeded state (non-winner but succeeded)'
        );

        // Try to start new cycle - should REVERT because pid1 is Succeeded
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        ILevrGovernor_v1(governor).startNewCycle();

        // Execute the winning proposal
        ILevrGovernor_v1(governor).execute(pid1);

        // Now cycle 2 should be auto-started
        assertEq(ILevrGovernor_v1(governor).currentCycleId(), 2, 'Should auto-start cycle 2');

        // Verify pid2 is orphaned in cycle 1 (cannot execute in new cycle)
        ILevrGovernor_v1.Proposal memory p2After = ILevrGovernor_v1(governor).getProposal(pid2);
        assertEq(p2After.cycleId, 1, 'pid2 should still be in cycle 1');
        assertEq(uint256(p2After.state), 2, 'pid2 still in Succeeded state but orphaned');
        assertFalse(p2After.executed, 'pid2 should not be executed');
    }

    // ============ Test 13: Can Start New Cycle If Proposal Is Defeated ============

    function test_canStartNewCycleIfProposalDefeated() public {
        // Setup: Create a proposal that will fail quorum (not enough participation)
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 5 ether);
        _stakeFor(charlie, 5 ether); // Total: 15 ether, alice has 1/3 (33% < 70% quorum)

        vm.warp(block.timestamp + 10 days);

        // Create proposal (auto-starts cycle 1)
        vm.prank(alice);
        uint256 proposalId = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Only alice votes (33% participation < 70% quorum requirement)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(proposalId, true);

        // Warp past voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Proposal should be Defeated (failed quorum)
        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(proposalId);
        assertEq(uint256(prop.state), 3, 'Proposal should be Defeated (failed quorum)');
        assertFalse(prop.executed, 'Proposal should not be executed');

        // NOW: startNewCycle() should succeed because proposal is Defeated, not Succeeded
        ILevrGovernor_v1(governor).startNewCycle();

        assertEq(
            ILevrGovernor_v1(governor).currentCycleId(),
            2,
            'Should be able to start new cycle'
        );
    }

    // ============ Test 14: Supply Invariant Testing - Comprehensive Snapshot Behavior ============

    function test_supplyInvariant_tinySupplyAtCreation_singleVoterCanPass() public {
        // SCENARIO 1: Proposal created with TINY supply (1 token), then supply explodes
        // EDGE CASE: Single early voter can meet quorum alone (snapshot is tiny)
        // This demonstrates potential manipulation if early proposer colludes

        // Minimal initial stake
        _stakeFor(alice, 1 ether);
        vm.warp(block.timestamp + 10 days); // Accumulate VP

        // Create proposal (snapshot: 1 ether)
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.totalSupplySnapshot, 1 ether, 'Snapshot: 1 ether');

        // Supply explodes (1000x increase!)
        for (uint256 i = 0; i < 10; i++) {
            address newUser = address(uint160(0x1000 + i));
            _stakeFor(newUser, 100 ether);
        }
        // Total: 1 ether (alice) + 1000 ether (10 users × 100) = 1001 ether

        assertEq(IERC20(stakedToken).totalSupply(), 1001 ether, 'Current supply: 1001 ether');

        // Warp to voting window (users have been staking, accumulating VP)
        vm.warp(prop.votingStartsAt + 1);

        // ONLY alice votes (0.1% of current supply)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Check results
        vm.warp(prop.votingEndsAt + 1);
        prop = ILevrGovernor_v1(governor).getProposal(pid);

        // Quorum: totalBalanceVoted (1) >= snapshot (1) × 70% = 0.7 ether ✅
        // Alice's 1 ether vote meets quorum, even though it's only 0.1% of current supply!
        assertTrue(prop.meetsQuorum, 'Quorum met with single voter (100% of snapshot)');
        assertTrue(prop.meetsApproval, 'Approval met (100% yes)');
        assertEq(uint256(prop.state), 2, 'Succeeded');

        // This shows: Early proposals with tiny snapshots can pass with minimal participation
        // if the original stakers vote, regardless of how much supply grows later
    }

    function test_supplyInvariant_supplyIncreaseAfterCreation() public {
        // SCENARIO 2: Proposal created with 10 ether supply, then supply DOUBLES to 20 ether
        // EXPECTED: Quorum uses snapshot (10 ether), so 70% quorum = 7 ether minimum

        // Stake initial supply
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 5 ether);
        // Total: 10 ether

        vm.warp(block.timestamp + 10 days); // Accumulate VP

        // Create proposal (snapshot: 10 ether)
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.totalSupplySnapshot, 10 ether, 'Snapshot: 10 ether');

        // Now supply DOUBLES (new stakers join after proposal created)
        _stakeFor(charlie, 10 ether);
        // Total: 20 ether (100% increase)

        assertEq(IERC20(stakedToken).totalSupply(), 20 ether, 'Current supply: 20 ether');

        // Warp to voting window (users have been staking, accumulating VP)
        vm.warp(prop.votingStartsAt + 1);

        // Only alice and bob vote (10 ether total, charlie doesn't vote)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Check results
        vm.warp(prop.votingEndsAt + 1);
        prop = ILevrGovernor_v1(governor).getProposal(pid);

        // Quorum: totalBalanceVoted (10) >= snapshot (10) * 70% = 7 ether ✅
        // Even though only 50% of CURRENT supply voted, 100% of SNAPSHOT voted
        assertTrue(prop.meetsQuorum, 'Quorum met (10/10 = 100% of snapshot)');
        assertTrue(prop.meetsApproval, 'Approval met');
        assertEq(uint256(prop.state), 2, 'Succeeded');

        // This demonstrates that new stakers AFTER proposal don't affect quorum calculation
    }

    function test_supplyInvariant_supplyDecreaseAfterCreation() public {
        // SCENARIO 3: Proposal created with 20 ether supply, then supply HALVES to 10 ether
        // EXPECTED: Quorum uses snapshot (20 ether), so 70% quorum = 14 ether minimum

        // Stake initial supply
        _stakeFor(alice, 5 ether);
        _stakeFor(bob, 10 ether);
        _stakeFor(charlie, 5 ether);
        // Total: 20 ether

        vm.warp(block.timestamp + 10 days); // Accumulate VP

        // Create proposal (snapshot: 20 ether)
        vm.prank(bob);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.totalSupplySnapshot, 20 ether, 'Snapshot: 20 ether');

        // Now charlie unstakes (supply decreases by 25%)
        vm.prank(charlie);
        ILevrStaking_v1(staking).unstake(5 ether, charlie);
        // Total: 15 ether (25% decrease)

        assertEq(IERC20(stakedToken).totalSupply(), 15 ether, 'Current supply: 15 ether');

        // Warp to voting window (users have been staking, accumulating VP)
        vm.warp(prop.votingStartsAt + 1);

        // Alice and bob vote (15 ether total balance, but charlie can't vote - unstaked)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Check results
        vm.warp(prop.votingEndsAt + 1);
        prop = ILevrGovernor_v1(governor).getProposal(pid);

        // Quorum: totalBalanceVoted (15) >= snapshot (20) * 70% = 14 ether ✅
        // 75% of snapshot supply voted (15/20), which exceeds 70% quorum
        assertTrue(prop.meetsQuorum, 'Quorum met (15/20 = 75% of snapshot)');
        assertTrue(prop.meetsApproval, 'Approval met');
        assertEq(uint256(prop.state), 2, 'Succeeded');
    }

    function test_supplyInvariant_extremeSupplyIncrease() public {
        // SCENARIO 4: Proposal created with 1 ether supply, then 10x increase to 10 ether
        // EXPECTED: Quorum uses snapshot (1 ether), so 70% = 0.7 ether minimum

        // Minimal initial stake
        _stakeFor(alice, 1 ether);
        vm.warp(block.timestamp + 10 days); // Accumulate VP

        // Create proposal (snapshot: 1 ether)
        vm.prank(alice);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.totalSupplySnapshot, 1 ether, 'Snapshot: 1 ether');

        // Extreme supply increase (10x growth)
        _stakeFor(bob, 5 ether);
        _stakeFor(charlie, 4 ether);
        // Total: 10 ether (1000% increase!)

        assertEq(IERC20(stakedToken).totalSupply(), 10 ether, 'Current supply: 10 ether');

        // Warp to voting window (users have been staking, accumulating VP)
        vm.warp(prop.votingStartsAt + 1);

        // Only alice votes (1 ether balance)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Check results
        vm.warp(prop.votingEndsAt + 1);
        prop = ILevrGovernor_v1(governor).getProposal(pid);

        // Quorum: totalBalanceVoted (1) >= snapshot (1) * 70% = 0.7 ether ✅
        // Alice's vote alone (100% of snapshot) exceeds quorum, even though it's only 10% of current supply
        assertTrue(prop.meetsQuorum, 'Quorum met (1/1 = 100% of snapshot)');
        assertTrue(prop.meetsApproval, 'Approval met');
        assertEq(uint256(prop.state), 2, 'Succeeded');

        // This shows that early proposals can pass with minimal absolute participation
        // if most original stakers vote, even if supply explodes later
    }

    function test_supplyInvariant_extremeSupplyDecrease() public {
        // SCENARIO 5: Proposal created with 10 ether supply, then 70% decrease to 3 ether
        // WITH ADAPTIVE QUORUM: Quorum adapts to current supply to prevent deadlock
        // Adaptive quorum = 70% of current (3 ether) = 2.1 ether (remaining voters can pass)

        // Large initial stake
        _stakeFor(alice, 2 ether);
        _stakeFor(bob, 4 ether);
        _stakeFor(charlie, 4 ether);
        // Total: 10 ether

        vm.warp(block.timestamp + 10 days); // Accumulate VP

        // Create proposal (snapshot: 10 ether)
        vm.prank(bob);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory prop = ILevrGovernor_v1(governor).getProposal(pid);
        assertEq(prop.totalSupplySnapshot, 10 ether, 'Snapshot: 10 ether');

        // Extreme unstaking (70% of supply leaves)
        vm.prank(bob);
        ILevrStaking_v1(staking).unstake(4 ether, bob);
        vm.prank(charlie);
        ILevrStaking_v1(staking).unstake(3 ether, charlie);
        // Remaining: 3 ether (alice 2, charlie 1)

        assertEq(IERC20(stakedToken).totalSupply(), 3 ether, 'Current supply: 3 ether');

        // Warp to voting window (users have been staking, accumulating VP)
        vm.warp(prop.votingStartsAt + 1);

        // Remaining users vote (alice 2 ether, charlie 1 ether = 100% participation!)
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid, true);

        // Check results
        vm.warp(prop.votingEndsAt + 1);
        prop = ILevrGovernor_v1(governor).getProposal(pid);

        // ADAPTIVE QUORUM: totalBalanceVoted (3) >= adaptive quorum (2.1 ether) ✅
        // Adaptive quorum uses current supply (3 ether) because 3 < 10 (snapshot)
        // Required = max(3 * 70%, 10 * 0.25%) = max(2.1, 0.025) = 2.1 ether
        // All remaining stakers voted (100% participation of remaining supply)
        assertTrue(prop.meetsQuorum, 'Quorum met with adaptive quorum (3 >= 2.1)');
        assertTrue(prop.meetsApproval, 'Approval met (100% yes)');
        assertEq(uint256(prop.state), 2, 'Succeeded with adaptive quorum');

        // This demonstrates that adaptive quorum prevents mass unstaking deadlock
        // Remaining stakers can pass proposals even after mass exodus
    }

    function test_supplyInvariant_multipleProposalsDifferentSnapshots() public {
        // SCENARIO 6: Multiple proposals created at different times with different snapshots
        // EXPECTED: Each proposal uses its own snapshot for quorum calculation

        // Initial stake: 5 ether
        _stakeFor(alice, 5 ether);
        vm.warp(block.timestamp + 10 days);

        // Proposal 1 created (snapshot: 5 ether)
        vm.prank(alice);
        uint256 pid1 = ILevrGovernor_v1(governor).proposeBoost(clankerToken, 100 ether);

        ILevrGovernor_v1.Proposal memory prop1 = ILevrGovernor_v1(governor).getProposal(pid1);
        assertEq(prop1.totalSupplySnapshot, 5 ether, 'Prop1 snapshot: 5 ether');

        // Supply doubles
        _stakeFor(bob, 5 ether);
        // Total: 10 ether

        vm.warp(block.timestamp + 1 hours); // Still in proposal window

        // Proposal 2 created (snapshot: 10 ether)
        vm.prank(bob);
        uint256 pid2 = ILevrGovernor_v1(governor).proposeTransfer(
            clankerToken,
            address(0xBEEF),
            50 ether,
            'test'
        );

        ILevrGovernor_v1.Proposal memory prop2 = ILevrGovernor_v1(governor).getProposal(pid2);
        assertEq(prop2.totalSupplySnapshot, 10 ether, 'Prop2 snapshot: 10 ether');

        // Supply triples
        _stakeFor(charlie, 10 ether);
        // Total: 20 ether

        // Warp to voting window (users have been staking, accumulating VP)
        vm.warp(prop1.votingStartsAt + 1);

        // All three vote on both proposals
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(alice);
        ILevrGovernor_v1(governor).vote(pid2, true);

        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(bob);
        ILevrGovernor_v1(governor).vote(pid2, true);

        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid1, true);
        vm.prank(charlie);
        ILevrGovernor_v1(governor).vote(pid2, true);

        // Check results
        vm.warp(prop1.votingEndsAt + 1);

        prop1 = ILevrGovernor_v1(governor).getProposal(pid1);
        prop2 = ILevrGovernor_v1(governor).getProposal(pid2);

        // Prop1: totalBalanceVoted (20) >= snapshot (5) * 70% = 3.5 ether ✅ (400% participation!)
        assertTrue(prop1.meetsQuorum, 'Prop1 quorum met (20/5 = 400% of snapshot)');

        // Prop2: totalBalanceVoted (20) >= snapshot (10) * 70% = 7 ether ✅ (200% participation)
        assertTrue(prop2.meetsQuorum, 'Prop2 quorum met (20/10 = 200% of snapshot)');

        // Both proposals use their respective snapshots correctly
        assertEq(uint256(prop1.state), 2, 'Prop1 Succeeded');
        assertEq(uint256(prop2.state), 2, 'Prop2 Succeeded');
    }
}
