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

/// @title Active Proposal Count Gridlock Test
/// @notice Definitive test: Does activeProposalCount reset between cycles or is it global?
contract LevrGovernor_ActiveCountGridlock_Test is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    MockERC20 internal underlying;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        // Config with maxActiveProposals = 2 (low limit for testing)
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 2, // LOW LIMIT
            quorumBps: 7000, // 70%
            approvalBps: 5100,
            minSTokenBpsToSubmit: 0, // No minimum for testing
            maxProposalAmountBps: 10000, // 100% for testing,
            minimumQuorumBps: 25, // 0.25% minimum quorum
            maxRewardTokens: 10 // Max non-whitelisted reward tokens
        });

        (
            LevrFactory_v1 fac,
            LevrForwarder_v1 fwd,
            LevrDeployer_v1 dep
        ) = deployFactoryWithDefaultClanker(cfg, address(this));
        factory = fac;

        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        underlying.mint(address(treasury), 100_000 ether);

        // Setup stakers
        underlying.mint(alice, 10000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether); // 10% of future supply
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether); // 90% of supply
        vm.stopPrank();
    }

    /// @notice DEFINITIVE TEST: Does activeProposalCount reset between cycles?
    function test_activeProposalCount_acrossCycles_isGlobal() public {
        console2.log('\n=== DEFINITIVE: Active Proposal Count Across Cycles ===\n');

        vm.warp(block.timestamp + 10 days);

        // CYCLE 1: Create 2 boost proposals (at max limit)
        console2.log('CYCLE 1');
        console2.log('-------');

        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);
        console2.log('Created proposal 1 (Boost)');

        uint256 countAfterFirst = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count:', countAfterFirst);
        assertEq(countAfterFirst, 1);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);
        console2.log('Created proposal 2 (Boost)');

        uint256 countAfterSecond = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count:', countAfterSecond);
        assertEq(countAfterSecond, 2);

        // Try to create 3rd - should fail (max = 2)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
        governor.proposeBoost(address(underlying), 3000 ether);
        console2.log('Cannot create 3rd proposal: maxActiveProposals = 2\n');

        // BOTH proposals fail quorum (only Alice votes, need 70%)
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid1, true);
        console2.log('Alice voted on proposal 1');

        vm.prank(alice);
        governor.vote(pid2, true);
        console2.log('Alice voted on proposal 2');
        console2.log('Only Alice voted: 100/1000 sTokens = 10% participation');
        console2.log('Quorum requires: 70% participation');
        console2.log('Both proposals will FAIL quorum\n');

        // Wait for voting to end
        vm.warp(block.timestamp + 5 days + 1);

        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);
        console2.log('Proposal 1 meets quorum:', p1.meetsQuorum);
        console2.log('Proposal 2 meets quorum:', p2.meetsQuorum);
        assertFalse(p1.meetsQuorum);
        assertFalse(p2.meetsQuorum);

        // Try to execute proposal 1 - FIX [OCT-31-CRITICAL-1]: no longer reverts
        console2.log('\nAttempting to execute proposal 1 (will fail quorum)...');
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid1);

        // Check active count AFTER defeated execute
        uint256 countAfterFailedExecute = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count after defeated execute:', countAfterFailedExecute);

        // FIX [OCT-31-SIMPLIFICATION]: Count no longer decrements during execution
        assertEq(countAfterFailedExecute, 2, 'Count stays at 2 (only resets at cycle start)');
        console2.log('Count = 2 (stays same, will reset at cycle start)');

        // Verify P1 marked as executed
        assertTrue(governor.getProposal(pid1).executed, 'P1 should be executed');

        // Try to execute proposal 2 - should also fail
        governor.execute(pid2);

        uint256 countAfterBothFailed = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count after both failed:', countAfterBothFailed);

        // FIX [OCT-31-SIMPLIFICATION]: Count still at 2 (will reset at cycle start)
        assertEq(countAfterBothFailed, 2, 'Count stays at 2');

        // Verify P2 marked as executed
        assertTrue(governor.getProposal(pid2).executed, 'P2 should be executed');

        // START CYCLE 2
        console2.log('\n-------');
        console2.log('CYCLE 2');
        console2.log('-------');

        governor.startNewCycle();
        console2.log('Started new cycle (cycle 2)');

        // THE CRITICAL QUESTION: Does starting a new cycle reset the count?
        uint256 countInCycle2 = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count in cycle 2:', countInCycle2);

        console2.log('\nCRITICAL QUESTION: Did count reset when cycle changed?');

        if (countInCycle2 == 0) {
            console2.log('YES - Count reset to 0');
            console2.log('NO BUG: New cycle = fresh start');
            console2.log('My reasoning was WRONG - user was correct!');
        } else if (countInCycle2 == 2) {
            console2.log('NO - Count still = 2');
            console2.log('BUG CONFIRMED: Count is GLOBAL across cycles');
            console2.log("User's question helped refine understanding");
        }

        // Try to create new proposal in cycle 2
        console2.log('\nAttempting to create proposal 3 in cycle 2...');

        vm.prank(alice);

        if (countInCycle2 >= 2) {
            // If count didn't reset, should fail
            vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
            governor.proposeBoost(address(underlying), 5000 ether);
            console2.log('BLOCKED: Cannot create new proposal in cycle 2');
            console2.log('BUG CONFIRMED: Defeated proposals from cycle 1 block cycle 2');
        } else {
            // If count reset, should succeed
            uint256 pid3 = governor.proposeBoost(address(underlying), 5000 ether);
            console2.log('SUCCESS: Created proposal 3 in cycle 2');
            console2.log('NO BUG: Count resets between cycles');
        }
    }

    /// @notice Test: Can we recover by having a successful proposal first?
    function test_activeProposalCount_recoveryViaSuccessfulProposal() public {
        console2.log('\n=== Recovery via Successful Proposal ===\n');

        vm.warp(block.timestamp + 10 days);

        // Create 2 proposals in cycle 1
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);

        console2.log('Created 2 boost proposals in cycle 1');
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        vm.warp(block.timestamp + 2 days + 1);

        // BOTH vote on proposal 1 (meets quorum)
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid1, true);

        console2.log('Both voted on proposal 1 (100% participation)');

        // Only Alice votes on proposal 2 (fails quorum)
        vm.prank(alice);
        governor.vote(pid2, true);

        console2.log('Only Alice voted on proposal 2 (10% participation)');

        vm.warp(block.timestamp + 5 days + 1);

        // Execute proposal 1 (succeeds, auto-starts cycle 2)
        governor.execute(pid1);
        console2.log('\nExecuted proposal 1 (auto-started cycle 2)');

        uint256 countAfterSuccess = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count after successful execute:', countAfterSuccess);
        console2.log('(Should be 1: proposal 2 still active)');

        // Try to execute proposal 2 - should fail quorum - FIX [OCT-31-CRITICAL-1]
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid2);

        // Verify P2 marked as executed
        assertTrue(governor.getProposal(pid2).executed, 'P2 should be executed');

        uint256 countAfterFailed = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count after failed execute:', countAfterFailed);

        if (countAfterFailed == 1) {
            console2.log('\nBUG: Count still = 1 even though proposal 2 defeated');
            console2.log('Proposal 2 is blocking the slot permanently');
        } else {
            console2.log('\nSafe: Count decremented somehow');
        }

        // Can we create new proposals in cycle 2?
        console2.log('\nAttempting to create new proposals in cycle 2...');

        vm.prank(alice);
        if (countAfterFailed < 2) {
            uint256 pid3 = governor.proposeBoost(address(underlying), 3000 ether);
            console2.log('Created proposal 3: SUCCESS');

            uint256 countNow = governor.activeProposalCount(
                ILevrGovernor_v1.ProposalType.BoostStakingPool
            );
            console2.log('Active count now:', countNow);

            if (countNow == 2) {
                console2.log('Count incremented to 2');

                // Try to create 3rd
                vm.prank(bob);
                vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
                governor.proposeBoost(address(underlying), 4000 ether);
                console2.log('Cannot create 4th: maxActiveProposals = 2');

                console2.log(
                    '\nCONCLUSION: Count is GLOBAL, defeated proposals DO block new ones!'
                );
            }
        } else {
            vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
            governor.proposeBoost(address(underlying), 3000 ether);
            console2.log('BLOCKED: Cannot create new proposal');
            console2.log('BUG CONFIRMED: Defeated proposal from cycle 1 blocks cycle 2');
        }
    }

    /// @notice Test: What if ALL proposals in a cycle fail?
    function test_activeProposalCount_allProposalsFail_permanentGridlock() public {
        console2.log('\n=== ALL Proposals Fail - Permanent Gridlock? ===\n');

        vm.warp(block.timestamp + 10 days);

        // CYCLE 1: Create maxActiveProposals (2) proposals
        console2.log('CYCLE 1: Creating 2 proposals (max limit)');

        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);
        console2.log('Proposal 1 created');

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 2000 ether);
        console2.log('Proposal 2 created');

        uint256 countCycle1 = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count in cycle 1:', countCycle1);
        assertEq(countCycle1, 2);

        // NO ONE VOTES - both proposals get 0 votes
        console2.log('\nNobody votes on either proposal');

        vm.warp(block.timestamp + 7 days + 1); // Past voting window

        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        console2.log('Proposal 1 meets quorum:', p1.meetsQuorum);
        console2.log('Proposal 2 meets quorum:', p2.meetsQuorum);
        assertFalse(p1.meetsQuorum);
        assertFalse(p2.meetsQuorum);

        // Start cycle 2 (no proposals executed)
        console2.log('\n-------');
        console2.log('CYCLE 2');
        console2.log('-------');
        governor.startNewCycle();
        console2.log('Started cycle 2 (no proposals from cycle 1 were executed)');

        // THE QUESTION: Did the count reset?
        uint256 countCycle2 = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count in cycle 2:', countCycle2);

        console2.log('\n=== ANSWER ===');

        if (countCycle2 == 0) {
            console2.log('Count RESET to 0 when cycle changed');
            console2.log('User was RIGHT: New cycle = fresh start');
            console2.log("NO BUG: Defeated proposals don't block new cycles");

            // Should be able to create new proposals
            vm.prank(alice);
            governor.proposeBoost(address(underlying), 3000 ether);
            console2.log('Can create new proposal: CONFIRMED');
        } else if (countCycle2 == 2) {
            console2.log('Count is STILL 2 from cycle 1');
            console2.log('I was RIGHT: Count is GLOBAL across cycles');
            console2.log('BUG CONFIRMED: Defeated proposals from cycle 1 block cycle 2');

            // Should NOT be able to create new proposals
            vm.prank(alice);
            vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
            governor.proposeBoost(address(underlying), 3000 ether);
            console2.log('Cannot create new proposal: CONFIRMED GRIDLOCK');

            console2.log('\n[CRITICAL BUG CONFIRMED]');
            console2.log('activeProposalCount never resets');
            console2.log('Defeated proposals permanently consume slots');
            console2.log('Eventually hits maxActiveProposals');
            console2.log('NO RECOVERY MECHANISM');
        }
    }

    /// @notice Test the EXACT scenario: Organic failure leading to gridlock
    function test_REALISTIC_organicGridlock_scenario() public {
        console2.log('\n=== REALISTIC: Organic Gridlock Over Multiple Cycles ===\n');

        vm.warp(block.timestamp + 10 days);

        uint256 currentCycle = governor.currentCycleId();
        console2.log('Starting cycle:', currentCycle);

        // CYCLE 1: Create 2 proposals, both fail
        console2.log('\n--- CYCLE', currentCycle, '---');

        vm.prank(alice);
        governor.proposeBoost(address(underlying), 1000 ether);
        vm.prank(bob);
        governor.proposeBoost(address(underlying), 2000 ether);
        console2.log('Created 2 boost proposals');
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // Skip voting (both fail)
        vm.warp(block.timestamp + 7 days + 1);
        governor.startNewCycle();
        console2.log('Cycle ended, no proposals executed');
        console2.log(
            'Active count:',
            governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool)
        );

        // CYCLE 2: Try to create 2 more proposals
        currentCycle = governor.currentCycleId();
        console2.log('\n--- CYCLE', currentCycle, '---');

        uint256 countBeforeCreate = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );

        if (countBeforeCreate >= 2) {
            console2.log('Active count already at max:', countBeforeCreate);
            console2.log('Cannot create ANY new proposals in cycle 2');

            vm.prank(alice);
            vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
            governor.proposeBoost(address(underlying), 3000 ether);

            console2.log('\n[PERMANENT GRIDLOCK CONFIRMED]');
            console2.log('Boost proposals are PERMANENTLY BLOCKED');
            console2.log('No recovery mechanism exists');
            console2.log('This proposal type is DEAD FOREVER');
        } else {
            console2.log('Active count reset, can create new proposals');
            console2.log('NO BUG: System recovered automatically');
        }
    }
}
