// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Governance E2E tests using airdrop claim mechanism to fund treasury
/// @dev Flow:
///   1. prepareForDeployment() to get treasury address before token deployment
///   2. Deploy Clanker token with treasury in airdrop merkle tree
///   3. register() to complete Levr setup
///   4. Claim airdrop using IClankerAirdrop.claim() to fund treasury

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IClankerAirdrop} from '../../src/interfaces/external/IClankerAirdrop.sol';
import {MerkleAirdropHelper} from '../utils/MerkleAirdropHelper.sol';

contract LevrV1_GovernanceE2E is BaseForkTest {
  LevrFactory_v1 internal factory;
  LevrForwarder_v1 internal forwarder;

  address internal protocolTreasury = address(0xFEE);
  address internal clankerToken;
  address internal clankerFactory; // set from constant
  address constant DEFAULT_CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
  address constant AIRDROP_EXTENSION = 0xf652B3610D75D81871bf96DB50825d9af28391E0;

  function setUp() public override {
    super.setUp();
    clankerFactory = DEFAULT_CLANKER_FACTORY;

    // Deploy forwarder first
    forwarder = new LevrForwarder_v1('LevrForwarder_v1');

    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 7 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 0,
      protocolTreasury: protocolTreasury
    });
    factory = new LevrFactory_v1(cfg, address(this), address(forwarder), 0xE85A59c628F7d27878ACeB4bf3b35733630083a9); // Base Clanker factory
  }

  function _deployRegisterAndGet(
    address fac,
    uint256 airdropAmount
  ) internal returns (address governor, address treasury, address staking, address stakedToken) {
    // Step 1: Prepare infrastructure FIRST to get the treasury address
    (treasury, staking) = LevrFactory_v1(fac).prepareForDeployment();

    // Step 2: Create merkle root with the known treasury address
    bytes32 merkleRoot = MerkleAirdropHelper.singleLeafRoot(treasury, airdropAmount);

    // Encode airdrop extension data
    bytes memory airdropData = abi.encode(
      address(this), // admin
      merkleRoot,
      1 days, // lockupDuration (minimum)
      0 // vestingDuration (instant unlock after lockup)
    );

    // Step 3: Deploy Clanker token with treasury in the airdrop merkle tree
    ClankerDeployer d = new ClankerDeployer();
    clankerToken = d.deployFactoryStaticFullWithOptions({
      clankerFactory: clankerFactory,
      tokenAdmin: address(this),
      name: 'CLK Test',
      symbol: 'CLK',
      clankerFeeBps: 100,
      pairedFeeBps: 100,
      enableAirdrop: true,
      airdropAdmin: address(this),
      airdropBps: 1000, // 10% of supply to airdrop
      airdropData: airdropData,
      enableDevBuy: false,
      devBuyBps: 0,
      devBuyEthAmount: 0,
      devBuyRecipient: address(0)
    });

    // Step 4: Complete registration (will use the prepared treasury and staking)
    ILevrFactory_v1.Project memory project = LevrFactory_v1(fac).register(clankerToken);
    treasury = project.treasury;
    governor = project.governor;
    staking = project.staking;
    stakedToken = project.stakedToken;
  }

  function _claimAirdropForTreasury(address treasury, uint256 allocatedAmount) internal {
    // Wait for lockup period to pass
    vm.warp(block.timestamp + 1 days + 1);

    // Generate empty proof for single-leaf merkle tree
    bytes32[] memory proof = new bytes32[](0);

    // Claim the airdrop directly to the treasury
    IClankerAirdrop(AIRDROP_EXTENSION).claim(clankerToken, treasury, allocatedAmount, proof);
  }

  function _acquireFromLocker(address to, uint256 desired) internal returns (uint256 acquired) {
    address locker = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
    uint256 lockerBalance = IERC20(clankerToken).balanceOf(locker);
    if (lockerBalance == 0) return 0;
    acquired = desired <= lockerBalance ? desired : lockerBalance;
    vm.prank(locker);
    IERC20(clankerToken).transfer(to, acquired);
  }

  function test_transfer_proposal_and_tier_validation() public {
    uint256 airdropAmount = 1_000 ether;

    // Deploy and register with airdrop (treasury address is included in merkle tree via prepareForDeployment)
    (address governor, address treasury, , ) = _deployRegisterAndGet(address(factory), airdropAmount);

    // Claim the airdrop directly to the treasury using the IClankerAirdrop.claim function
    _claimAirdropForTreasury(treasury, airdropAmount);

    // Verify treasury has funds from airdrop claim
    uint256 treasBal = IERC20(clankerToken).balanceOf(treasury);
    assertTrue(treasBal > 0, 'treasury should have funds from airdrop');
    assertEq(treasBal, airdropAmount, 'treasury should have exactly airdrop amount');

    // Valid transfer (custom amount, no tiers)
    address receiver = address(0xBEEF);
    uint256 recvBefore = IERC20(clankerToken).balanceOf(receiver);
    uint256 amount = treasBal / 2; // Transfer half
    uint256 pid = ILevrGovernor_v1(governor).proposeTransfer(receiver, amount, 'ops');
    ILevrGovernor_v1(governor).execute(pid);
    uint256 recvAfter = IERC20(clankerToken).balanceOf(receiver);
    assertEq(recvAfter - recvBefore, amount);
  }

  function test_min_balance_gating_and_deadline_enforcement() public {
    // Create stricter config
    LevrForwarder_v1 fwd = new LevrForwarder_v1('LevrForwarder_v1');
    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 1 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 1,
      protocolTreasury: protocolTreasury
    });
    LevrFactory_v1 strictFactory = new LevrFactory_v1(
      cfg,
      address(this),
      address(fwd),
      0xE85A59c628F7d27878ACeB4bf3b35733630083a9
    ); // Base Clanker factory

    uint256 treasuryAirdropAmount = 1_000 ether;

    // Deploy and register with airdrop (treasury address is included in merkle tree via prepareForDeployment)
    (address governor, address treasury, address staking, ) = _deployRegisterAndGet(
      address(strictFactory),
      treasuryAirdropAmount
    );

    // Without stake, proposing should revert
    vm.expectRevert(ILevrGovernor_v1.NotAuthorized.selector);
    ILevrGovernor_v1(governor).proposeBoost(100 ether);

    // Get tokens for user from locker (for staking purposes)
    uint256 userGot = _acquireFromLocker(address(this), 1_000 ether);
    assertTrue(userGot > 0, 'need tokens from locker');
    uint256 stakeAmt = userGot / 2;
    IERC20(clankerToken).approve(staking, stakeAmt);
    ILevrStaking_v1(staking).stake(stakeAmt);

    // Claim airdrop directly to the treasury using IClankerAirdrop.claim
    _claimAirdropForTreasury(treasury, treasuryAirdropAmount);

    uint256 tBal = IERC20(clankerToken).balanceOf(treasury);
    assertTrue(tBal > 0, 'treasury should have funds from airdrop');
    uint256 boostAmt = tBal / 2;
    uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt);

    // After deadline passes, execute should revert
    vm.warp(block.timestamp + 2 days);
    vm.expectRevert(ILevrGovernor_v1.DeadlinePassed.selector);
    ILevrGovernor_v1(governor).execute(pid);
  }
}
