// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrGovernorV1_UnitTest is Test {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    address internal user = address(0xA11CE);
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        // Deploy forwarder first
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100
        });
        factory = new LevrFactory_v1(
            cfg,
            address(this),
            address(forwarder),
            0xE85A59c628F7d27878ACeB4bf3b35733630083a9
        ); // Base Clanker factory
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
        // Create a new factory with maxSubmissionPerType = 1
        LevrForwarder_v1 fwd = new LevrForwarder_v1('LevrForwarder_v1');
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 1, // Testing with maxActiveProposals = 1
            quorumBps: 0, // No quorum requirement for this unit test
            approvalBps: 0, // No approval requirement for this unit test
            minSTokenBpsToSubmit: 0 // No minimum for this test
        });
        LevrFactory_v1 fac = new LevrFactory_v1(
            cfg,
            address(this),
            address(fwd),
            0xE85A59c628F7d27878ACeB4bf3b35733630083a9
        ); // Base Clanker factory
        ILevrFactory_v1.Project memory proj = fac.register(address(underlying));
        LevrGovernor_v1 g = LevrGovernor_v1(proj.governor);

        // fund user tokens and stake 1 wei to satisfy minWTokenToSubmit
        address u = address(0x1111);
        underlying.mint(u, 10 ether);
        vm.startPrank(u);
        underlying.approve(proj.staking, type(uint256).max);
        LevrStaking_v1(proj.staking).stake(1);
        vm.stopPrank();

        // fund treasury for transfers
        underlying.mint(proj.treasury, 10_000 ether);

        // Wait for VP to accumulate
        vm.warp(block.timestamp + 1 days);

        // Start governance cycle
        g.startNewCycle();

        // First transfer proposal succeeds
        vm.prank(u);
        g.proposeTransfer(address(0xB0B), 1 ether, 'ops');

        // Second transfer proposal should revert (maxActiveProposals = 1)
        vm.prank(u);
        vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
        g.proposeTransfer(address(0xB0B), 1 ether, 'ops2');

        // Vote on first proposal to make it winner
        vm.warp(block.timestamp + 2 days + 1); // In voting window
        vm.prank(u);
        g.vote(1, true);

        // Execute first proposal to free up the slot (quorum/approval = 0 for this test)
        vm.warp(block.timestamp + 5 days + 1); // Past voting window
        g.execute(1);

        // Start new cycle
        g.startNewCycle();

        // Now new proposal should succeed
        vm.prank(u);
        g.proposeTransfer(address(0xB0B), 1 ether, 'ops3');
    }
}
