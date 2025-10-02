// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
contract LevrFactoryV1_PrepareForDeploymentTest is Test {
  LevrFactory_v1 internal factory;
  address internal protocolTreasury = address(0xFEE);

  function setUp() public {
    ILevrFactory_v1.TierConfig[] memory transferTiers = new ILevrFactory_v1.TierConfig[](3);
    transferTiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
    transferTiers[1] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
    transferTiers[2] = ILevrFactory_v1.TierConfig({value: 100_000 ether});

    ILevrFactory_v1.TierConfig[] memory boostTiers = new ILevrFactory_v1.TierConfig[](3);
    boostTiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
    boostTiers[1] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
    boostTiers[2] = ILevrFactory_v1.TierConfig({value: 100_000 ether});

    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 0,
      submissionDeadlineSeconds: 7 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      transferTiers: transferTiers,
      stakingBoostTiers: boostTiers,
      minWTokenToSubmit: 0,
      protocolTreasury: protocolTreasury
    });
    factory = new LevrFactory_v1(cfg, address(this));
  }

  function test_prepareForDeployment_deploys_treasury_and_staking() public {
    // Step 1: Prepare infrastructure BEFORE deploying Clanker token
    (address treasury, address staking) = factory.prepareForDeployment();

    // Verify contracts are deployed
    assertTrue(treasury != address(0), 'Treasury should be deployed');
    assertTrue(staking != address(0), 'Staking should be deployed');

    // Step 2: Now you would deploy Clanker token with:
    // - treasury as airdrop recipient
    // - staking as LP fee recipient
    MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');

    // Step 3: Complete registration with the prepared contracts
    (address regTreasury, address governor, address regStaking, address stakedToken) = factory.register(
      address(clankerToken)
    );

    // Verify same addresses are used
    assertEq(regTreasury, treasury, 'Should use prepared treasury');
    assertEq(regStaking, staking, 'Should use prepared staking');
    assertTrue(governor != address(0), 'Governor should be deployed');
    assertTrue(stakedToken != address(0), 'StakedToken should be deployed');

    // Verify treasury is controlled by governor (not ownable anymore)
    assertEq(LevrTreasury_v1(payable(treasury)).governor(), governor, 'Treasury controlled by governor');
  }

  function test_prepareForDeployment_multiple_times_creates_different_addresses() public {
    // Call prepareForDeployment multiple times
    (address treasury1, address staking1) = factory.prepareForDeployment();

    // Warp time to ensure different timestamp
    vm.warp(block.timestamp + 1);

    (address treasury2, address staking2) = factory.prepareForDeployment();

    // Different deployments should get different addresses
    assertTrue(treasury1 != treasury2, 'Different treasuries for different preparations');
    assertTrue(staking1 != staking2, 'Different staking for different preparations');
  }

  function test_register_works_without_preparation() public {
    // Register directly without prepareForDeployment
    MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');

    (address treasury, address governor, address staking, address stakedToken) = factory.register(
      address(clankerToken)
    );

    // Should deploy new contracts
    assertTrue(treasury != address(0), 'Treasury should be deployed');
    assertTrue(governor != address(0), 'Governor should be deployed');
    assertTrue(staking != address(0), 'Staking should be deployed');
    assertTrue(stakedToken != address(0), 'StakedToken should be deployed');
  }

  function test_typical_workflow_with_preparation() public {
    // WORKFLOW DEMONSTRATION:
    // This shows the typical flow for deploying a Levr project with Clanker integration

    // Step 1: Prepare infrastructure FIRST (before Clanker token exists)
    (address treasury, address staking) = factory.prepareForDeployment();

    emit log_named_address('Treasury (use as Clanker airdrop recipient)', treasury);
    emit log_named_address('Staking (use as Clanker LP fee recipient)', staking);

    // Step 2: Deploy Clanker token (in real scenario, using Clanker SDK/contracts)
    // - Set `treasury` as airdrop recipient → treasury receives initial allocation
    // - Set `staking` as LP fee recipient → staking receives ongoing trading fees
    MockERC20 clankerToken = new MockERC20('Clanker Token', 'CLANK');

    emit log_named_address('Clanker Token deployed', address(clankerToken));

    // Step 3: Complete registration with prepared contracts
    vm.prank(address(this)); // tokenAdmin for MockERC20 is address(this)
    (address finalTreasury, address governor, address finalStaking, address stakedToken) = factory.register(
      address(clankerToken)
    );

    emit log_named_address('Governor deployed', governor);
    emit log_named_address('StakedToken deployed', stakedToken);

    // Verify the system is fully integrated
    assertEq(finalTreasury, treasury, 'Treasury address matches');
    assertEq(finalStaking, staking, 'Staking address matches');

    (address projTreasury, address projGovernor, address projStaking, address projStakedToken) = factory
      .getProjectContracts(address(clankerToken));

    assertEq(projTreasury, treasury, 'Project treasury registered');
    assertEq(projGovernor, governor, 'Project governor registered');
    assertEq(projStaking, staking, 'Project staking registered');
    assertEq(projStakedToken, stakedToken, 'Project stakedToken registered');
  }
}
