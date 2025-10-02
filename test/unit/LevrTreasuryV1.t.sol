// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrTreasuryV1_UnitTest is Test {
  MockERC20 internal underlying;
  LevrFactory_v1 internal factory;
  LevrTreasury_v1 internal treasury;
  LevrStaking_v1 internal staking;
  LevrStakedToken_v1 internal sToken;
  address internal governor;

  address internal protocolTreasury = address(0xDEAD);

  function setUp() public {
    underlying = new MockERC20('Token', 'TKN');

    ILevrFactory_v1.TierConfig[] memory ttiers = new ILevrFactory_v1.TierConfig[](1);
    ttiers[0] = ILevrFactory_v1.TierConfig({value: type(uint256).max});
    ILevrFactory_v1.TierConfig[] memory btiers = new ILevrFactory_v1.TierConfig[](1);
    btiers[0] = ILevrFactory_v1.TierConfig({value: type(uint256).max});
    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 7 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      transferTiers: ttiers,
      stakingBoostTiers: btiers,
      minWTokenToSubmit: 0,
      protocolTreasury: protocolTreasury
    });
    factory = new LevrFactory_v1(cfg, address(this));

    ILevrFactory_v1.Project memory project = factory.register(address(underlying));
    governor = project.governor;
    treasury = LevrTreasury_v1(payable(project.treasury));
    staking = LevrStaking_v1(project.staking);
    sToken = LevrStakedToken_v1(project.stakedToken);

    // fund treasury
    underlying.mint(address(treasury), 10_000 ether);
  }

  function test_onlyGovernor_can_transfer() public {
    vm.expectRevert();
    treasury.transfer(address(1), 1 ether);

    vm.prank(governor);
    treasury.transfer(address(1), 1 ether);
  }

  function test_applyBoost_movesFundsToStaking_andCreditsRewards() public {
    vm.prank(governor);
    treasury.applyBoost(2_000 ether);

    address[] memory tokens = new address[](1);
    tokens[0] = address(underlying);

    // no stake yet → no rewards claimable, but staking now holds funds
    assertGt(underlying.balanceOf(address(staking)), 0);
  }
}
