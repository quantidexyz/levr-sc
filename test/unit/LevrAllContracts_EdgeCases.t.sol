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
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Comprehensive Edge Case Test Suite
/// @notice Systematic testing based on USER_FLOWS.md analysis
/// @dev Tests organized by flow categories: synchronization, boundaries, ordering, etc.
contract LevrAllContracts_EdgeCases_Test is Test, LevrFactoryDeployHelper {
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
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
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

        // Fund treasury
        underlying.mint(address(treasury), 100_000 ether);
    }

    /// @notice Helper function to whitelist a dynamically created reward token
    /// @dev Caller must ensure no ongoing prank before calling this
    function _whitelistRewardToken(address token) internal {
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.whitelistToken(token);
    }

    // ============================================================================
    // CATEGORY A: STATE SYNCHRONIZATION ISSUES (CRITICAL)
    // ============================================================================

    /// @notice CRITICAL: VP changes between vote and execution
    /// @dev User's VP decreases after voting, affects their recorded vote retroactively?
    function test_votingPower_changeAfterVoting() public {
        console2.log('\n=== VP Change After Voting ===');

        // Alice stakes and waits for VP
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        uint256 aliceVP = staking.getVotingPower(alice);
        console2.log('Alice VP before vote:', aliceVP);

        // Create and vote on proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid, true);

        ILevrGovernor_v1.VoteReceipt memory receipt = governor.getVoteReceipt(pid, alice);
        console2.log('VP recorded in vote:', receipt.votes);

        // AFTER VOTING: Alice unstakes 50%
        vm.prank(alice);
        staking.unstake(500 ether, alice);

        uint256 aliceVPAfter = staking.getVotingPower(alice);
        console2.log('Alice VP after unstake:', aliceVPAfter);

        // Check if vote receipt still has original VP
        receipt = governor.getVoteReceipt(pid, alice);
        console2.log('VP still in receipt:', receipt.votes);

        // QUESTION: Vote is snapshotted at vote time (good!)
        // But quorum uses CURRENT supply (bad!)
        vm.warp(block.timestamp + 5 days + 1);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('\nProposal meets quorum:', prop.meetsQuorum);
        console2.log('Proposal yes votes:', prop.yesVotes);
        console2.log('Proposal total balance voted:', prop.totalBalanceVoted);
        console2.log('Current total supply:', sToken.totalSupply() / 1e18);
    }

    /// @notice CRITICAL: SToken balance changes between vote and quorum check
    /// @dev DISABLED: Uses transfers which are now blocked
    function skip_test_quorumCheck_sTokenBalanceChanges() public {
        console2.log('\n=== Quorum with SToken Balance Changes ===');

        // Three users stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(400 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(300 ether);
        vm.stopPrank();

        underlying.mint(charlie, 1000 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(300 ether);
        vm.stopPrank();

        // Total = 1000 sTokens, quorum = 700 sTokens

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice and Bob vote (700 sTokens)
        vm.prank(alice);
        governor.vote(pid, true);

        vm.prank(bob);
        governor.vote(pid, true);

        console2.log('Total balance voted: 700 sTokens');
        console2.log('Total supply: 1000 sTokens');
        console2.log('Quorum: 700 sTokens (70%)');
        console2.log('Meets quorum: true');

        // AFTER VOTING: Bob transfers his 300 sTokens to Dave
        address dave = address(0xDADE);
        vm.prank(bob);
        sToken.transfer(dave, 300 ether);

        console2.log('\nBob transferred 300 sTokens to Dave');
        console2.log('Bob balance now:', sToken.balanceOf(bob) / 1e18);
        console2.log('Dave balance now:', sToken.balanceOf(dave) / 1e18);

        // QUESTION: Does this affect quorum calculation?
        // totalBalanceVoted = 700 (Alice 400 + Bob 300 at vote time)
        // totalSupply = still 1000 (no minting/burning)
        // Quorum check: 700 >= 700 → still passes

        vm.warp(block.timestamp + 5 days + 1);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('\nStill meets quorum:', prop.meetsQuorum);

        // This is SAFE because quorum uses totalBalanceVoted (snapshot) vs totalSupply (current)
        // The balance that voted (700) doesn't change, only who holds the tokens
    }

    // ============================================================================
    // CATEGORY B: BOUNDARY CONDITIONS
    // ============================================================================

    /// @notice First stake when totalStaked = 0
    function test_boundary_firstStakeWhenTotalZero() public {
        console2.log('\n=== First Stake When Total = 0 ===');

        assertEq(staking.totalStaked(), 0, 'Should start with 0');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        assertEq(staking.totalStaked(), 100 ether);
        assertEq(staking.stakedBalanceOf(alice), 100 ether);
        console2.log('First stake successful: 100 tokens');
    }

    /// @notice Last unstake when totalStaked → 0
    function test_boundary_lastUnstakeToZero() public {
        console2.log('\n=== Last Unstake to Total = 0 ===');

        // Alice is only staker
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);

        // Accrue some rewards
        MockERC20 reward = new MockERC20('Reward', 'RWD');
        reward.mint(address(staking), 1000 ether);
        vm.stopPrank();
        
        // Whitelist after stopping prank
        _whitelistRewardToken(address(reward));

        staking.accrueRewards(address(reward));

        console2.log('Total staked before unstake:', staking.totalStaked() / 1e18);
        console2.log('Active reward stream exists');

        // Wait for rewards to vest
        vm.warp(block.timestamp + 3 days);

        // Alice unstakes everything
        vm.prank(alice);
        staking.unstake(100 ether, alice);

        console2.log('Total staked after unstake:', staking.totalStaked());

        // QUESTION: What happens to the reward stream?
        // Stream should pause (per M-2 fix)

        // If Bob stakes now, does he get Alice's unvested rewards?
        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);

        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        uint256 bobRewards = reward.balanceOf(bob);
        console2.log('Bob claimed rewards:', bobRewards / 1e18);

        if (bobRewards > 0) {
            console2.log('POTENTIAL ISSUE: Bob got rewards from period when nobody was staked');
        }
    }

    /// @notice Voting at exact moment window opens/closes
    function test_boundary_votingAtExactWindowBoundary() public {
        console2.log('\n=== Voting at Exact Window Boundaries ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        uint256 votingStarts = prop.votingStartsAt;
        uint256 votingEnds = prop.votingEndsAt;

        // Try to vote at exactly votingStartsAt (should succeed)
        vm.warp(votingStarts);
        console2.log('At exact voting start time');

        vm.prank(alice);
        governor.vote(pid, true);
        console2.log('Vote at exact start: SUCCESS');

        // Create another proposal for boundary test
        vm.warp(block.timestamp - 10 days); // Reset time
        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 10 days);
        uint256 pid2 = governor.proposeBoost(address(underlying), 1000 ether);
        vm.stopPrank();

        prop = governor.getProposal(pid2);
        votingEnds = prop.votingEndsAt;

        // Try to vote at exactly votingEndsAt (boundary check: <= vs <)
        vm.warp(votingEnds);
        console2.log('\nAt exact voting end time');

        vm.prank(bob);
        // Check what the code says: block.timestamp > proposal.votingEndsAt
        // At votingEndsAt: block.timestamp NOT > votingEndsAt (equal)
        // Should ALLOW voting
        governor.vote(pid2, true);
        console2.log('Vote at exact end: SUCCESS (inclusive boundary)');

        // Try one second after
        vm.warp(votingEnds + 1);

        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.VotingNotActive.selector);
        governor.vote(pid2, false);
        console2.log('Vote one second after end: BLOCKED (correct)');
    }

    /// @notice Proposal amount = maximum allowed
    function test_boundary_proposalAtMaxAmount() public {
        console2.log('\n=== Proposal at Maximum Amount Boundary ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Treasury has 100k tokens
        // maxProposalAmountBps = 5000 (50%)
        // Max = 50k tokens
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));
        uint256 maxAmount = (treasuryBalance * 5000) / 10_000;

        console2.log('Treasury balance:', treasuryBalance / 1e18);
        console2.log('Max proposal amount (50%):', maxAmount / 1e18);

        // Propose exactly at max (should succeed)
        vm.prank(alice);
        uint256 _pid = governor.proposeBoost(address(underlying), maxAmount);
        console2.log('Proposal at exact max: SUCCESS');

        // Wait for new cycle
        vm.warp(block.timestamp + 7 days + 1);
        governor.startNewCycle();

        // Propose 1 wei over max (should fail)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.ProposalAmountExceedsLimit.selector);
        governor.proposeBoost(address(underlying), maxAmount + 1);
        console2.log('Proposal at max + 1: BLOCKED (correct)');
    }

    /// @notice Stream window = minimum (1 day)
    function test_boundary_minimumStreamWindow() public {
        console2.log('\n=== Minimum Stream Window (1 day) ===');

        // Create new factory with 1 day stream window
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 1 days, // Minimum
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 0,
            approvalBps: 0,
            minSTokenBpsToSubmit: 0,
            maxProposalAmountBps: 10000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        (
            LevrFactory_v1 fac,
            LevrForwarder_v1 _fwd,
            LevrDeployer_v1 _dep
        ) = deployFactoryWithDefaultClanker(cfg, address(this));

        MockERC20 token = new MockERC20('Test', 'TST');
        fac.prepareForDeployment();
        ILevrFactory_v1.Project memory proj = fac.register(address(token));

        // Stake
        token.mint(alice, 1000 ether);
        vm.startPrank(alice);
        token.approve(proj.staking, type(uint256).max);
        LevrStaking_v1(proj.staking).stake(100 ether);
        vm.stopPrank();

        // Accrue rewards with 1 day window
        MockERC20 reward = new MockERC20('Reward', 'RWD');
        vm.prank(address(this)); // Test contract is admin of token
        LevrStaking_v1(proj.staking).whitelistToken(address(reward));
        reward.mint(address(proj.staking), 1000 ether);
        LevrStaking_v1(proj.staking).accrueRewards(address(reward));

        console2.log('Stream duration: 1 day');
        console2.log('Total rewards: 1000 tokens');

        // Wait 12 hours (50%)
        vm.warp(block.timestamp + 12 hours);

        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);

        vm.prank(alice);
        LevrStaking_v1(proj.staking).claimRewards(tokens, alice);

        uint256 claimed = reward.balanceOf(alice);
        console2.log('Claimed after 12 hours:', claimed / 1e18);

        // Should be ~500 tokens (50% of stream)
        assertGt(claimed, 499 ether);
        assertLt(claimed, 501 ether);
        console2.log('Minimum window works correctly');
    }

    // ============================================================================
    // CATEGORY C: ORDERING DEPENDENCIES
    // ============================================================================

    /// @notice Vote then Unstake then Execute (supply changes affect quorum)
    function test_ordering_voteUnstakeExecute() public {
        console2.log('\n=== Vote then Unstake then Execute Ordering ===');

        // Setup: Two users with majority
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(700 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(300 ether);
        vm.stopPrank();

        // Total = 1000, quorum = 700
        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // BOTH vote (1000 sTokens = 100% participation)
        vm.prank(alice);
        governor.vote(pid, true);

        vm.prank(bob);
        governor.vote(pid, true);

        console2.log('Voting complete: 1000/1000 sTokens (100%)');

        // Voting ends
        vm.warp(block.timestamp + 5 days + 1);

        // BEFORE EXECUTION: Bob unstakes everything
        vm.prank(bob);
        staking.unstake(300 ether, bob);

        console2.log('Bob unstaked 300 sTokens');
        console2.log('New total supply:', sToken.totalSupply() / 1e18);
        console2.log('Total balance voted: still 1000');

        // Quorum check at execution
        // totalBalanceVoted = 1000 (recorded at vote time)
        // totalSupply = 700 (current)
        // Required quorum = 700 * 70% = 490
        // 1000 >= 490 → PASSES

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('Meets quorum:', prop.meetsQuorum);

        if (prop.meetsQuorum) {
            console2.log('SAFE: Quorum still met even though supply decreased');
            console2.log('totalBalanceVoted is snapshot, totalSupply is not');
            console2.log('This can be manipulated (supply decrease helps quorum)');
        }
    }

    /// @notice Propose then Config Change then Vote (constraints change)
    function test_ordering_proposeConfigChangeVote() public {
        console2.log('\n=== Propose then Config Change then Vote ===');

        // Alice stakes 10% of supply
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

        // Alice has 10% of supply, minStake = 1%, so she can propose
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);
        console2.log('Alice proposed with 10% of supply (min = 1%)');

        // Factory owner changes minStake to 20%
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 2000, // 20% now!
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        factory.updateConfig(newCfg);
        console2.log('Config updated: minStake now 20%');

        // Alice's existing proposal should still be valid
        // But she cannot create NEW proposals
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid, true);
        console2.log('Alice can vote on existing proposal: SUCCESS');

        // FIX: Bob (90% of supply) needs to vote too to meet 70% quorum
        vm.prank(bob);
        governor.vote(pid, true);
        console2.log('Bob also voted (now 100% participation)');

        // Execute the proposal (auto-starts cycle 2)
        vm.warp(block.timestamp + 5 days + 1); // End of voting window
        governor.execute(pid);
        console2.log('Proposal executed (auto-starts cycle 2)');

        // Now in cycle 2, try to create new proposal (should fail - Alice only has 10%, needs 20%)
        vm.warp(block.timestamp + 1 days); // Into proposal window

        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientStake.selector);
        governor.proposeBoost(address(underlying), 1000 ether);
        console2.log('Alice cannot create new proposal: BLOCKED (10% < 20%)');
    }

    /// @notice Stake then Vote then Transfer sToken then Vote again?
    /// @dev DISABLED: Staked tokens are now non-transferable (simplified design)
    function skip_test_ordering_stakeVoteTransferStoken() public {
        console2.log('\n=== Stake then Vote then Transfer SToken ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes
        vm.prank(alice);
        governor.vote(pid, true);
        console2.log('Alice voted');

        // Alice transfers all sTokens to Bob
        vm.prank(alice);
        sToken.transfer(bob, 1000 ether);
        console2.log('Alice transferred all sTokens to Bob');

        // Can Bob vote now?
        vm.prank(bob);

        // Bob has sTokens but stakeStartTime = 0 (never staked himself)
        // VP = 0, so vote should fail
        uint256 bobVP = staking.getVotingPower(bob);
        console2.log('Bob VP after receiving sTokens:', bobVP);

        if (bobVP == 0) {
            vm.expectRevert(ILevrGovernor_v1.InsufficientVotingPower.selector);
            governor.vote(pid, false);
            console2.log('Bob cannot vote: VP = 0 (sToken transfer doesnt transfer VP)');
        } else {
            console2.log('POTENTIAL ISSUE: sToken transfer also transfers VP');
        }
    }

    // ============================================================================
    // CATEGORY F: PRECISION & ROUNDING
    // ============================================================================

    /// @notice Dust accumulation from fee splitting
    function test_precision_feeSplitDust() public pure {
        console2.log('\n=== Fee Split Rounding Dust ===');

        // Scenario: 3 receivers with 33.33% each (can't be exact with bps)
        // 3333 + 3333 + 3334 = 10000

        // Actually, let's test a real dust scenario:
        // 100 wei / 3 receivers with 3333 bps each
        // Receiver 1: (100 * 3333) / 10000 = 33
        // Receiver 2: (100 * 3333) / 10000 = 33
        // Receiver 3: (100 * 3334) / 10000 = 33
        // Total distributed: 99
        // Dust remaining: 1 wei

        console2.log('Fee split can leave dust due to rounding');
        console2.log('This is expected and handled by recoverDust()');
        console2.log('See LevrFeeSplitterV1.t.sol for comprehensive tests');
    }

    /// @notice Reward distribution with very small totalStaked
    function test_precision_rewardWithTinyTotalStaked() public {
        console2.log('\n=== Reward Distribution with Tiny Total Staked ===');

        // Alice stakes minimum amount
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1 ether); // Very small
        vm.stopPrank();

        // Accrue massive rewards
        MockERC20 reward = new MockERC20('Reward', 'RWD');
        _whitelistRewardToken(address(reward));
        reward.mint(address(staking), 1_000_000 ether);
        staking.accrueRewards(address(reward));

        uint256 totalStaked = staking.totalStaked() / 1e18;
        uint256 rewardAmount = 1_000_000;
        console2.log('Total staked:', totalStaked);
        console2.log('Reward amount:', rewardAmount);

        // Wait for stream
        vm.warp(block.timestamp + 3 days);

        // Alice claims
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 claimed = reward.balanceOf(alice);
        console2.log('Alice claimed:', claimed / 1e18);

        // Should get all rewards (she's the only staker)
        assertGt(claimed, 999_000 ether, 'Should get most rewards');
        console2.log('No precision loss with extreme ratios');
    }

    /// @notice accPerShare overflow test
    function test_precision_accPerShareOverflow() public {
        console2.log('\n=== AccPerShare Overflow Test ===');

        // accPerShare calculation:
        // accPerShare += (vestAmount * ACC_SCALE) / _totalStaked
        // ACC_SCALE = 1e18

        // Worst case: vestAmount = type(uint256).max, _totalStaked = 1
        // accPerShare = type(uint256).max * 1e18 / 1
        // This WILL overflow!

        uint256 accScale = 1e18;
        console2.log('ACC_SCALE:', accScale);

        // But in practice:
        // vestAmount <= total reward amount (realistic: < 1 billion tokens = 1e27)
        // _totalStaked >= 1 wei (realistic: >= 1 token = 1e18)
        // accPerShare = (1e27 * 1e18) / 1e18 = 1e27 (safe)

        console2.log('\nRealistic scenario:');
        console2.log('Vest amount: 1 billion tokens = 1e27 wei');
        console2.log('Total staked: 1 token = 1e18 wei');
        console2.log('accPerShare: (1e27 * 1e18) / 1e18 = 1e27 (safe)');

        // Test with realistic large values
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1 ether);
        vm.stopPrank();

        // Accrue 1 billion tokens
        MockERC20 reward = new MockERC20('Reward', 'RWD');
        _whitelistRewardToken(address(reward));
        reward.mint(address(staking), 1_000_000_000 ether);
        staking.accrueRewards(address(reward));

        console2.log('Accrued 1 billion reward tokens: SUCCESS (no overflow)');
    }

    // ============================================================================
    // CATEGORY G: TOKEN-SPECIFIC BEHAVIORS
    // ============================================================================

    /// @notice Token that reverts on zero transfer
    function test_tokenBehavior_revertsOnZeroTransfer() public {
        console2.log('\n=== Token Reverts on Zero Transfer ===');

        // Some tokens (like some old ERC20s) revert on zero amount transfers
        // Our code should handle this gracefully

        MaliciousZeroTransferToken malToken = new MaliciousZeroTransferToken();

        // Register with malicious token
        (LevrFactory_v1 fac, , ) = deployFactoryWithDefaultClanker(
            createDefaultConfig(protocolTreasury),
            address(this)
        );

        fac.prepareForDeployment();
        ILevrFactory_v1.Project memory proj = fac.register(address(malToken));

        // Try to unstake 0 (should be blocked by our validation, not token)
        malToken.mint(alice, 1000 ether);
        vm.startPrank(alice);
        malToken.approve(proj.staking, type(uint256).max);
        LevrStaking_v1(proj.staking).stake(100 ether);

        // Try to unstake 0
        vm.expectRevert(ILevrStaking_v1.InvalidAmount.selector);
        LevrStaking_v1(proj.staking).unstake(0, alice);
        vm.stopPrank();

        console2.log('Zero amount validation prevents token-specific issues');
    }

    // ============================================================================
    // CATEGORY H: MULTI-USER INTERACTIONS
    // ============================================================================

    /// @notice Two proposals executed back-to-back in same transaction
    function test_multiUser_sequentialProposalExecution() public {
        console2.log('\n=== Sequential Proposal Execution ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal in cycle 1
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Execute proposal 1 (auto-starts cycle 2)
        governor.execute(pid1);
        console2.log('Proposal 1 executed, cycle 2 started');

        // FIX: Create proposal immediately, then warp to voting window
        vm.prank(alice);
        uint256 pid2 = governor.proposeBoost(address(underlying), 1000 ether);

        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);
        console2.log('Proposal 2 created at:', block.timestamp);
        console2.log('Voting starts at:', p2.votingStartsAt);
        console2.log('Voting ends at:', p2.votingEndsAt);

        // Wait for voting window to start (proposal window = 2 days)
        vm.warp(p2.votingStartsAt + 1);
        console2.log('Warped to:', block.timestamp);

        // Double-check the proposal state
        p2 = governor.getProposal(pid2);
        console2.log('Proposal state before vote:', uint(p2.state));
        console2.log('Block timestamp:', block.timestamp);
        console2.log('Voting starts at:', p2.votingStartsAt);
        console2.log('Voting ends at (double-check):', p2.votingEndsAt);
        console2.log('Is block.timestamp < votingStartsAt?', block.timestamp < p2.votingStartsAt);
        console2.log('Is block.timestamp > votingEndsAt?', block.timestamp > p2.votingEndsAt);

        // Check Alice's VP
        uint256 aliceVP = staking.getVotingPower(alice);
        console2.log('Alice voting power:', aliceVP);

        vm.prank(alice);
        governor.vote(pid2, true);

        // Wait for voting window to end
        vm.warp(p2.votingEndsAt + 1);
        governor.execute(pid2);

        console2.log('Proposal 2 executed successfully');
        console2.log('Sequential execution works correctly');
    }

    /// @notice Rewards accrued while nobody is staked
    function test_multiUser_accrueRewardsWithNoStakers() public {
        console2.log('\n=== Accrue Rewards with No Stakers ===');

        // Nobody has staked yet
        assertEq(staking.totalStaked(), 0);

        // Accrue rewards anyway
        MockERC20 reward = new MockERC20('Reward', 'RWD');
        _whitelistRewardToken(address(reward));
        reward.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(reward));

        console2.log('Rewards accrued with totalStaked = 0');

        // Stream should pause (per M-2 fix)
        // Check that stream exists but hasn't consumed time

        // Bob stakes
        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        console2.log('Bob staked 100 tokens');

        // Wait for stream
        vm.warp(block.timestamp + 3 days);

        // Bob should get ALL rewards (he's the only staker and stream resumed)
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        uint256 bobRewards = reward.balanceOf(bob);
        console2.log('Bob claimed:', bobRewards / 1e18);

        assertGt(bobRewards, 999 ether, 'Bob should get all rewards');
        console2.log('Stream correctly preserved for first staker');
    }
}

/// @notice Mock token that reverts on zero transfers
contract MaliciousZeroTransferToken is MockERC20 {
    constructor() MockERC20('Malicious', 'MAL') {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(amount > 0, 'NO_ZERO_TRANSFER');
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(amount > 0, 'NO_ZERO_TRANSFER');
        return super.transferFrom(from, to, amount);
    }
}
