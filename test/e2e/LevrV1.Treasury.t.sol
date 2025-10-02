// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrTreasury_v1} from '../../src/interfaces/ILevrTreasury_v1.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IClankerAirdrop} from '../../src/interfaces/external/IClankerAirdrop.sol';
import {MerkleAirdropHelper} from '../utils/MerkleAirdropHelper.sol';

contract LevrV1_TreasuryE2E is BaseForkTest {
  LevrFactory_v1 internal factory;
  ERC2771Forwarder internal forwarder;

  address internal protocolTreasury = address(0xFEE);
  address internal clankerToken;
  address internal clankerFactory; // set from constant
  address constant DEFAULT_CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;

  function setUp() public override {
    super.setUp();
    clankerFactory = DEFAULT_CLANKER_FACTORY;

    // Deploy forwarder first
    forwarder = new ERC2771Forwarder('LevrForwarder');

    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 7 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 0,
      protocolTreasury: protocolTreasury
    });
    factory = new LevrFactory_v1(cfg, address(this), address(forwarder));
  }

  function _deployRegisterAndGet(
    address fac
  ) internal returns (address governor, address treasury, address staking, address stakedToken) {
    ClankerDeployer d = new ClankerDeployer();
    clankerToken = d.deployFactoryStaticFull({
      clankerFactory: clankerFactory,
      tokenAdmin: address(this),
      name: 'CLK Test',
      symbol: 'CLK',
      clankerFeeBps: 100,
      pairedFeeBps: 100
    });

    ILevrFactory_v1.Project memory project = LevrFactory_v1(fac).register(clankerToken);
    treasury = project.treasury;
    governor = project.governor;
    staking = project.staking;
    stakedToken = project.stakedToken;
  }

  function _acquireFromLocker(address to, uint256 desired) internal returns (uint256 acquired) {
    address locker = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
    uint256 lockerBalance = IERC20(clankerToken).balanceOf(locker);
    if (lockerBalance == 0) return 0;
    acquired = desired <= lockerBalance ? desired : lockerBalance;
    vm.prank(locker);
    IERC20(clankerToken).transfer(to, acquired);
  }

  function test_user_stake_boost_claim_unstake_flow() public {
    // Use default factory config from setUp()
    (address governor, address treasury, address staking, address stakedToken) = _deployRegisterAndGet(
      address(factory)
    );

    // Get some underlying to the user from locker and split between stake and treasury funding
    uint256 userGot = _acquireFromLocker(address(this), 1_000 ether);
    assertTrue(userGot > 0, 'need some tokens to stake');
    uint256 stakeAmt = userGot / 2;
    uint256 boostAmt = userGot - stakeAmt;

    // Stake half
    IERC20(clankerToken).approve(staking, stakeAmt);
    ILevrStaking_v1(staking).stake(stakeAmt);
    assertEq(ILevrStaking_v1(staking).stakedBalanceOf(address(this)), stakeAmt);

    // Fund treasury with the rest
    IERC20(clankerToken).transfer(treasury, boostAmt);

    // Boost via governor using treasury funds
    uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt);
    ILevrGovernor_v1(governor).execute(pid);

    // Let some time pass and claim; with streaming, claim ~ boostAmt * elapsed/window
    vm.warp(block.timestamp + 1 hours);
    address[] memory toks = new address[](1);
    toks[0] = clankerToken;
    uint256 balBefore = IERC20(clankerToken).balanceOf(address(this));
    ILevrStaking_v1(staking).claimRewards(toks, address(this));
    uint256 balAfter = IERC20(clankerToken).balanceOf(address(this));
    uint256 claimed = balAfter - balBefore;
    assertApproxEqRel(claimed, (boostAmt * 1 hours) / (3 days), 3e16);

    // Unstake
    uint256 stakeBal = ILevrStaking_v1(staking).stakedBalanceOf(address(this));
    ILevrStaking_v1(staking).unstake(stakeBal, address(this));
    assertEq(ILevrStaking_v1(staking).stakedBalanceOf(address(this)), 0);
    // Staked token total supply should drop to zero
    assertEq(IERC20(stakedToken).totalSupply(), 0);
  }

  function test_only_tokenAdmin_can_register() public {
    // Deploy a Clanker token with this contract as tokenAdmin
    ClankerDeployer d = new ClankerDeployer();
    address sharedClankerToken = d.deployFactoryStaticFull({
      clankerFactory: clankerFactory,
      tokenAdmin: address(this),
      name: 'Shared Token',
      symbol: 'SHR',
      clankerFeeBps: 100,
      pairedFeeBps: 100
    });

    // Bob tries to register the token but he's not the tokenAdmin - should fail
    address bob = address(0x2222);
    vm.prank(bob);
    vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
    factory.register(sharedClankerToken);

    // Only the tokenAdmin (this contract) can successfully register
    ILevrFactory_v1.Project memory project = factory.register(sharedClankerToken);

    // Verify registration succeeded
    ILevrFactory_v1.Project memory registered = factory.getProjectContracts(sharedClankerToken);
    assertEq(registered.governor, project.governor);
  }

  function test_apy_views_work_correctly() public {
    // Deploy and register project
    (address governor, address treasury, address staking, address stakedToken) = _deployRegisterAndGet(
      address(factory)
    );

    // Get tokens for staking and boosting
    uint256 userGot = _acquireFromLocker(address(this), 10_000 ether);
    assertTrue(userGot > 0, 'need tokens from locker');

    // Stake 50% of tokens
    uint256 stakeAmt = userGot / 2;
    IERC20(clankerToken).approve(staking, stakeAmt);
    ILevrStaking_v1(staking).stake(stakeAmt);

    // Verify initial state: no rewards accrued yet
    uint256 initialApr = ILevrStaking_v1(staking).aprBps(address(this));
    uint256 initialRate = ILevrStaking_v1(staking).rewardRatePerSecond(clankerToken);
    assertEq(initialApr, 0, 'initial APR should be 0');
    assertEq(initialRate, 0, 'initial reward rate should be 0');

    // Fund treasury and execute boost
    uint256 boostAmt = userGot - stakeAmt;
    IERC20(clankerToken).transfer(treasury, boostAmt);
    uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt);
    ILevrGovernor_v1(governor).execute(pid);

    // Now check APR and reward rate calculations
    uint256 aprAfterBoost = ILevrStaking_v1(staking).aprBps(address(this));
    uint256 rateAfterBoost = ILevrStaking_v1(staking).rewardRatePerSecond(clankerToken);

    // APR calculation: (boostAmt * 365 days / 3 days) * 10000 / stakeAmt
    // rate = boostAmt / 3 days
    uint256 expectedRate = boostAmt / 3 days;
    uint256 expectedAnnual = expectedRate * 365 days;
    uint256 expectedAprBps = (expectedAnnual * 10_000) / stakeAmt;

    assertApproxEqRel(aprAfterBoost, expectedAprBps, 1e16, 'APR should match calculation'); // 1% tolerance
    assertApproxEqRel(rateAfterBoost, expectedRate, 1e16, 'reward rate should match calculation');

    // Let some time pass and check rate doesn't change (linear emission)
    vm.warp(block.timestamp + 1 hours);
    uint256 rateAfterTime = ILevrStaking_v1(staking).rewardRatePerSecond(clankerToken);
    assertEq(rateAfterTime, rateAfterBoost, 'rate should not change during stream');

    // APR should remain the same (annualized)
    uint256 aprAfterTime = ILevrStaking_v1(staking).aprBps(address(this));
    assertEq(aprAfterTime, aprAfterBoost, 'APR should not change during stream');

    // Claim some rewards and verify APR still works
    vm.warp(block.timestamp + 1 days);
    address[] memory toks = new address[](1);
    toks[0] = clankerToken;
    ILevrStaking_v1(staking).claimRewards(toks, address(this));

    uint256 aprAfterClaim = ILevrStaking_v1(staking).aprBps(address(this));
    assertEq(aprAfterClaim, aprAfterBoost, 'APR should remain same after claim');

    // Test edge case: unstake all, APR should become 0
    ILevrStaking_v1(staking).unstake(stakeAmt, address(this));
    uint256 aprAfterUnstake = ILevrStaking_v1(staking).aprBps(address(this));
    assertEq(aprAfterUnstake, 0, 'APR should be 0 when no tokens staked');

    // Rate should still exist (stream continues)
    uint256 rateAfterUnstake = ILevrStaking_v1(staking).rewardRatePerSecond(clankerToken);
    assertEq(rateAfterUnstake, expectedRate, 'rate should continue after unstake');
  }
}
