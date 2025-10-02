// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
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
  ERC2771Forwarder internal forwarder;
  LevrGovernor_v1 internal governor;
  LevrTreasury_v1 internal treasury;
  LevrStaking_v1 internal staking;
  LevrStakedToken_v1 internal sToken;

  address internal user = address(0xA11CE);
  address internal protocolTreasury = address(0xDEAD);

  function setUp() public {
    underlying = new MockERC20('Token', 'TKN');

    // Deploy forwarder first
    forwarder = new ERC2771Forwarder('LevrForwarder');

    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 3 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 100 ether,
      protocolTreasury: protocolTreasury
    });
    factory = new LevrFactory_v1(cfg, address(this), address(forwarder));
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

  function test_propose_and_execute_transfer() public {
    vm.startPrank(user);
    uint256 pid = governor.proposeTransfer(address(0xB0B), 500 ether, 'ops');
    ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
    assertEq(uint8(p.proposalType), uint8(ILevrGovernor_v1.ProposalType.Transfer));
    vm.stopPrank();

    governor.execute(pid);
  }

  function test_proposeBoost_and_deadline_enforcement() public {
    vm.startPrank(user);
    uint256 pid = governor.proposeBoost(4_000 ether);
    vm.stopPrank();

    // move time forward but before deadline
    vm.warp(block.timestamp + 1 days);
    governor.execute(pid);

    // After deadline should revert
    vm.startPrank(user);
    uint256 pid2 = governor.proposeBoost(4_000 ether);
    vm.stopPrank();
    vm.warp(block.timestamp + 4 days);
    vm.expectRevert(ILevrGovernor_v1.DeadlinePassed.selector);
    governor.execute(pid2);
  }

  function test_rate_limit_per_week_enforced() public {
    // Create a new factory with maxSubmissionPerType = 1
    ERC2771Forwarder fwd = new ERC2771Forwarder('LevrForwarder');
    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 3 days,
      maxSubmissionPerType: 1,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 1,
      protocolTreasury: protocolTreasury
    });
    LevrFactory_v1 fac = new LevrFactory_v1(cfg, address(this), address(fwd));
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

    // First transfer proposal succeeds
    vm.prank(u);
    g.proposeTransfer(address(0xB0B), 1 ether, 'ops');

    // Second transfer proposal in same week should revert
    vm.prank(u);
    vm.expectRevert(ILevrGovernor_v1.RateLimitExceeded.selector);
    g.proposeTransfer(address(0xB0B), 1 ether, 'ops2');

    // Move to next week and it should succeed again
    vm.warp(block.timestamp + 8 days);
    vm.prank(u);
    g.proposeTransfer(address(0xB0B), 1 ether, 'ops3');
  }
}
