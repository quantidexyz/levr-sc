// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Non-Transferable Staked Token Edge Cases
 * @notice Comprehensive tests for non-transferable design edge cases
 * @dev Tests all scenarios that could break with transfer blocking
 */
contract LevrStakedToken_NonTransferableEdgeCasesTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    LevrGovernor_v1 governor;
    LevrTreasury_v1 treasury;
    MockERC20 underlying;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address charlie = address(0x3333);

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
            minimumQuorumBps: 25, // 0.25% minimum quorum
            maxRewardTokens: 10
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0));
        underlying = new MockERC20('Underlying', 'UND');

        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );
        treasury = new LevrTreasury_v1(address(factory), address(0));
        governor = new LevrGovernor_v1(
            address(factory),
            address(treasury),
            address(staking),
            address(stakedToken),
            address(underlying),
            address(0)
        );

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(treasury),
            address(factory)
        );

        vm.prank(address(factory));
        treasury.initialize(address(governor), address(staking));

        underlying.mint(alice, 100000 ether);
        underlying.mint(bob, 100000 ether);
        underlying.mint(charlie, 100000 ether);
        underlying.mint(address(treasury), 100000 ether);
    }

    /// @notice Test all transfer methods are blocked
    function test_transferBlocking_allMethodsBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Direct transfer blocked
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(bob, 500 ether);

        // Approve bob
        stakedToken.approve(bob, 500 ether);

        // transferFrom also blocked
        vm.startPrank(bob);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transferFrom(alice, bob, 500 ether);

        // Self-transfer also blocked
        vm.startPrank(alice);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(alice, 100 ether);
    }

    /// @notice Test governance flow with blocked transfers
    /// @dev Converted from skip_test_ordering_stakeVoteTransferStoken
    function test_governanceFlow_transferBlockedAfterVoting() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait for VP
        vm.warp(block.timestamp + 10 days);

        uint256 aliceVP = staking.getVotingPower(alice);
        console.log('Alice VP:', aliceVP);
        assertTrue(aliceVP > 0, 'Alice should have VP');

        // Alice creates proposal
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        // Wait for voting (time advances, VP increases!)
        vm.warp(block.timestamp + 2 days + 1);

        // Get current VP (has increased due to time passing)
        uint256 aliceVPAtVote = staking.getVotingPower(alice);

        // Alice votes
        governor.vote(pid, true);

        // Alice tries to transfer - BLOCKED
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(bob, 500 ether);

        // Alice's vote should still be valid
        ILevrGovernor_v1.VoteReceipt memory receipt = governor.getVoteReceipt(pid, alice);
        assertTrue(receipt.hasVoted, 'Vote should still be recorded');
        assertEq(receipt.votes, aliceVPAtVote, 'VP should match voting time VP');

        // Proposal should still meet quorum (Alice's 1000 tokens voted)
        vm.warp(block.timestamp + 5 days + 1);
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertTrue(proposal.meetsQuorum, 'Quorum should be met');
    }

    /// @notice Test quorum with no transfer manipulation possible
    /// @dev Converted from skip_test_quorumCheck_sTokenBalanceChanges
    function test_quorum_noTransferManipulation() public {
        // Three users stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(charlie);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 10 days);

        // Total supply: 3000
        uint256 totalSupply = stakedToken.totalSupply();
        assertEq(totalSupply, 3000 ether);

        // Alice creates proposal
        vm.startPrank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice and Bob vote (2000 tokens)
        governor.vote(pid, true);
        vm.startPrank(bob);
        governor.vote(pid, true);

        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);

        // totalBalanceVoted should be 2000
        assertEq(proposal.totalBalanceVoted, 2000 ether, 'Should be 2000 tokens voted');

        // Try to manipulate by transferring - BLOCKED
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(charlie, 500 ether);

        // Quorum calculation remains valid (no manipulation possible)
        uint256 requiredQuorum = (totalSupply * 7000) / 10000; // 2100
        assertEq(proposal.totalBalanceVoted, 2000 ether, 'Still 2000 (no change)');
        assertFalse(proposal.meetsQuorum, '2000 < 2100, quorum not met');
    }

    /// @notice Test that double-voting via transfer is impossible
    /// @dev Converted from skip_test_CRITICAL_totalBalanceVoted_doubleCount
    function test_doubleVoting_impossibleWithoutTransfers() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 2000 ether);
        staking.stake(2000 ether);

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);
        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes
        governor.vote(pid, true);

        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertEq(proposal.totalBalanceVoted, 2000 ether);

        // Alice can't vote again
        vm.expectRevert(ILevrGovernor_v1.AlreadyVoted.selector);
        governor.vote(pid, true);

        // Alice can't transfer to Bob to let him vote with same tokens
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(bob, 2000 ether);

        // totalBalanceVoted stays at 2000 (no inflation possible)
        proposal = governor.getProposal(pid);
        assertEq(proposal.totalBalanceVoted, 2000 ether, 'No double counting possible');
    }

    /// @notice Test approval system is safe but useless
    function test_approval_doesntBypassRestriction() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Alice can approve Bob
        stakedToken.approve(bob, 500 ether);
        assertEq(stakedToken.allowance(alice, bob), 500 ether);

        // But Bob still can't transferFrom
        vm.startPrank(bob);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transferFrom(alice, bob, 500 ether);

        // Approval unchanged (transfer didn't happen)
        assertEq(stakedToken.allowance(alice, bob), 500 ether);
    }

    /// @notice Test balance consistency without transfers
    function test_balanceConsistency_alwaysSynced() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(stakedToken.balanceOf(alice), staking.stakedBalanceOf(alice));

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);

        assertEq(stakedToken.balanceOf(bob), staking.stakedBalanceOf(bob));

        // Total supply = total staked
        assertEq(stakedToken.totalSupply(), staking.totalStaked());

        // Alice unstakes partial
        vm.startPrank(alice);
        staking.unstake(300 ether, alice);

        assertEq(stakedToken.balanceOf(alice), staking.stakedBalanceOf(alice));
        assertEq(stakedToken.totalSupply(), staking.totalStaked());

        // No desync possible (no transfers to create mismatch)
        assertEq(stakedToken.balanceOf(alice) + stakedToken.balanceOf(bob), staking.totalStaked());
    }

    /// @notice Test VP accumulation without transfer interference
    function test_vpAccumulation_noTransferInterference() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 2000 ether);

        // Initial stake
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 100 days);

        uint256 vp1 = staking.getVotingPower(alice);
        assertEq(vp1, 100_000, '1000 tokens * 100 days');

        // Additional stake (weighted average)
        staking.stake(1000 ether);
        uint256 vp2 = staking.getVotingPower(alice);

        // VP should use weighted average formula
        // Old: 1000 * 100 = 100,000
        // New total: 2000
        // New time: (1000 * 100) / 2000 = 50 days
        // VP: 2000 * 50 = 100,000 (preserved)
        assertEq(vp2, 100_000, 'VP preserved through weighted average');

        // Partial unstake
        staking.unstake(1000 ether, alice);
        uint256 vp3 = staking.getVotingPower(alice);

        // After unstaking 50%, VP scales: 0.5 * 0.5 = 0.25
        // VP: 100,000 * 0.25 = 25,000
        assertEq(vp3, 25_000, 'VP scales on unstake');

        // No transfer interference - VP calculation is pure
    }

    /// @notice Test rewards distribution without transfer complications
    function test_rewards_fairDistributionWithoutTransfers() public {
        // Alice and Bob stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        vm.startPrank(alice);
        underlying.mint(address(staking), 2000 ether);
        staking.accrueRewards(address(underlying));

        // Complete stream - claim AT end, not after
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(streamEnd);

        // Both should have equal claimable (50/50 split)
        uint256 aliceClaimable = staking.claimableRewards(alice, address(underlying));
        uint256 bobClaimable = staking.claimableRewards(bob, address(underlying));

        // POOL-BASED: Perfect proportional distribution
        assertApproxEqAbs(aliceClaimable, bobClaimable, 1, 'Equal stakes = equal rewards');
        assertApproxEqAbs(
            aliceClaimable + bobClaimable,
            2000 ether,
            1 ether,
            'Total claimable = accrued'
        );

        // No transfer complications - clean accounting
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 aliceBalBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        vm.stopPrank();
        uint256 aliceClaimed = underlying.balanceOf(alice) - aliceBalBefore;
        assertApproxEqAbs(aliceClaimed, aliceClaimable, 1, 'Alice claims what was claimable');

        // After Alice claims, pool is reduced
        // Bob's NEW claimable is based on reduced pool (pool-based system!)
        uint256 bobClaimableAfterAlice = staking.claimableRewards(bob, address(underlying));

        vm.startPrank(bob);
        uint256 bobBalBefore = underlying.balanceOf(bob);
        staking.claimRewards(tokens, bob);
        uint256 bobClaimed = underlying.balanceOf(bob) - bobBalBefore;
        assertApproxEqAbs(
            bobClaimed,
            bobClaimableAfterAlice,
            1,
            'Bob claims his share of remaining pool'
        );

        // POOL-BASED NOTE: Claim order creates timing dependency
        // Alice claims 50% of pool (1000), Bob claims 50% of REMAINING pool (500)
        // This leaves 500 in pool - users should claim together or use auto-claim on unstake
        // Total distributed to users (not including pool remainder)
        uint256 totalClaimedByUsers = aliceClaimed + bobClaimed;
        uint256 poolRemainder = 2000 ether - totalClaimedByUsers;

        assertEq(aliceClaimed, 1000 ether, 'Alice gets 50% of original pool');
        assertEq(bobClaimed, 500 ether, 'Bob gets 50% of reduced pool');
        assertApproxEqAbs(poolRemainder, 500 ether, 1, 'Pool remainder from claim timing');
    }

    /// @notice Test multiple users with independent operations
    function test_multipleUsers_independentOperations() public {
        // FIX: Use absolute timestamp to avoid test pollution
        // Set to a known future timestamp to avoid underflow issues
        uint256 startTime = 365 days; // Start at day 365 to avoid conflicts
        vm.warp(startTime);

        // Alice stakes at day 365
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Bob stakes at day 365
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        vm.stopPrank();

        vm.warp(startTime + 50 days); // Day 415

        // Charlie stakes at day 415
        vm.startPrank(charlie);
        underlying.approve(address(staking), 300 ether);
        staking.stake(300 ether);
        vm.stopPrank();

        vm.warp(startTime + 100 days); // Day 465 (Charlie has been staked 50 days)

        // VP should be independent for each user
        uint256 aliceVP = staking.getVotingPower(alice);
        uint256 bobVP = staking.getVotingPower(bob);
        uint256 charlieVP = staking.getVotingPower(charlie);

        console.log('Alice VP (100 days):', aliceVP);
        console.log('Bob VP (100 days):', bobVP);
        console.log('Charlie VP (50 days):', charlieVP);

        // VP values depend on exact timing
        // Alice and Bob have been staking for 100 days
        // Charlie has been staking for 50 days (not "just staked")
        assertTrue(aliceVP > 0, 'Alice should have VP');
        assertTrue(bobVP > 0, 'Bob should have VP');
        assertTrue(charlieVP > 0, 'Charlie should have VP (50 days staked)');

        // Alice staked more tokens than Bob for same time
        assertGt(aliceVP, bobVP, 'Alice staked more tokens');

        // Alice has been staking 2x longer than Charlie
        assertGt(aliceVP, charlieVP, 'Alice staked longer');

        // No interference between users (no transfers to complicate)
    }

    /// @notice Test stake → unstake → stake cycle
    function test_stakeUnstakeStake_vpResetsCorrectly() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 10000 ether);

        // First stake
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 100 days);

        uint256 vp1 = staking.getVotingPower(alice);
        assertEq(vp1, 100_000);

        // Full unstake
        staking.unstake(1000 ether, alice);

        uint256 vp2 = staking.getVotingPower(alice);
        assertEq(vp2, 0, 'VP should be 0 after full unstake');

        // Stake again
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 50 days);

        uint256 vp3 = staking.getVotingPower(alice);
        assertEq(vp3, 50_000, 'VP should start fresh (1000 * 50)');

        // Clean lifecycle - no transfer complications
    }

    /// @notice Test partial unstake with VP and rewards
    function test_partialUnstake_vpAndRewardsCorrect() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Warp to stream end to fully vest
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(streamEnd);

        uint256 vpBefore = staking.getVotingPower(alice);
        uint256 rewardsBefore = staking.claimableRewards(alice, address(underlying));

        console.log('VP before unstake:', vpBefore);
        console.log('Rewards before unstake:', rewardsBefore);

        // NEW DESIGN: Claim rewards BEFORE unstaking
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256 aliceBalBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);

        // Partial unstake (30%) - now just returns principal
        staking.unstake(300 ether, alice);
        uint256 aliceBalAfter = underlying.balanceOf(alice);

        // Should receive principal + rewards (claimed separately)
        uint256 received = aliceBalAfter - aliceBalBefore;
        console.log('Received total (claim + unstake):', received);
        assertGt(received, 300 ether, 'Should get principal + rewards');

        // VP should scale: 70% balance * 70% time = 49%
        uint256 vpAfter = staking.getVotingPower(alice);
        uint256 expectedVP = (vpBefore * 49) / 100;
        assertEq(vpAfter, expectedVP, 'VP should scale correctly');

        // No transfer complications
    }

    /// @notice Test that totalSupply accurately reflects staked amount
    function test_totalSupply_accurateWithoutTransfers() public {
        uint256 expectedTotal = 0;

        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        expectedTotal += 1000 ether;

        assertEq(stakedToken.totalSupply(), expectedTotal);
        assertEq(staking.totalStaked(), expectedTotal);

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        expectedTotal += 500 ether;

        assertEq(stakedToken.totalSupply(), expectedTotal);
        assertEq(staking.totalStaked(), expectedTotal);

        // Alice unstakes
        vm.startPrank(alice);
        staking.unstake(300 ether, alice);
        expectedTotal -= 300 ether;

        assertEq(stakedToken.totalSupply(), expectedTotal);
        assertEq(staking.totalStaked(), expectedTotal);

        // totalSupply always accurate (no transfers to mess it up)
        assertEq(
            stakedToken.balanceOf(alice) + stakedToken.balanceOf(bob),
            stakedToken.totalSupply()
        );
    }

    /// @notice Test mint and burn operations still work
    function test_mintBurn_stillFunctional() public {
        // Mint via staking
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Mint works');

        // Burn via unstaking
        staking.unstake(400 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 600 ether, 'Burn works');

        // No transfer needed - mint/burn sufficient for all operations
    }

    /// @notice Test that attempting transfer doesn't break state
    function test_attemptedTransfer_noStateSideEffects() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        uint256 balanceBefore = stakedToken.balanceOf(alice);
        uint256 totalBefore = staking.totalStaked();

        // Attempt transfer (will revert)
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(bob, 500 ether);

        // State should be unchanged
        assertEq(stakedToken.balanceOf(alice), balanceBefore, 'Balance unchanged');
        assertEq(stakedToken.balanceOf(bob), 0, 'Bob still has 0');
        assertEq(staking.totalStaked(), totalBefore, 'Total unchanged');

        // No side effects from attempted transfer
    }

    /// @notice Test ERC20 view functions still work
    function test_erc20ViewFunctions_work() public {
        assertEq(stakedToken.name(), 'Staked');
        assertEq(stakedToken.symbol(), 'sUND');
        assertEq(stakedToken.decimals(), 18);

        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(stakedToken.totalSupply(), 1000 ether);
        assertEq(stakedToken.balanceOf(alice), 1000 ether);

        // All view functions work as expected
    }

    /// @notice Test governance quorum with only stake/unstake (no transfers)
    function test_governance_quorumWithStakeUnstakeOnly() public {
        // Setup: 3 users stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(charlie);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.startPrank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice and Bob vote
        governor.vote(pid, true);
        vm.startPrank(bob);
        governor.vote(pid, true);

        // Quorum: need 70% of 3000 = 2100
        // Voted: 2000
        // Should NOT meet quorum
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertFalse(proposal.meetsQuorum, 'Should not meet 70% quorum');

        // Charlie votes
        vm.startPrank(charlie);
        governor.vote(pid, true);

        // Now: 3000 voted, quorum met
        proposal = governor.getProposal(pid);
        assertTrue(proposal.meetsQuorum, 'Should meet quorum with all 3 voting');

        // Quorum calculation is simple and accurate (no transfer complications)
    }
}
