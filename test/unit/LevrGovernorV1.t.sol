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

contract LevrGovernorV1_UnitTest is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    address internal user = address(0xA11CE);
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        // Prepare infrastructure before registering
        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        // fund user and stake to reach min balance
        underlying.mint(user, 1_000 ether);
        vm.startPrank(user);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(200 ether);
        vm.stopPrank();

        // fund treasury for transfer proposals
        underlying.mint(address(treasury), 10_000 ether);
    }

    // Legacy tests removed - new governance model uses cycle-based proposals
    // All governance coverage is in test/e2e/LevrV1.Governance.t.sol

    function test_rate_limit_per_type_enforced() public {
        // Create a new factory with maxActiveProposals = 1
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 1, // Testing with maxActiveProposals = 1
            quorumBps: 0, // No quorum requirement for this unit test
            approvalBps: 0, // No approval requirement for this unit test
            minSTokenBpsToSubmit: 0, // No minimum for this test
            maxProposalAmountBps: 500 // 5% max
        });
        (LevrFactory_v1 fac, LevrForwarder_v1 fwd, ) = deployFactoryWithDefaultClanker(
            cfg,
            address(this)
        );

        // Prepare infrastructure before registering
        fac.prepareForDeployment();

        ILevrFactory_v1.Project memory proj = fac.register(address(underlying));
        LevrGovernor_v1 g = LevrGovernor_v1(proj.governor);

        // fund user tokens and stake enough to get meaningful VP with token-days normalization
        address u = address(0x1111);
        underlying.mint(u, 10 ether);
        vm.startPrank(u);
        underlying.approve(proj.staking, type(uint256).max);
        LevrStaking_v1(proj.staking).stake(1 ether); // Stake 1 token instead of 1 wei
        vm.stopPrank();

        // fund treasury for transfers
        underlying.mint(proj.treasury, 10_000 ether);

        // Wait for VP to accumulate (with normalization, need time to get non-zero VP)
        vm.warp(block.timestamp + 10 days);

        // First transfer proposal succeeds (auto-starts cycle)
        vm.prank(u);
        g.proposeTransfer(address(underlying), address(0xB0B), 1 ether, 'ops');

        // Second transfer proposal should revert (maxActiveProposals = 1)
        vm.prank(u);
        vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
        g.proposeTransfer(address(underlying), address(0xB0B), 1 ether, 'ops2');

        // Vote on first proposal to make it winner
        vm.warp(block.timestamp + 2 days + 1); // In voting window
        vm.prank(u);
        g.vote(1, true);

        // Execute first proposal to free up the slot (quorum/approval = 0 for this test)
        // Execution auto-starts new cycle
        vm.warp(block.timestamp + 5 days + 1); // Past voting window
        g.execute(1);

        // Now new proposal should succeed in the new auto-started cycle
        vm.prank(u);
        g.proposeTransfer(address(underlying), address(0xB0B), 1 ether, 'ops3');
    }

    function test_getProposal_returns_computed_fields() public {
        // Create a proposal
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        // Get proposal in pending state
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertEq(
            uint256(proposal.state),
            uint256(ILevrGovernor_v1.ProposalState.Pending),
            'Should be Pending'
        );
        assertFalse(proposal.meetsQuorum, 'Should not meet quorum yet');
        assertFalse(proposal.meetsApproval, 'Should not meet approval yet');

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Get proposal in active state
        proposal = governor.getProposal(pid);
        assertEq(
            uint256(proposal.state),
            uint256(ILevrGovernor_v1.ProposalState.Active),
            'Should be Active'
        );
        assertFalse(proposal.meetsQuorum, 'Should not meet quorum without votes');
        assertFalse(proposal.meetsApproval, 'Should not meet approval without votes');

        // Vote
        vm.prank(user);
        governor.vote(pid, true);

        // Get proposal with vote
        proposal = governor.getProposal(pid);
        assertEq(
            uint256(proposal.state),
            uint256(ILevrGovernor_v1.ProposalState.Active),
            'Should still be Active'
        );
        // With quorum/approval at 0 in test config, both should be true
        assertTrue(proposal.meetsQuorum, 'Should meet quorum (0% threshold)');
        assertTrue(proposal.meetsApproval, 'Should meet approval (0% threshold)');

        // Warp past voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Get proposal in succeeded state
        proposal = governor.getProposal(pid);
        assertEq(
            uint256(proposal.state),
            uint256(ILevrGovernor_v1.ProposalState.Succeeded),
            'Should be Succeeded'
        );
        assertTrue(proposal.meetsQuorum, 'Should meet quorum');
        assertTrue(proposal.meetsApproval, 'Should meet approval');

        // Execute proposal
        governor.execute(pid);

        // Get proposal in executed state
        proposal = governor.getProposal(pid);
        assertEq(
            uint256(proposal.state),
            uint256(ILevrGovernor_v1.ProposalState.Executed),
            'Should be Executed'
        );
        assertTrue(proposal.executed, 'Should be marked as executed');
    }

    function test_getProposal_invalid_proposalId_reverts() public {
        // Try to get a non-existent proposal (should revert)
        vm.expectRevert(ILevrGovernor_v1.InvalidProposalType.selector);
        governor.getProposal(999);

        vm.expectRevert(ILevrGovernor_v1.InvalidProposalType.selector);
        governor.getProposal(0);
    }

    function test_getProposal_defeated_proposal_state() public {
        // Create a factory with high quorum that can't be met
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000, // 70% quorum
            approvalBps: 5100,
            minSTokenBpsToSubmit: 0,
            maxProposalAmountBps: 500
        });
        (LevrFactory_v1 fac, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        fac.prepareForDeployment();
        ILevrFactory_v1.Project memory proj = fac.register(address(underlying));
        LevrGovernor_v1 g = LevrGovernor_v1(proj.governor);

        // Fund treasury with enough tokens to support proposals
        // maxProposalAmountBps = 500 (5%), so to allow 100 ether proposals, need 2000 ether in treasury
        underlying.mint(proj.treasury, 2000 ether);

        // Create multiple stakers so one person can't meet quorum alone
        address alice = address(0x1111);
        address bob = address(0x2222);

        // Alice stakes 40% of supply
        underlying.mint(alice, 4 ether);
        vm.startPrank(alice);
        underlying.approve(proj.staking, type(uint256).max);
        LevrStaking_v1(proj.staking).stake(4 ether);
        vm.stopPrank();

        // Bob stakes 60% of supply (now 10 ether total)
        underlying.mint(bob, 6 ether);
        vm.startPrank(bob);
        underlying.approve(proj.staking, type(uint256).max);
        LevrStaking_v1(proj.staking).stake(6 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = g.proposeBoost(address(underlying), 100 ether);

        // Only Alice votes (40% participation < 70% quorum)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        g.vote(pid, true);

        // Warp past voting
        vm.warp(block.timestamp + 5 days + 1);

        // Get proposal - should be Defeated due to insufficient quorum
        ILevrGovernor_v1.Proposal memory proposal = g.getProposal(pid);
        assertEq(
            uint256(proposal.state),
            uint256(ILevrGovernor_v1.ProposalState.Defeated),
            'Should be Defeated'
        );
        assertFalse(proposal.meetsQuorum, 'Should not meet quorum (40% < 70%)');
        assertTrue(proposal.meetsApproval, 'Should meet approval (100% yes votes)');
    }
}
