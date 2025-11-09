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

/// @notice POC tests for non-winner state confusion (Sherlock #33)
/// @dev Tests that non-winning proposals show as Defeated, not Succeeded
/// @dev BEFORE FIX: Non-winners show as Succeeded (test will FAIL)
/// @dev AFTER FIX: Non-winners show as Defeated (test will PASS)
contract LevrGovernorNonWinnerStateTest is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;

    address alice = makeAddr('alice');
    address bob = makeAddr('bob');
    address charlie = makeAddr('charlie');
    address protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Underlying', 'UND');
        tokenA = new MockERC20('Token A', 'TKNA');
        tokenB = new MockERC20('Token B', 'TKNB');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (LevrFactory_v1 factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);

        // Setup stakers with voting power
        // Need enough participation to meet 70% quorum
        // Total: 2000 tokens, so need 1400+ to vote for quorum

        // Alice: 1000 tokens → will vote YES on both proposals
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Bob: 500 tokens → will vote NO on Proposal A, YES on Proposal B
        underlying.mint(bob, 500 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        vm.stopPrank();

        // Charlie: 500 tokens → will vote YES on Proposal B only
        underlying.mint(charlie, 500 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        vm.stopPrank();

        // Fund treasury with both tokens
        tokenA.mint(address(treasury), 10000 ether);
        tokenB.mint(address(treasury), 10000 ether);

        // Warp to accumulate voting power
        vm.warp(block.timestamp + 10 days);
    }

    /// @notice SHERLOCK #33 - Core validation test
    /// @dev Non-winner proposals must show as Defeated, not Succeeded
    /// @dev BEFORE FIX: This test will FAIL (propA.state = Succeeded)
    /// @dev AFTER FIX: This test will PASS (propA.state = Defeated)
    function test_SHERLOCK_33_nonWinner_mustShowDefeated() public {
        emit log('=== SHERLOCK #33: Non-Winner State Validation ===');

        // Step 1: Create two proposals in same cycle
        vm.prank(alice);
        uint256 proposalA = governor.proposeBoost(address(tokenA), 100 ether);
        emit log_named_uint('Proposal A ID', proposalA);

        vm.prank(bob);
        uint256 proposalB = governor.proposeBoost(address(tokenB), 200 ether);
        emit log_named_uint('Proposal B ID', proposalB);

        // Step 2: Vote on proposals
        // Advance to voting phase
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 100);

        // Proposal A: 67% approval (1000 yes, 500 no = 1500 total = 75% quorum)
        // Alice votes YES (1000 tokens)
        vm.prank(alice);
        governor.vote(proposalA, true);

        // Bob votes NO (500 tokens)
        vm.prank(bob);
        governor.vote(proposalA, false);

        // Proposal B: 100% approval (1000+500+500=2000 yes, 0 no = 100% quorum)
        // Alice votes YES (1000 tokens)
        vm.prank(alice);
        governor.vote(proposalB, true);

        // Bob votes YES (500 tokens)
        vm.prank(bob);
        governor.vote(proposalB, true);

        // Charlie votes YES on B (500 tokens)
        vm.prank(charlie);
        governor.vote(proposalB, true);

        // Step 3: End voting
        vm.warp(block.timestamp + 5 days);

        // Step 4: Check winner
        uint256 cycleId = governor.currentCycleId();
        uint256 winnerId = governor.getWinner(cycleId);

        emit log('');
        emit log('=== VOTING RESULTS ===');

        ILevrGovernor_v1.Proposal memory propA = governor.getProposal(proposalA);
        ILevrGovernor_v1.Proposal memory propB = governor.getProposal(proposalB);

        // Calculate approval ratios for logging
        uint256 totalVotesA = propA.yesVotes + propA.noVotes;
        uint256 approvalRatioA = (propA.yesVotes * 10000) / totalVotesA;
        emit log_named_uint('Proposal A approval ratio (bps)', approvalRatioA);

        uint256 totalVotesB = propB.yesVotes + propB.noVotes;
        uint256 approvalRatioB = (propB.yesVotes * 10000) / totalVotesB;
        emit log_named_uint('Proposal B approval ratio (bps)', approvalRatioB);

        // Verify Proposal B is the winner (higher approval)
        assertEq(winnerId, proposalB, 'Proposal B should be the winner (higher approval)');
        emit log_named_uint('Winner ID', winnerId);

        // Verify both proposals meet thresholds
        assertTrue(propA.meetsQuorum, 'Proposal A should meet quorum');
        assertTrue(propA.meetsApproval, 'Proposal A should meet approval');
        assertTrue(propB.meetsQuorum, 'Proposal B should meet quorum');
        assertTrue(propB.meetsApproval, 'Proposal B should meet approval');

        emit log('');
        emit log('=== STATE VALIDATION ===');

        // THE CRITICAL ASSERTION:
        // Non-winner (Proposal A) must show as Defeated, not Succeeded
        emit log_named_uint(
            'Proposal A state (0=Pending,1=Active,2=Defeated,3=Succeeded,4=Executed)',
            uint8(propA.state)
        );
        emit log_named_uint('Proposal B state', uint8(propB.state));

        // BEFORE FIX: This assertion will FAIL
        // propA.state = Succeeded (wrong!) because it meets quorum+approval
        //
        // AFTER FIX: This assertion will PASS
        // propA.state = Defeated (correct!) because it's not the winner
        assertEq(
            uint8(propA.state),
            uint8(ILevrGovernor_v1.ProposalState.Defeated),
            'SHERLOCK #33: Non-winner MUST show as Defeated (not Succeeded)'
        );

        // Winner must show as Succeeded
        assertEq(
            uint8(propB.state),
            uint8(ILevrGovernor_v1.ProposalState.Succeeded),
            'Winner MUST show as Succeeded'
        );

        emit log('');
        emit log('[TEST RESULT] Non-winner correctly shows as Defeated');
        emit log('[SHERLOCK #33] VULNERABILITY FIXED');
    }

    /// @notice Additional test: Cycle advancement not blocked by non-winner
    /// @dev Verifies that non-winners don't prevent new cycle from starting
    /// @dev NOTE: This functionality is already tested in e2e tests
    /// @dev Skipping here due to token whitelisting setup complexity
    // function test_SHERLOCK_33_nonWinner_doesNotBlockCycleAdvancement() public {
    //     // Covered in test/e2e/LevrV1.Governance.t.sol::test_canStartNewCycleAfterExecutingProposals
    // }

    /// @notice Edge case: Multiple non-winners all show Defeated
    function test_SHERLOCK_33_multipleNonWinners_allDefeated() public {
        emit log('=== SHERLOCK #33: Multiple Non-Winners Test ===');

        // Create 3 proposals
        vm.prank(alice);
        uint256 proposal1 = governor.proposeBoost(address(tokenA), 100 ether);

        vm.prank(bob);
        uint256 proposal2 = governor.proposeBoost(address(tokenA), 200 ether);

        vm.prank(charlie);
        uint256 proposal3 = governor.proposeBoost(address(tokenA), 300 ether);

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 100);

        // Proposal 1: 67% approval (1000 yes, 500 no)
        vm.prank(alice);
        governor.vote(proposal1, true);
        vm.prank(bob);
        governor.vote(proposal1, false);

        // Proposal 2: 50% approval (1000 yes, 1000 no - needs more votes for quorum)
        vm.prank(alice);
        governor.vote(proposal2, true);
        vm.prank(bob);
        governor.vote(proposal2, false);
        vm.prank(charlie);
        governor.vote(proposal2, false);

        // Proposal 3: 100% approval (WINNER - all vote yes)
        vm.prank(alice);
        governor.vote(proposal3, true);
        vm.prank(bob);
        governor.vote(proposal3, true);
        vm.prank(charlie);
        governor.vote(proposal3, true);

        vm.warp(block.timestamp + 5 days);

        // Verify winner
        uint256 winnerId = governor.getWinner(governor.currentCycleId());
        assertEq(winnerId, proposal3, 'Proposal 3 should be winner (90% approval)');

        // Check states
        ILevrGovernor_v1.Proposal memory prop1 = governor.getProposal(proposal1);
        ILevrGovernor_v1.Proposal memory prop2 = governor.getProposal(proposal2);
        ILevrGovernor_v1.Proposal memory prop3 = governor.getProposal(proposal3);

        // Non-winners must be Defeated
        assertEq(
            uint8(prop1.state),
            uint8(ILevrGovernor_v1.ProposalState.Defeated),
            'Proposal 1 (non-winner) must be Defeated'
        );

        assertEq(
            uint8(prop2.state),
            uint8(ILevrGovernor_v1.ProposalState.Defeated),
            'Proposal 2 (non-winner) must be Defeated'
        );

        // Winner must be Succeeded
        assertEq(
            uint8(prop3.state),
            uint8(ILevrGovernor_v1.ProposalState.Succeeded),
            'Proposal 3 (winner) must be Succeeded'
        );

        emit log('[TEST RESULT] All non-winners correctly show as Defeated');
    }
}
