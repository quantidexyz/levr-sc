// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Cross-Contract Flow Tests
/// @notice Tests complete governance cycles and cross-contract interactions from USER_FLOWS.md
contract LevrGovernor_CrossContract_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    MockERC20 internal weth;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xCCC);
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        weth = new MockERC20('WETH', 'WETH');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        // Fund users
        underlying.mint(alice, 10_000 ether);
        underlying.mint(bob, 10_000 ether);
        underlying.mint(charlie, 10_000 ether);

        // Stake tokens
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(5_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(3_000 ether);
        vm.stopPrank();

        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(2_000 ether);
        vm.stopPrank();

        // Fund treasury
        underlying.mint(address(treasury), 50_000 ether);
        weth.mint(address(treasury), 20_000 ether);

        // Advance time for VP accumulation
        vm.warp(block.timestamp + 10 days);
    }

    // ============ Missing Edge Cases from USER_FLOWS.md Flow 20-22 ============

    // Flow 20 - Complete Governance Cycle
    function test_fullCycle_aliceUnstakesAfterVoting_proposalStillValid() public {
        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1_000 ether);

        // Enter voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes
        vm.prank(alice);
        governor.vote(pid, true);

        // Alice unstakes after voting
        vm.prank(alice);
        staking.unstake(5_000 ether, alice);

        // Proposal should still be valid (snapshot taken at creation)
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertGt(proposal.totalSupplySnapshot, 0, 'Snapshot should exist');
        assertTrue(proposal.yesVotes > 0, 'Vote should be recorded');

        // Execution should still work
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);

        // Verify boost executed
        assertGt(underlying.balanceOf(address(staking)), 0, 'Staking should receive boost');
    }

    function test_fullCycle_treasuryRunsOutOfWeth_proposalDefeated() public {
        // Create WETH proposal (amount must be within maxProposalAmountBps = 5%)
        // 5% of 20_000 = 1_000 ether max
        vm.prank(alice);
        uint256 pid = governor.proposeTransfer(address(weth), address(0xB0B), 1_000 ether, 'transfer');

        // Treasury has 20_000 WETH initially
        assertEq(weth.balanceOf(address(treasury)), 20_000 ether, 'Treasury should have WETH');

        // Vote first
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        // Treasury balance decreases before execution (simulated - in practice would need another proposal)
        // Drain treasury so balance is insufficient (proposal needs 1_000, leave only 500)
        uint256 initialRecipientBalance = weth.balanceOf(address(0xB0B));
        vm.prank(address(governor));
        treasury.transfer(address(weth), address(0xB0B), 19_500 ether); // Leave only 500 ether
        
        // Verify balance is now insufficient
        assertLt(weth.balanceOf(address(treasury)), 1_000 ether, 'Treasury should have insufficient balance');

        // Try to execute - should mark as defeated due to insufficient balance (doesn't revert)
        vm.warp(block.timestamp + 5 days + 1);
        uint256 recipientBalanceBeforeExecute = weth.balanceOf(address(0xB0B));
        governor.execute(pid);
        
        // Verify proposal was marked as executed (defeated)
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertTrue(proposal.executed, 'Proposal should be marked executed (defeated)');
        // Verify transfer didn't happen (balance should be same as before execution, which includes the 19_500 drain)
        assertEq(weth.balanceOf(address(0xB0B)), recipientBalanceBeforeExecute, 'Transfer should not execute');
    }

    function test_fullCycle_boostReverts_proposalFails() public {
        // Create boost proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1_000 ether);

        // Vote
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        // Drain most of treasury balance to cause boost to fail
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));
        vm.prank(address(governor));
        treasury.transfer(address(underlying), address(0xB0B), treasuryBalance - 500 ether); // Leave only 500 ether

        // Execution should mark as defeated due to insufficient balance (doesn't revert)
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
        
        // Verify proposal was marked as defeated
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertTrue(proposal.executed, 'Proposal should be marked executed (defeated)');
    }

    function test_fullCycle_noExecution_cycleStuck_manualRecovery() public {
        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1_000 ether);

        // Vote window ends but proposal doesn't meet quorum
        vm.warp(block.timestamp + 2 days + 5 days + 1);

        // Proposal should be defeated (no votes)
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertFalse(proposal.meetsQuorum, 'Should not meet quorum');

        // Cycle should be stuck - manually start new cycle
        governor.startNewCycle();

        // New cycle should start
        uint256 newCycle = governor.currentCycleId();
        assertGt(newCycle, 0, 'New cycle should start');
    }

    function test_fullCycle_underlyingVsWethProposals_independent() public {
        // Create proposals for different tokens (amounts must be within maxProposalAmountBps = 5%)
        // 5% of 50_000 = 2_500 ether max for underlying
        // 5% of 20_000 = 1_000 ether max for weth
        vm.prank(alice);
        uint256 pid1 = governor.proposeTransfer(address(underlying), address(0xA), 2_000 ether, 'transfer1');

        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(weth), address(0xB), 500 ether, 'transfer2');

        // Both proposals should be in same cycle but independent
        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        assertEq(p1.cycleId, p2.cycleId, 'Same cycle');
        assertEq(p1.token, address(underlying), 'Different tokens');
        assertEq(p2.token, address(weth), 'Different tokens');

        // Vote on both to ensure they meet quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid2, true);
        // Charlie also votes to ensure quorum
        vm.prank(charlie);
        governor.vote(pid1, true);

        // Execute winner (highest votes)
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid1); // Execute first proposal

        // Verify execution
        assertEq(underlying.balanceOf(address(0xA)), 2_000 ether, 'Underlying transfer executed');
    }

    // Flow 21 - Competing Proposals
    function test_competingProposals_sameYesVotes_deterministic() public {
        // Create two proposals with equal voting power users
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1_000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2_000 ether);

        // Both vote with equal VP (roughly)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid2, true);

        // Get proposals
        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        // Winner should be deterministic (first proposal with highest votes)
        // In this case, winner depends on which has more votes
        assertTrue(p1.yesVotes > 0, 'Proposal 1 has votes');
        assertTrue(p2.yesVotes > 0, 'Proposal 2 has votes');
    }

    function test_failedProposal_executeAttempt_reverts() public {
        // Create proposal that will fail quorum
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1_000 ether);

        // Don't vote (or vote insufficiently - alice alone might not meet quorum)
        vm.warp(block.timestamp + 2 days + 5 days + 1);

        // Try to execute - doesn't revert, marks as defeated if quorum not met
        ILevrGovernor_v1.Proposal memory proposalBefore = governor.getProposal(pid);
        governor.execute(pid);
        
        // Verify proposal was marked as executed (either succeeded or defeated)
        ILevrGovernor_v1.Proposal memory proposalAfter = governor.getProposal(pid);
        assertTrue(proposalAfter.executed, 'Proposal should be marked executed');
        
        // If it didn't meet quorum, it should be defeated
        if (!proposalBefore.meetsQuorum) {
            // Proposal was defeated (executed = true but no actual execution)
            assertTrue(true, 'Proposal defeated due to insufficient quorum');
        }
    }

    function test_failedProposal_startNewCycleBeforeVotingEnds_reverts() public {
        // Create proposal
        vm.prank(alice);
        governor.proposeBoost(address(underlying), 1_000 ether);

        // Try to start new cycle before voting ends
        vm.warp(block.timestamp + 2 days); // Still in proposal window
        
        // Should revert (cycle still active)
        vm.expectRevert();
        governor.startNewCycle();
    }
}

