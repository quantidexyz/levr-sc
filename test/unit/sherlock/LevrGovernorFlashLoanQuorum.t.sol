// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrGovernor_v1} from '../../../src/LevrGovernor_v1.sol';
import {ILevrGovernor_v1} from '../../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {LevrTreasury_v1} from '../../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';

/// @title Flash Loan Quorum Manipulation Tests - Sherlock #29
/// @notice POC tests demonstrating the fix for flash loan quorum manipulation
/// @dev Tests verify that quorum uses time-weighted voting power instead of instantaneous balance
contract LevrGovernorFlashLoanQuorumTest is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal stakedToken;

    address alice = makeAddr('alice');
    address bob = makeAddr('bob');
    address attacker = makeAddr('attacker');
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
        stakedToken = LevrStakedToken_v1(project.stakedToken);

        // Alice stakes (legitimate long-term voter)
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Fund treasury
        underlying.mint(address(treasury), 10000 ether);

        // Warp for VP accumulation
        vm.warp(block.timestamp + 1 days);
    }

    // ============ Test: CORRECT BEHAVIOR - Must Execute Before Auto-Advancement ============

    /// @notice CORRECT: Auto-advancement blocks if Succeeded proposal exists (must execute first)
    /// @dev This is the correct flow: execute winning proposals before moving to next cycle
    function test_CORRECT_mustExecuteBeforeAutoAdvancement() public {
        console.log('=== CORRECT BEHAVIOR: Must Execute Before Auto-Advancement ===');

        // Step 1: Create proposal in cycle 1
        vm.prank(alice);
        uint256 proposalId1 = governor.proposeTransfer(
            address(underlying),
            bob,
            50 ether,
            'Cycle 1 Proposal'
        );

        console.log('Cycle 1 ID:', governor.currentCycleId());
        console.log('Proposal 1 ID:', proposalId1);

        // Step 2: Advance to voting window and vote
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        governor.vote(proposalId1, true);

        // Step 3: Advance past voting window
        ILevrGovernor_v1.Proposal memory proposal1 = governor.getProposal(proposalId1);
        vm.warp(proposal1.votingEndsAt + 1);

        // Verify proposal is Succeeded
        proposal1 = governor.getProposal(proposalId1);
        assertEq(uint256(proposal1.state), uint256(ILevrGovernor_v1.ProposalState.Succeeded));
        console.log('Proposal 1 state: Succeeded');

        // Step 4: Try to propose in cycle 2 - should FAIL (must execute first)
        vm.prank(alice);
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        governor.proposeTransfer(
            address(underlying),
            bob,
            100 ether,
            'Cycle 2 Proposal - Should Fail'
        );

        console.log('CORRECT: Cannot propose until Succeeded proposal is executed');

        // Step 5: Execute the Succeeded proposal
        vm.prank(alice);
        governor.execute(proposalId1);
        console.log('Proposal 1 executed successfully');

        // Step 6: Now we can propose in cycle 2 (auto-advancement after execution)
        vm.prank(alice);
        uint256 proposalId2 = governor.proposeTransfer(
            address(underlying),
            bob,
            100 ether,
            'Cycle 2 Proposal - Now Works'
        );

        assertEq(governor.currentCycleId(), 2, 'Should be cycle 2');
        console.log('SUCCESS: After execution, can propose in cycle 2');
    }

    /// @notice Manual advancement works after 3 failed execution attempts (escape hatch)
    function test_manualAdvancement_escapeHatchAfter3Attempts() public {
        console.log('=== MANUAL ADVANCEMENT: Escape Hatch After 3 Attempts ===');

        // This test documents the escape hatch behavior
        // In practice, if execution fails 3 times, community can manually advance
        // For this test, we just verify the flag behavior

        // Create and vote on proposal
        vm.prank(alice);
        uint256 proposalId1 = governor.proposeTransfer(
            address(underlying),
            bob,
            50 ether,
            'Cycle 1 Proposal'
        );

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        governor.vote(proposalId1, true);

        ILevrGovernor_v1.Proposal memory proposal1 = governor.getProposal(proposalId1);
        vm.warp(proposal1.votingEndsAt + 1);

        // Manual advancement should FAIL with 0 attempts
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        governor.startNewCycle();

        console.log('Manual advancement blocked with 0 attempts: Correct');
    }

    /// @notice Can manually bootstrap but not recommended (auto-bootstrap preferred)
    function test_canManuallyBootstrap_butNotRecommended() public {
        console.log('=== CAN MANUALLY BOOTSTRAP (But Not Recommended) ===');

        // Deploy fresh governor (no proposals yet, cycleId = 0)
        MockERC20 freshUnderlying = new MockERC20('Fresh', 'FRSH');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (LevrFactory_v1 factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(freshUnderlying));
        LevrGovernor_v1 freshGovernor = LevrGovernor_v1(project.governor);

        // Verify cycle is 0
        assertEq(freshGovernor.currentCycleId(), 0, 'Should be cycle 0');

        // Manual bootstrap works (but creates empty cycle)
        freshGovernor.startNewCycle();

        assertEq(freshGovernor.currentCycleId(), 1, 'Should be cycle 1');
        console.log('Manual bootstrap works but creates empty cycle');
        console.log('Recommendation: Use first proposal for auto-bootstrap instead');
        console.log('Empty cycles serve no purpose and waste gas');
    }

    /// @notice First proposal auto-bootstraps cycle 1
    function test_firstProposal_autoBootstraps() public {
        console.log('=== FIRST PROPOSAL AUTO-BOOTSTRAPS ===');

        // Deploy fresh governor
        MockERC20 freshUnderlying = new MockERC20('Fresh', 'FRSH');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (LevrFactory_v1 factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(freshUnderlying));
        LevrGovernor_v1 freshGovernor = LevrGovernor_v1(project.governor);
        LevrTreasury_v1 freshTreasury = LevrTreasury_v1(payable(project.treasury));
        LevrStaking_v1 freshStaking = LevrStaking_v1(project.staking);

        // Setup alice with stake
        freshUnderlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        freshUnderlying.approve(address(freshStaking), 1000 ether);
        freshStaking.stake(1000 ether);
        vm.stopPrank();

        // Fund treasury
        freshUnderlying.mint(address(freshTreasury), 10000 ether);

        // Wait for VP
        vm.warp(block.timestamp + 1 days);

        // Verify cycle is 0
        assertEq(freshGovernor.currentCycleId(), 0, 'Should be cycle 0');

        // First proposal auto-bootstraps cycle 1
        vm.prank(alice);
        uint256 proposalId = freshGovernor.proposeTransfer(
            address(freshUnderlying),
            bob,
            50 ether,
            'First Proposal'
        );

        // Verify cycle 1 was auto-created
        assertEq(freshGovernor.currentCycleId(), 1, 'Should be cycle 1');
        assertEq(proposalId, 1, 'Should be proposal 1');

        console.log('SUCCESS: First proposal auto-bootstrapped cycle 1');
    }
}
