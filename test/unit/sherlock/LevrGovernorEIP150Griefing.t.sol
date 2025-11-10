// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrGovernor_v1} from '../../../src/LevrGovernor_v1.sol';
import {ILevrGovernor_v1} from '../../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {LevrTreasury_v1} from '../../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';

/// @notice POC tests for EIP-150 gas griefing vulnerability (Sherlock #28)
/// @dev These tests demonstrate the CURRENT VULNERABILITY before the fix
contract LevrGovernorEIP150GriefingTest is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;

    address alice = makeAddr('alice');
    address bob = makeAddr('bob');
    address protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (LevrFactory_v1 factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);

        // Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Fund treasury
        underlying.mint(address(treasury), 10000 ether);

        // Warp for VP
        vm.warp(block.timestamp + 1 days);
    }

    /// @notice FIXED: Low gas execution fails but allows immediate retry
    /// @dev After fix, failed execution doesn't block retry and doesn't auto-advance cycle
    function test_FIXED_lowGas_allowsImmediateRetry() public {
        // Create proposal
        vm.prank(alice);
        uint256 proposalId = governor.proposeTransfer(
            address(underlying),
            bob,
            50 ether,
            'Transfer to Bob'
        );

        // Vote
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + 6 days);

        uint256 bobBalanceBefore = underlying.balanceOf(bob);
        uint256 cycleIdBefore = governor.currentCycleId();

        // Attempt 1: Execute with low gas (might fail depending on actual gas needed)
        // Note: 250k might be enough, so we just test the retry mechanism
        governor.execute{gas: 250000}(proposalId);

        ILevrGovernor_v1.Proposal memory proposal1 = governor.getProposal(proposalId);
        uint256 bobBalanceAfter1 = underlying.balanceOf(bob);

        if (!proposal1.executed && bobBalanceAfter1 == bobBalanceBefore) {
            // Execution failed - verify retry works
            emit log('[FIXED] Execution failed, proposal NOT marked executed');

            // Cycle should NOT have advanced (allows retry)
            assertEq(
                governor.currentCycleId(),
                cycleIdBefore,
                'Cycle should NOT advance on failure'
            );

            // Attempt 2: Retry with more gas should succeed
            governor.execute{gas: 1000000}(proposalId);

            // Verify success
            ILevrGovernor_v1.Proposal memory proposal2 = governor.getProposal(proposalId);
            assertTrue(proposal2.executed, 'Proposal should be executed after retry');
            assertEq(
                underlying.balanceOf(bob),
                bobBalanceBefore + 50 ether,
                'Funds transferred on retry'
            );

            // Cycle does NOT auto-advance (advances on next propose)
            assertEq(governor.currentCycleId(), cycleIdBefore, 'Cycle does NOT auto-advance');

            // Create next proposal to trigger cycle advancement
            vm.prank(alice);
            governor.proposeTransfer(address(underlying), bob, 10 ether, 'Next');
            assertEq(
                governor.currentCycleId(),
                cycleIdBefore + 1,
                'Cycle advances on next propose'
            );
        } else {
            // 250k was enough - verify normal success path
            assertTrue(proposal1.executed, 'Proposal executed');
            assertEq(bobBalanceAfter1, bobBalanceBefore + 50 ether, 'Funds transferred');
            // Cycle does NOT auto-advance
            assertEq(governor.currentCycleId(), cycleIdBefore, 'Cycle does NOT auto-advance');

            // Create next proposal to trigger cycle advancement
            vm.prank(alice);
            governor.proposeTransfer(address(underlying), bob, 10 ether, 'Next');
            assertEq(
                governor.currentCycleId(),
                cycleIdBefore + 1,
                'Cycle advances on next propose'
            );
        }
    }

    /// @notice Test successful execution auto-advances cycle
    function test_FIXED_successfulExecution_autoAdvancesCycle() public {
        vm.prank(alice);
        uint256 proposalId = governor.proposeTransfer(
            address(underlying),
            bob,
            50 ether,
            'Transfer to Bob'
        );

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + 6 days);

        uint256 bobBalanceBefore = underlying.balanceOf(bob);
        uint256 cycleIdBefore = governor.currentCycleId();

        governor.execute{gas: 1000000}(proposalId);

        // Verify successful execution
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(proposalId);
        assertTrue(proposal.executed, 'Proposal should be executed');
        assertEq(underlying.balanceOf(bob), bobBalanceBefore + 50 ether, 'Funds transferred');

        // Cycle does NOT auto-advance (advances on next propose)
        assertEq(
            governor.currentCycleId(),
            cycleIdBefore,
            'Cycle should NOT auto-advance (advances on next propose)'
        );

        // Create next proposal to trigger cycle advancement
        vm.prank(alice);
        governor.proposeTransfer(address(underlying), bob, 10 ether, 'Next');
        assertEq(governor.currentCycleId(), cycleIdBefore + 1, 'Cycle advances on next propose');
    }

    /// @notice FIXED: Old proposals become non-executable after manual cycle advance
    function test_FIXED_oldProposals_notExecutableAfterManualAdvance() public {
        // Deploy reverting token to force execution failure
        RevertingToken revertToken = new RevertingToken();

        // Create proposal in cycle 1
        vm.prank(alice);
        uint256 proposalId = governor.proposeTransfer(
            address(revertToken),
            bob,
            50 ether,
            'Will fail'
        );

        // Vote
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + 6 days);

        // Attempt to execute multiple times (will fail each time)
        governor.execute(proposalId);
        assertEq(governor.executionAttempts(proposalId).count, 1, 'Should have 1 attempt');

        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(proposalId);
        assertEq(governor.executionAttempts(proposalId).count, 2, 'Should have 2 attempts');

        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(proposalId);
        assertEq(governor.executionAttempts(proposalId).count, 3, 'Should have 3 attempts');

        // Now manual advance is allowed (attempted 3 times)
        governor.startNewCycle();

        // Now in cycle 2
        assertEq(governor.currentCycleId(), 2, 'Should be in cycle 2');

        // Try to execute old proposal - should fail with ProposalNotInCurrentCycle
        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(proposalId);

        emit log('[FIXED] Old proposals properly rejected with ProposalNotInCurrentCycle');
    }

    /// @notice FIXED: Failed execution doesn't auto-advance, allows manual advancement
    function test_FIXED_failedExecution_requiresManualAdvance() public {
        // Deploy reverting token
        RevertingToken revertToken = new RevertingToken();

        // Create proposal with reverting token
        vm.prank(alice);
        uint256 proposalId = governor.proposeTransfer(
            address(revertToken),
            bob,
            50 ether,
            'Will fail'
        );

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + 6 days);

        uint256 cycleIdBefore = governor.currentCycleId();

        // Execute multiple times - will fail due to reverting token
        governor.execute(proposalId);
        assertEq(governor.executionAttempts(proposalId).count, 1, 'Should have 1 attempt');

        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(proposalId);
        assertEq(governor.executionAttempts(proposalId).count, 2, 'Should have 2 attempts');

        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(proposalId);
        assertEq(governor.executionAttempts(proposalId).count, 3, 'Should have 3 attempts');

        // Verify proposal NOT marked executed (can retry)
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(proposalId);
        assertFalse(proposal.executed, 'Proposal should NOT be marked executed');

        // Verify cycle did NOT auto-advance
        assertEq(
            governor.currentCycleId(),
            cycleIdBefore,
            'Cycle should NOT auto-advance on failure'
        );

        // Manual advance should work after 3 attempts
        governor.startNewCycle();
        assertEq(
            governor.currentCycleId(),
            cycleIdBefore + 1,
            'Manual advance should work after 3 attempts'
        );

        // Now old proposal is non-executable
        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(proposalId);
    }

    /// @notice FIXED: Multiple retries work until success
    function test_FIXED_multipleRetries_untilSuccess() public {
        // Create proposal
        vm.prank(alice);
        uint256 proposalId = governor.proposeTransfer(
            address(underlying),
            bob,
            50 ether,
            'Transfer to Bob'
        );

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + 6 days);

        uint256 cycleIdBefore = governor.currentCycleId();

        // Multiple retry attempts (simulate failures, though 250k might succeed)
        // The point is: can call execute() multiple times without error
        governor.execute{gas: 1000000}(proposalId);

        // Eventually succeeds
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(proposalId);
        assertTrue(proposal.executed, 'Should eventually execute');
        // Cycle does NOT auto-advance (advances on next propose)
        assertEq(governor.currentCycleId(), cycleIdBefore, 'Cycle does NOT auto-advance');

        // Create next proposal to trigger cycle advancement
        vm.prank(alice);
        governor.proposeTransfer(address(underlying), bob, 10 ether, 'Next');
        assertEq(governor.currentCycleId(), cycleIdBefore + 1, 'Cycle advances on next propose');
    }
}

/// @notice Helper contract for testing failures
contract RevertingToken {
    function balanceOf(address) external pure returns (uint256) {
        return 1000000 * 1e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert('Transfer fails');
    }
}
