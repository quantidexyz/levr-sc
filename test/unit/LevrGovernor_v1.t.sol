// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrGovernor_v1_Test is Test, LevrFactoryDeployHelper {
    uint256 internal constant TREASURY_BUFFER = 100_000 ether;

    MockERC20 internal _underlying;
    LevrFactory_v1 internal _factory;
    LevrForwarder_v1 internal _forwarder;
    LevrDeployer_v1 internal _deployer;
    LevrGovernor_v1 internal _governor;
    LevrStaking_v1 internal _staking;
    LevrTreasury_v1 internal _treasury;
    LevrStakedToken_v1 internal _stakedToken;

    address internal _protocolTreasury = address(0xDEAD);
    address internal _alice = makeAddr('alice');
    address internal _bob = makeAddr('bob');
    address internal _carol = makeAddr('carol');

    uint32 internal _proposalWindow;
    uint32 internal _votingWindow;

    function setUp() public {
        _underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(_protocolTreasury);
        _proposalWindow = cfg.proposalWindowSeconds;
        _votingWindow = cfg.votingWindowSeconds;

        (_factory, _forwarder, _deployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        registerTokenWithMockClanker(address(_underlying));

        _factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = _factory.register(address(_underlying));

        _governor = LevrGovernor_v1(project.governor);
        _staking = LevrStaking_v1(project.staking);
        _treasury = LevrTreasury_v1(payable(project.treasury));
        _stakedToken = LevrStakedToken_v1(project.stakedToken);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Helper Functions

    function _fundTreasury(uint256 amount) internal {
        _underlying.mint(address(_treasury), amount);
    }

    function _fundAndStake(address user, uint256 amount) internal {
        _underlying.mint(user, amount);
        vm.startPrank(user);
        _underlying.approve(address(_staking), amount);
        _staking.stake(amount);
        vm.stopPrank();

        // Advance block & time so voting is allowed
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _advanceToVoting() internal {
        vm.warp(block.timestamp + _proposalWindow + 1);
    }

    function _advanceToExecution() internal {
        vm.warp(block.timestamp + _votingWindow + 1);
    }

    function _createBoostProposal(
        address proposer,
        uint256 stakeAmount,
        uint256 treasuryAmount,
        uint256 boostAmount
    ) internal returns (uint256 proposalId) {
        _fundTreasury(treasuryAmount);
        _fundAndStake(proposer, stakeAmount);

        vm.prank(proposer);
        proposalId = _governor.proposeBoost(address(_underlying), boostAmount);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Initialization

    /* Test: constructor */
    function test_Constructor_RevertIf_FactoryZero() public {
        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        new LevrGovernor_v1(address(0), address(_forwarder));
    }

    /* Test: initialize */
    function test_Initialize_RevertIf_NotFactory() public {
        LevrGovernor_v1 governor = new LevrGovernor_v1(address(_factory), address(_forwarder));
        vm.expectRevert(ILevrGovernor_v1.OnlyFactory.selector);
        governor.initialize(address(_treasury), address(_staking), address(_stakedToken), address(_underlying));
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.prank(address(_factory));
        vm.expectRevert(ILevrGovernor_v1.AlreadyInitialized.selector);
        _governor.initialize(address(_treasury), address(_staking), address(_stakedToken), address(_underlying));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test External Functions

    // ========================================================================
    // External - Proposal Submission

    /* Test: proposeBoost */
    function test_ProposeBoost_RevertIf_TokenZero() public {
        _fundTreasury(TREASURY_BUFFER);
        _fundAndStake(_alice, 100 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        _governor.proposeBoost(address(0), 1 ether);
    }

    function test_ProposeBoost_RevertIf_AmountZero() public {
        _fundTreasury(TREASURY_BUFFER);
        _fundAndStake(_alice, 100 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrGovernor_v1.InvalidAmount.selector);
        _governor.proposeBoost(address(_underlying), 0);
    }

    function test_ProposeBoost_RevertIf_InsufficientStake() public {
        _fundTreasury(TREASURY_BUFFER);
        _fundAndStake(_alice, 10_000 ether);

        vm.prank(_bob);
        vm.expectRevert(ILevrGovernor_v1.InsufficientStake.selector);
        _governor.proposeBoost(address(_underlying), 1_000 ether);
    }

    function test_ProposeBoost_SuccessCreatesProposal() public {
        uint256 proposalId = _createBoostProposal(_alice, 1_000 ether, TREASURY_BUFFER, 500 ether);
        assertEq(proposalId, 1, 'first proposal id should be 1');

        ILevrGovernor_v1.Proposal memory proposal = _governor.getProposal(proposalId);
        assertEq(uint256(proposal.proposalType), uint256(ILevrGovernor_v1.ProposalType.BoostStakingPool));
        assertEq(proposal.token, address(_underlying));
        assertEq(proposal.amount, 500 ether);
        assertEq(proposal.proposer, _alice);
    }

    /* Test: proposeTransfer */
    function test_ProposeTransfer_RevertIf_RecipientZero() public {
        _fundTreasury(TREASURY_BUFFER);
        _fundAndStake(_alice, 1_000 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        _governor.proposeTransfer(address(_underlying), address(0), 100 ether, 'invalid');
    }

    function test_ProposeTransfer_RevertIf_TreasuryInsufficient() public {
        _fundAndStake(_alice, 1_000 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        _governor.proposeTransfer(address(_underlying), _bob, 1 ether, 'empty');
    }

    // ========================================================================
    // External - Voting

    /* Test: vote */
    function test_Vote_RevertIf_VotingNotActive() public {
        uint256 proposalId = _createBoostProposal(_alice, 1_000 ether, TREASURY_BUFFER, 500 ether);
        _fundAndStake(_bob, 1_000 ether);

        vm.prank(_bob);
        vm.expectRevert(ILevrGovernor_v1.VotingNotActive.selector);
        _governor.vote(proposalId, true);
    }

    function test_Vote_RevertIf_StakeActionTooRecent() public {
        uint256 proposalId = _createBoostProposal(_alice, 1_000 ether, TREASURY_BUFFER, 500 ether);
        _fundAndStake(_bob, 1_000 ether);
        _advanceToVoting();

        vm.startPrank(_bob);
        // simulate immediate stake by staking again right before voting
        _underlying.mint(_bob, 1 ether);
        _underlying.approve(address(_staking), 1 ether);
        _staking.stake(1 ether);
        vm.expectRevert(ILevrGovernor_v1.StakeActionTooRecent.selector);
        _governor.vote(proposalId, true);
        vm.stopPrank();
    }

    function test_Vote_SuccessRecordsReceipt() public {
        uint256 proposalId = _createBoostProposal(_alice, 2_000 ether, TREASURY_BUFFER, 500 ether);
        _fundAndStake(_bob, 2_000 ether);
        _advanceToVoting();

        vm.prank(_bob);
        _governor.vote(proposalId, true);

        ILevrGovernor_v1.Proposal memory updated = _governor.getProposal(proposalId);
        assertGt(updated.yesVotes, 0, 'yes votes recorded');
        assertEq(updated.noVotes, 0, 'no votes untouched');
        assertGt(updated.totalBalanceVoted, 0, 'quorum balance recorded');
    }

    // ========================================================================
    // External - Execution

    /* Test: execute */
    function test_Execute_RevertIf_VotingNotEnded() public {
        uint256 proposalId = _createBoostProposal(_alice, 1_000 ether, TREASURY_BUFFER, 500 ether);
        _fundAndStake(_bob, 1_000 ether);
        _advanceToVoting();

        vm.prank(_bob);
        _governor.vote(proposalId, true);

        vm.expectRevert(ILevrGovernor_v1.VotingNotEnded.selector);
        _governor.execute(proposalId);
    }

    function test_Execute_DefeatsWhenNoQuorum() public {
        uint256 proposalId = _createBoostProposal(_alice, 1_000 ether, TREASURY_BUFFER, 500 ether);
        _advanceToVoting();
        _advanceToExecution();

        vm.expectEmit(true, true, false, true);
        emit ILevrGovernor_v1.ProposalDefeated(proposalId);
        _governor.execute(proposalId);

        ILevrGovernor_v1.Proposal memory proposal = _governor.getProposal(proposalId);
        assertTrue(proposal.executed, 'proposal marked executed');
    }

    function test_Execute_SuccessTransfersFunds() public {
        uint256 proposalId = _createBoostProposal(_alice, 2_000 ether, TREASURY_BUFFER, 1_000 ether);
        _fundAndStake(_bob, 2_000 ether);
        _advanceToVoting();

        vm.prank(_alice);
        _governor.vote(proposalId, true);
        vm.prank(_bob);
        _governor.vote(proposalId, true);

        _advanceToExecution();

        uint256 stakingBalanceBefore = _underlying.balanceOf(address(_staking));
        _governor.execute(proposalId);
        uint256 stakingBalanceAfter = _underlying.balanceOf(address(_staking));

        assertEq(stakingBalanceAfter - stakingBalanceBefore, 1_000 ether, 'boost moved to staking');
    }

    // ========================================================================
    // External - Cycle Management

    /* Test: startNewCycle */
    function test_StartNewCycle_SucceedsAfterExecution() public {
        uint256 proposalId = _createBoostProposal(_alice, 2_000 ether, TREASURY_BUFFER, 500 ether);
        _fundAndStake(_bob, 2_000 ether);
        _advanceToVoting();
        vm.prank(_bob);
        _governor.vote(proposalId, true);
        _advanceToExecution();
        _governor.execute(proposalId);

        uint256 cycleBefore = _governor.currentCycleId();
        _governor.startNewCycle();
        assertEq(_governor.currentCycleId(), cycleBefore + 1, 'cycle advanced');
    }

    // ========================================================================
    // External - Views

    /* Test: state */
    function test_State_TransitionsAcrossLifecycle() public {
        uint256 proposalId = _createBoostProposal(_alice, 2_000 ether, TREASURY_BUFFER, 500 ether);
        assertEq(uint256(_governor.state(proposalId)), uint256(ILevrGovernor_v1.ProposalState.Pending));

        _advanceToVoting();
        assertEq(uint256(_governor.state(proposalId)), uint256(ILevrGovernor_v1.ProposalState.Active));

        _advanceToExecution();
        assertEq(uint256(_governor.state(proposalId)), uint256(ILevrGovernor_v1.ProposalState.Defeated));
    }

    function test_ViewHelpers_ReturnExpectedData() public {
        uint256 proposalId = _createBoostProposal(_alice, 2_000 ether, TREASURY_BUFFER, 500 ether);
        uint256 cycleId = _governor.currentCycleId();

        uint256[] memory cycleProposals = _governor.getProposalsForCycle(cycleId);
        assertEq(cycleProposals.length, 1);
        assertEq(cycleProposals[0], proposalId);

        assertEq(_governor.activeProposalCount(ILevrGovernor_v1.ProposalType.BoostStakingPool), 1);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Internal Functions

    // While internal functions are not directly exposed, their effects are validated
    // through the public APIs above (cycle creation, quorum/approval, winner selection).
}

