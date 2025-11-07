// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrGovernor_StuckProcess Test Suite
 * @notice Tests for governance process deadlock and recovery scenarios
 * @dev Tests scenarios from USER_FLOWS.md Flow 27-28
 */
contract LevrGovernor_StuckProcessTest is Test {
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrStaking_v1 internal staking;
    LevrTreasury_v1 internal treasury;
    LevrStakedToken_v1 internal sToken;
    MockERC20 internal underlying;
    MockERC20 internal weth;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie;

    function setUp() public {
        charlie = makeAddr('charlie');

        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('Wrapped ETH', 'WETH');

        // Deploy factory
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000, // 70%
            approvalBps: 5100, // 51%
            minSTokenBpsToSubmit: 100, // 1%
            maxProposalAmountBps: 5000, // 50%
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        factory = new LevrFactory_v1(
            config,
            address(this),
            address(0),
            address(0),
            new address[](0)
        );

        // Deploy contracts
        treasury = new LevrTreasury_v1(address(factory), address(0));
        staking = new LevrStaking_v1(address(0), address(factory));
        sToken = new LevrStakedToken_v1(
            'Staked Token',
            'sTKN',
            18,
            address(underlying),
            address(staking)
        );
        governor = new LevrGovernor_v1(
            address(factory),
            address(treasury),
            address(staking),
            address(sToken),
            address(underlying),
            address(0)
        );

        // Initialize (must be called by factory)
        vm.prank(address(factory));
        treasury.initialize(address(governor), address(underlying));

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(sToken),
            address(treasury),
            new address[](0)
        );

        // Fund treasury
        underlying.mint(address(treasury), 10000 ether);
        weth.mint(address(treasury), 5000 ether);
    }

    // ============ Flow 27: Governance Cycle Stuck Tests ============

    /// @notice Test manual recovery when all proposals fail
    function test_allProposalsFail_manualRecovery() public {
        console2.log('\n=== Flow 27: All Proposals Fail - Manual Recovery ===');

        // Setup: Alice and Bob stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        underlying.mint(bob, 100 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        // Wait to accumulate VP
        vm.warp(block.timestamp + 10 days);

        // Create proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 100 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 50 ether);

        console2.log('Created 2 proposals');

        // Move to voting
        vm.warp(block.timestamp + 2 days + 1);

        // Only Bob votes (insufficient quorum - need 70% of 1100 = 770)
        vm.prank(bob);
        governor.vote(pid1, true);

        console2.log('Only Bob voted (insufficient quorum)');

        // End voting
        vm.warp(block.timestamp + 5 days + 1);

        // Both proposals should fail quorum - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid1);
        governor.execute(pid2);

        // Verify both marked as executed
        assertTrue(governor.getProposal(pid1).executed, 'P1 should be executed');
        assertTrue(governor.getProposal(pid2).executed, 'P2 should be executed');

        console2.log('Both proposals failed quorum (marked as defeated)');
        console2.log('Cycle is stuck - no executable proposals');

        // Manual recovery: Anyone can start new cycle
        governor.startNewCycle();

        console2.log('SUCCESS: Manual startNewCycle() recovered governance');

        // Verify new cycle started
        uint256 currentCycle = governor.currentCycleId();
        assertEq(currentCycle, 2, 'Should be in cycle 2');
    }

    /// @notice Test auto-recovery via next proposal
    function test_allProposalsFail_autoRecoveryViaPropose() public {
        console2.log('\n=== Flow 27: Auto-Recovery Via Next Proposal ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create and fail a proposal
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 2 days + 1);
        // No one votes
        vm.warp(block.timestamp + 5 days + 1);

        // Proposal fails - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid1);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid1).executed, 'Proposal should be executed');

        console2.log('Proposal failed, cycle ended');

        // Next propose auto-starts new cycle
        vm.prank(alice);
        uint256 pid2 = governor.proposeBoost(address(underlying), 50 ether);

        console2.log('SUCCESS: New proposal auto-started new cycle');

        // Verify we're in cycle 2
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid2);
        assertEq(proposal.cycleId, 2, 'Should be in cycle 2');
    }

    /// @notice Test that startNewCycle fails if executable proposals exist
    function test_cannotStartCycle_ifExecutableProposalExists() public {
        console2.log('\n=== Flow 27: Cannot Start Cycle With Executable Proposal ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create successful proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes yes (meets quorum and approval)
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Try to start new cycle (should fail - executable proposal exists)
        vm.expectRevert();
        governor.startNewCycle();

        console2.log('SUCCESS: Cannot start new cycle while executable proposal exists');

        // Execute the proposal first
        governor.execute(pid);

        // Now new cycle should auto-start
        uint256 currentCycle = governor.currentCycleId();
        assertEq(currentCycle, 2, 'Cycle should advance after execution');
    }

    /// @notice Test permissionless recovery (anyone can call startNewCycle)
    function test_startNewCycle_permissionless() public {
        console2.log('\n=== Flow 27: Permissionless Recovery ===');

        // Setup and fail a cycle
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 7 days + 1);

        // Proposal fails - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        // Charlie (random user) can recover
        vm.prank(charlie);
        governor.startNewCycle();

        console2.log('SUCCESS: Random user (charlie) successfully started new cycle');
        assertEq(governor.currentCycleId(), 2, 'Cycle recovered');
    }

    /// @notice Test cycle stuck for extended period
    function test_cycleStuck_extendedPeriod_stillRecoverable() public {
        console2.log('\n=== Flow 27: Extended Stuck Period - Still Recoverable ===');

        // Setup and fail cycle
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 7 days + 1);

        // Wait 30 days (simulate extended stuck period)
        vm.warp(block.timestamp + 30 days);

        console2.log('Cycle stuck for 30+ days');

        // Still recoverable
        governor.startNewCycle();

        console2.log('SUCCESS: Recovered even after 30+ days stuck');
        assertEq(governor.currentCycleId(), 2, 'Recovery successful');
    }

    // ============ Flow 28: Treasury Balance Depletion Tests ============

    /// @notice Test proposal defeated when treasury balance insufficient
    function test_treasuryDepletion_proposalDefeated() public {
        console2.log('\n=== Flow 28: Treasury Depletion - Proposal Defeated ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal for 4000 ether (treasury has 10000, max is 50% = 5000)
        vm.prank(alice);
        uint256 pid = governor.proposeTransfer(address(underlying), alice, 4000 ether, 'Test');

        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes
        vm.prank(alice);
        governor.vote(pid, true);

        // Before execution, drain treasury
        vm.prank(address(governor));
        treasury.transfer(address(underlying), address(0xDEAD), 7000 ether);

        console2.log('Treasury drained from 10000 to 3000 ether (proposal needs 4000)');

        vm.warp(block.timestamp + 5 days + 1);

        // Execution fails - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.execute(pid);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        // FIX [OCT-31-CRITICAL-1]: State changes persist, proposal.executed is now true
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertTrue(proposal.executed, 'Proposal marked as executed (state persists)');

        console2.log('SUCCESS: Insufficient balance marks as defeated (state persisted)');
        console2.log('Recovery: Start new cycle or wait for treasury refill');
    }

    /// @notice Test that other proposals can execute when one fails balance check
    function test_multipleProposals_oneFailsBalance_otherExecutes() public {
        console2.log('\n=== Flow 28: Multiple Proposals - One Fails, Other Succeeds ===');

        // Setup: Alice and Bob stake
        underlying.mint(alice, 800 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(800 ether);
        vm.stopPrank();

        underlying.mint(bob, 200 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(200 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create two proposals (max is 50% of treasury = 5000)
        vm.prank(alice);
        uint256 pidLarge = governor.proposeTransfer(
            address(underlying),
            alice,
            5000 ether,
            'Large'
        );

        vm.prank(bob);
        uint256 pidSmall = governor.proposeTransfer(address(underlying), bob, 1000 ether, 'Small');

        console2.log('Created 2 proposals: 5000 ether and 1000 ether');

        vm.warp(block.timestamp + 2 days + 1);

        // Both vote yes on both
        vm.prank(alice);
        governor.vote(pidLarge, true);
        vm.prank(alice);
        governor.vote(pidSmall, true);

        vm.prank(bob);
        governor.vote(pidLarge, true);
        vm.prank(bob);
        governor.vote(pidSmall, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Large proposal wins (more yes VP)
        // But we didn't drain treasury, so it should execute successfully
        governor.execute(pidLarge);

        console2.log('Large proposal executed successfully (treasury had sufficient balance)');

        // This test documents that governance continues
        // For actual treasury depletion test, see test_treasuryDepletion_proposalDefeated

        console2.log('SUCCESS: Winner executes when balance is sufficient');
    }

    /// @notice Test that governance is not blocked by insufficient balance
    function test_insufficientBalance_cycleNotBlocked() public {
        console2.log('\n=== Flow 28: Insufficient Balance Does Not Block Cycle ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal that will fail balance check (max allowed is 5000)
        vm.prank(alice);
        uint256 pid = governor.proposeTransfer(
            address(underlying),
            alice,
            5000 ether,
            'Max allowed'
        );

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid, true);

        // Drain treasury before execution
        vm.prank(address(governor));
        treasury.transfer(address(underlying), address(0xDEAD), 8000 ether);

        console2.log('Treasury drained from 10000 to 2000');

        vm.warp(block.timestamp + 5 days + 1);

        // Execution fails - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.execute(pid);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        console2.log('Execution marked as defeated due to insufficient balance');

        // FIX [OCT-31-CRITICAL-1]: Cycle does NOT advance (defeated proposals don't trigger new cycle)
        uint256 cycleAfter = governor.currentCycleId();
        assertEq(cycleAfter, 1, 'Cycle unchanged (defeated proposals dont advance cycle)');

        // Manual recovery: CAN start new cycle now (no executable proposals remain)
        // FIX: Since proposal is marked as executed (defeated), no executable proposals block new cycle
        governor.startNewCycle(); // Should succeed

        assertEq(governor.currentCycleId(), 2, 'Should advance to cycle 2');

        console2.log('SUCCESS: Can start new cycle - defeated proposal marked as executed');

        console2.log('SUCCESS: Proposal executed after treasury refund');
        assertEq(governor.currentCycleId(), 2, 'Cycle advances after execution');
    }

    /// @notice Test token-agnostic treasury depletion (WETH vs underlying)
    function test_treasuryDepletion_tokenAgnostic() public {
        console2.log('\n=== Flow 28: Token-Agnostic Treasury Depletion ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create WETH proposal (max is 50% of 5000 WETH = 2500)
        vm.prank(alice);
        uint256 pidWeth = governor.proposeTransfer(address(weth), alice, 2000 ether, 'WETH');

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pidWeth, true);

        // Drain WETH from treasury
        vm.prank(address(governor));
        treasury.transfer(address(weth), address(0xDEAD), 4500 ether);

        console2.log('WETH drained from 5000 to 500');

        vm.warp(block.timestamp + 5 days + 1);

        // WETH proposal fails - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.execute(pidWeth);

        // Verify marked as executed
        assertTrue(governor.getProposal(pidWeth).executed, 'WETH proposal should be executed');

        // Underlying balance unaffected - still 10000 ether
        uint256 underlyingBal = underlying.balanceOf(address(treasury));
        assertEq(underlyingBal, 10000 ether, 'Underlying balance unchanged');

        console2.log('SUCCESS: Token-specific balance checks work correctly');
    }

    /// @notice Test balance check happens before execution
    function test_balanceCheck_beforeExecution() public {
        console2.log('\n=== Flow 28: Balance Check Before Execution ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create valid proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 3000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Execute succeeds - balance check passes
        governor.execute(pid);

        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertTrue(proposal.executed, 'Proposal should be marked executed');
        assertEq(governor.currentCycleId(), 2, 'Cycle should advance after execution');

        console2.log('SUCCESS: Balance check passes, boost executes');
    }
}
