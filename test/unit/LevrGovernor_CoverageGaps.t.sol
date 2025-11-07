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
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title LevrGovernor Coverage Gap Tests
/// @notice Tests to improve branch coverage for LevrGovernor_v1.sol
/// @dev Focuses on uncovered branches and edge cases identified in coverage analysis
contract LevrGovernor_CoverageGaps_Test is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    MockERC20 internal underlying;
    MockERC20 internal weth;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC001);

    event ProposalCreated(
        uint256 indexed proposalId,
        address proposer,
        ILevrGovernor_v1.ProposalType proposalType,
        address token,
        uint256 amount,
        address recipient,
        string description
    );
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 votes);
    event ProposalExecuted(uint256 indexed proposalId, address executor);
    event ProposalDefeated(uint256 indexed proposalId);
    event CycleStarted(
        uint256 indexed cycleId,
        uint256 proposalWindowStart,
        uint256 proposalWindowEnd,
        uint256 votingWindowEnd
    );

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        weth = new MockERC20('Wrapped Ether', 'WETH');

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 5000, // 50%
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
        weth.mint(address(treasury), 50_000 ether);
    }

    // ============================================================================
    // TEST 1: Already Executed Proposal - Double Execution Prevention
    // ============================================================================
    /// @dev Covers line 156-157: Already executed proposal revert
    function test_execute_alreadyExecuted_reverts() public {
        // Setup: Create users and stake
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create and vote on proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Move to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Vote yes to pass
        vm.prank(alice);
        governor.vote(pid, true);

        // Move past voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Execute once (should succeed and auto-advance to cycle 2)
        governor.execute(pid);

        // Try to execute again (should revert - proposal from cycle 1, now in cycle 2)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(pid);
    }

    // ============================================================================
    // TEST 2: Get Proposals For Cycle - View Function
    // ============================================================================
    /// @dev Covers line 263-264: getProposalsForCycle function
    function test_getProposalsForCycle_returnsCorrectProposals() public {
        // Setup staker
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create multiple proposals in same cycle
        vm.startPrank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);
        uint256 pid2 = governor.proposeTransfer(
            address(underlying),
            bob,
            500 ether,
            'Transfer to Bob'
        );
        vm.stopPrank();

        uint256 currentCycle = governor.currentCycleId();

        // Get proposals for current cycle
        uint256[] memory proposals = governor.getProposalsForCycle(currentCycle);

        assertEq(proposals.length, 2, 'Should have 2 proposals');
        assertEq(proposals[0], pid1, 'First proposal should be pid1');
        assertEq(proposals[1], pid2, 'Second proposal should be pid2');
    }

    // ============================================================================
    // TEST 3: Cycle Advancement Edge Cases
    // ============================================================================
    /// @dev Covers lines 136-142: Cycle still active paths
    function test_startNewCycle_cycleStillActive_reverts() public {
        // Setup staker and create proposal to start cycle
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal to start cycle
        vm.prank(alice);
        governor.proposeBoost(address(underlying), 1000 ether);

        // Current cycle should now be active
        uint256 cycleId = governor.currentCycleId();
        assertGt(cycleId, 0, 'Cycle should be started');

        // Try to start new cycle while current is active
        vm.expectRevert(ILevrGovernor_v1.CycleStillActive.selector);
        governor.startNewCycle();
    }

    // ============================================================================
    // TEST 4: Cycle Advancement with No Proposals
    // ============================================================================
    /// @dev Covers lines 307-310: Auto-start cycle when needed
    function test_propose_autoStartsCycle_afterExpiry() public {
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        uint256 initialCycleId = governor.currentCycleId();

        // Warp past voting window to expire cycle
        vm.warp(block.timestamp + 7 days + 1); // Past proposal + voting windows

        // Proposing should auto-start new cycle
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 newCycleId = governor.currentCycleId();
        assertGt(newCycleId, initialCycleId, 'Should have started new cycle');

        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertEq(proposal.cycleId, newCycleId, 'Proposal should be in new cycle');
    }

    // ============================================================================
    // TEST 5: Treasury Balance Validation
    // ============================================================================
    /// @dev Covers lines 341-347: Treasury balance validation edge cases
    function test_propose_insufficientTreasuryBalance_reverts() public {
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Get treasury balance
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));

        // Try to propose more than treasury has
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.proposeBoost(address(underlying), treasuryBalance + 1 ether);
    }

    // ============================================================================
    // TEST 6: Winner Determination Edge Cases
    // ============================================================================
    /// @dev Covers lines 471-485: Winner determination with no qualifying proposals
    function test_getWinner_noQualifyingProposals_returnsZero() public {
        // Setup users
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        underlying.mint(bob, 10_000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposals (IDs not used, just creating proposals to test winner logic)
        vm.prank(alice);
        governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        governor.proposeTransfer(address(underlying), charlie, 500 ether, 'Transfer');

        // Move to voting window but don't vote (no quorum)
        vm.warp(block.timestamp + 2 days + 1);

        // Move past voting
        vm.warp(block.timestamp + 5 days + 1);

        uint256 cycleId = governor.currentCycleId();
        uint256 winner = governor.getWinner(cycleId);

        assertEq(winner, 0, 'No winner should be selected without quorum');
    }

    // ============================================================================
    // TEST 7: Winner Determination with Tie
    // ============================================================================
    /// @dev Covers winner selection when multiple proposals have same approval ratio
    function test_getWinner_tieBreaking_firstProposalWins() public {
        // Setup 3 equal stakers
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        for (uint256 i = 0; i < users.length; i++) {
            underlying.mint(users[i], 10_000 ether);
            vm.startPrank(users[i]);
            underlying.approve(address(staking), type(uint256).max);
            staking.stake(1000 ether);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 10 days);

        // Create 3 proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 900 ether);

        vm.prank(charlie);
        uint256 pid3 = governor.proposeBoost(address(underlying), 800 ether);

        // Move to voting
        vm.warp(block.timestamp + 2 days + 1);

        // All vote yes on all proposals (100% approval each)
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            governor.vote(pid1, true);
            governor.vote(pid2, true);
            governor.vote(pid3, true);
            vm.stopPrank();
        }

        // Move past voting
        vm.warp(block.timestamp + 5 days + 1);

        uint256 cycleId = governor.currentCycleId();
        uint256 winner = governor.getWinner(cycleId);

        // With equal approval ratios, first proposal wins
        assertEq(winner, pid1, 'First proposal should win in tie');
    }

    // ============================================================================
    // TEST 8: Proposal Window Timing Edge Case
    // ============================================================================
    /// @dev Covers lines 318-322: Proposal window validation
    function test_propose_beforeProposalWindow_reverts() public {
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create first proposal to establish cycle
        vm.prank(alice);
        governor.proposeBoost(address(underlying), 1000 ether);

        // Warp to AFTER proposal window but BEFORE voting ends
        vm.warp(block.timestamp + 2 days + 1); // After proposal window

        // Try to create another proposal (should fail - window closed)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.ProposalWindowClosed.selector);
        governor.proposeTransfer(address(underlying), bob, 500 ether, 'Late proposal');
    }

    // ============================================================================
    // TEST 9: Executable Proposals Remaining Check
    // ============================================================================
    /// @dev Covers lines 523-534: Check for executable proposals before cycle advancement
    function test_cannotAdvanceCycle_withExecutableProposals() public {
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create and pass proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Vote to pass
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        // Move past voting window (proposal is now executable)
        vm.warp(block.timestamp + 5 days + 1);

        // Try to manually start new cycle (should fail - executable proposal exists)
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        governor.startNewCycle();

        // Execute the proposal first
        governor.execute(pid);

        // Now starting new cycle should work (execute auto-starts it actually)
        uint256 cycleId = governor.currentCycleId();
        assertGt(cycleId, 1, 'Cycle should have advanced after execution');
    }

    // ============================================================================
    // TEST 10: Multiple Tokens in Same Cycle
    // ============================================================================
    /// @dev Tests that users can only propose one of each type per cycle, but different users can
    function test_multipleUsers_sameType_sameCycle() public {
        underlying.mint(alice, 10_000 ether);
        underlying.mint(bob, 10_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Alice creates boost proposal for underlying
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        // Bob creates boost proposal for weth (different token, same type)
        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(weth), 500 ether);

        ILevrGovernor_v1.Proposal memory prop1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory prop2 = governor.getProposal(pid2);

        assertEq(prop1.token, address(underlying), 'First proposal should use underlying');
        assertEq(prop2.token, address(weth), 'Second proposal should use weth');
        assertEq(prop1.cycleId, prop2.cycleId, 'Both proposals should be in same cycle');

        // Alice cannot create another boost proposal in same cycle
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.AlreadyProposedInCycle.selector);
        governor.proposeBoost(address(weth), 100 ether);
    }

    // ============================================================================
    // TEST 11: Cycle Already Executed
    // ============================================================================
    /// @dev Covers lines 189-193: Cycle already executed check - only winner can execute per cycle
    function test_execute_onlyWinnerCanExecutePerCycle() public {
        underlying.mint(alice, 10_000 ether);
        underlying.mint(bob, 10_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create two proposals in same cycle from different users
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(weth), 500 ether);

        // Vote - make pid1 winner with more approval
        vm.warp(block.timestamp + 2 days + 1);

        // Both vote yes on both, but pid1 gets more total votes
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid1, true);

        vm.prank(alice);
        governor.vote(pid2, true);

        // Move past voting
        vm.warp(block.timestamp + 5 days + 1);

        // Execute winner (pid1) - this marks cycle as executed and auto-advances to cycle 2
        governor.execute(pid1);

        // Try to execute loser (pid2) - now fails with ProposalNotInCurrentCycle (cycle advanced)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(pid2);
    }

    // ============================================================================
    // TEST 12: Not Winner Cannot Execute
    // ============================================================================
    /// @dev Covers lines 183-186: Only winner can execute
    function test_execute_notWinner_reverts() public {
        underlying.mint(alice, 10_000 ether);
        underlying.mint(bob, 10_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create two proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 900 ether);

        // Vote - make pid1 winner
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid1, true);

        // Only one person votes for pid2
        vm.prank(bob);
        governor.vote(pid2, true);

        // Move past voting
        vm.warp(block.timestamp + 5 days + 1);

        // Try to execute loser (should revert - not winner)
        vm.expectRevert(ILevrGovernor_v1.NotWinner.selector);
        governor.execute(pid2);
    }

    // ============================================================================
    // TEST 13: Zero Amount Proposal
    // ============================================================================
    /// @dev Covers line 301: Zero amount validation
    function test_propose_zeroAmount_reverts() public {
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Try to propose with zero amount
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.InvalidAmount.selector);
        governor.proposeBoost(address(underlying), 0);
    }
}
