// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrFactoryV1_DryRunTest is Test {
  LevrFactory_v1 internal factory;
  MockERC20 internal token;
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
    token = new MockERC20('Test Token', 'TEST');
  }

  function test_registerDryRun_predicts_correct_addresses() public {
    // Call registerDryRun BEFORE actual registration
    (
      address predictedTreasury,
      address predictedGovernor,
      address predictedStaking,
      address predictedStakedToken
    ) = factory.registerDryRun(address(token));

    // Now actually register
    (address actualTreasury, address actualGovernor, address actualStaking, address actualStakedToken) = factory
      .register(address(token));

    // Verify predictions match actual deployments
    assertEq(predictedTreasury, actualTreasury, 'Treasury address mismatch');
    assertEq(predictedGovernor, actualGovernor, 'Governor address mismatch');
    assertEq(predictedStaking, actualStaking, 'Staking address mismatch');
    assertEq(predictedStakedToken, actualStakedToken, 'StakedToken address mismatch');
  }

  function test_registerDryRun_is_deterministic_over_time() public {
    // Call registerDryRun at different times
    (address pred1Treasury, address pred1Governor, address pred1Staking, address pred1StakedToken) = factory
      .registerDryRun(address(token));

    // Do some other transactions to change factory nonce
    MockERC20 dummy1 = new MockERC20('Dummy1', 'DUM1');
    MockERC20 dummy2 = new MockERC20('Dummy2', 'DUM2');
    dummy1; // silence warning
    dummy2; // silence warning

    // Call registerDryRun again - should get SAME addresses
    (address pred2Treasury, address pred2Governor, address pred2Staking, address pred2StakedToken) = factory
      .registerDryRun(address(token));

    // Predictions should be identical regardless of when called or nonce passed
    assertEq(pred1Treasury, pred2Treasury, 'Treasury predictions differ over time');
    assertEq(pred1Governor, pred2Governor, 'Governor predictions differ over time');
    assertEq(pred1Staking, pred2Staking, 'Staking predictions differ over time');
    assertEq(pred1StakedToken, pred2StakedToken, 'StakedToken predictions differ over time');
  }

  function test_registerDryRun_different_tokens_get_different_addresses() public {
    MockERC20 token2 = new MockERC20('Test Token 2', 'TEST2');

    (address pred1Treasury, address pred1Governor, address pred1Staking, address pred1StakedToken) = factory
      .registerDryRun(address(token));

    (address pred2Treasury, address pred2Governor, address pred2Staking, address pred2StakedToken) = factory
      .registerDryRun(address(token2));

    // Different tokens should get different addresses
    assertTrue(pred1Treasury != pred2Treasury, 'Same treasury for different tokens');
    assertTrue(pred1Governor != pred2Governor, 'Same governor for different tokens');
    assertTrue(pred1Staking != pred2Staking, 'Same staking for different tokens');
    assertTrue(pred1StakedToken != pred2StakedToken, 'Same stakedToken for different tokens');
  }
}
