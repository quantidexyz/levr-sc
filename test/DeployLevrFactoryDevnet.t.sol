// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';

/**
 * @title DeployLevrFactoryDevnet Test
 * @notice Unit test for the devnet deployment script logic
 */
contract DeployLevrFactoryDevnetTest is Test {
  function test_DevnetConfig() public {
    // Deploy forwarder first (matching deployment script)
    LevrForwarder_v1 forwarder = new LevrForwarder_v1('LevrForwarder_v1');

    // Test the same configuration values used in the deployment script
    uint16 protocolFeeBps = 50;
    uint32 submissionDeadlineSeconds = 604800;
    uint32 streamWindowSeconds = 2592000;
    uint16 maxSubmissionPerType = 10;
    uint256 minWTokenToSubmit = 100e18;
    address protocolTreasury = address(this);

    ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: protocolFeeBps,
      submissionDeadlineSeconds: submissionDeadlineSeconds,
      maxSubmissionPerType: maxSubmissionPerType,
      streamWindowSeconds: streamWindowSeconds,
      minWTokenToSubmit: minWTokenToSubmit,
      protocolTreasury: protocolTreasury
    });

    // Deploy factory with forwarder
    LevrFactory_v1 factory = new LevrFactory_v1(config, address(this), address(forwarder));

    // Verify configuration
    assertEq(factory.protocolFeeBps(), protocolFeeBps);
    assertEq(factory.submissionDeadlineSeconds(), submissionDeadlineSeconds);
    assertEq(factory.streamWindowSeconds(), streamWindowSeconds);
    assertEq(factory.maxSubmissionPerType(), maxSubmissionPerType);
    assertEq(factory.minWTokenToSubmit(), minWTokenToSubmit);
    assertEq(factory.protocolTreasury(), protocolTreasury);
  }
}
