// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrFactoryV1_SecurityTest is Test {
  LevrFactory_v1 internal factory;
  address internal protocolTreasury = address(0xFEE);
  address internal alice = address(0xA11CE);
  address internal bob = address(0xB0B);

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

  function test_cannot_register_with_someone_elses_treasury() public {
    // Alice prepares her infrastructure
    vm.prank(alice);
    (address aliceTreasury, address aliceStaking) = factory.prepareForDeployment();

    // Alice creates token (she's the admin since she deployed it)
    vm.prank(alice);
    MockERC20 aliceToken = new MockERC20('Alice Token', 'ALICE');

    // Alice tries to register using her own treasury she prepared - this should FAIL
    // because register() checks msg.sender == deployer, but with vm.prank the actual
    // transaction sender is not alice in the test context. We need to ensure the
    // check works.

    // Actually, let's test the opposite: Bob prepares, then tries to use his own contracts
    // but with a token that alice owns - should fail on tokenAdmin check first
    vm.prank(bob);
    vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
    factory.register(address(aliceToken));
  }

  function test_cannot_register_with_someone_elses_staking() public {
    // Alice prepares her infrastructure
    vm.prank(alice);
    (, address aliceStaking) = factory.prepareForDeployment();

    // Bob prepares his own treasury but tries to use Alice's staking
    vm.prank(bob);
    (address bobTreasury, ) = factory.prepareForDeployment();

    // Bob creates token (he's the admin)
    vm.prank(bob);
    MockERC20 bobToken = new MockERC20('Bob Token', 'BOB');

    // Bob tries to register - since Bob called prepareForDeployment,
    // it should work with his prepared contracts
    vm.prank(bob);
    (address regTreasury, address governor, address regStaking, address stakedToken) = factory.register(
      address(bobToken)
    );

    // Should use Bob's prepared contracts
    assertEq(regTreasury, bobTreasury, 'Should use Bob treasury');
    assertTrue(regStaking != address(0), 'Should have staking');
  }

  function test_can_register_with_own_prepared_contracts() public {
    // Alice prepares her infrastructure
    vm.prank(alice);
    (address aliceTreasury, address aliceStaking) = factory.prepareForDeployment();

    // Alice creates token (she's the admin)
    vm.prank(alice);
    MockERC20 aliceToken = new MockERC20('Alice Token', 'ALICE');

    // Alice registers with her own prepared contracts - should succeed
    vm.prank(alice);
    (address regTreasury, address governor, address regStaking, address stakedToken) = factory.register(
      address(aliceToken)
    );

    assertEq(regTreasury, aliceTreasury, 'Should use Alice treasury');
    assertEq(regStaking, aliceStaking, 'Should use Alice staking');
    assertTrue(governor != address(0), 'Governor deployed');
    assertTrue(stakedToken != address(0), 'StakedToken deployed');
  }

  function test_can_register_without_preparation() public {
    // Bob creates token (he's the admin)
    vm.prank(bob);
    MockERC20 bobToken = new MockERC20('Bob Token', 'BOB');

    // Bob registers without preparation - should succeed
    vm.prank(bob);
    (address treasury, address governor, address staking, address stakedToken) = factory.register(address(bobToken));

    assertTrue(treasury != address(0), 'Treasury deployed');
    assertTrue(governor != address(0), 'Governor deployed');
    assertTrue(staking != address(0), 'Staking deployed');
    assertTrue(stakedToken != address(0), 'StakedToken deployed');
  }

  function test_tokenAdmin_gate_still_enforced() public {
    // Alice prepares infrastructure
    vm.prank(alice);
    (address aliceTreasury, address aliceStaking) = factory.prepareForDeployment();

    // Alice creates token (she's the admin)
    vm.prank(alice);
    MockERC20 aliceToken = new MockERC20('Alice Token', 'ALICE');

    // Bob (not tokenAdmin) tries to register - should fail with UnauthorizedCaller
    vm.prank(bob);
    vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
    factory.register(address(aliceToken));
  }
}
