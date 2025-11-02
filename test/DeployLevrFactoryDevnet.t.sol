// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';
import {LevrFactoryDeployHelper} from './utils/LevrFactoryDeployHelper.sol';

/**
 * @title DeployLevrFactoryDevnet Test
 * @notice Unit test for the devnet deployment script logic
 */
contract DeployLevrFactoryDevnetTest is Test, LevrFactoryDeployHelper {
    function test_DevnetConfig() public {
        // Test the same configuration values used in the deployment script
        uint16 protocolFeeBps = 50;
        uint32 streamWindowSeconds = 2592000;
        address protocolTreasury = address(this);

        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: protocolFeeBps,
            streamWindowSeconds: streamWindowSeconds,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        // Deploy factory with forwarder and deployer logic using helper
        (
            LevrFactory_v1 factory,
            LevrForwarder_v1 forwarder,
            LevrDeployer_v1 levrDeployer
        ) = deployFactory(config, address(this), 0xE85A59c628F7d27878ACeB4bf3b35733630083a9);

        // Verify configuration
        assertEq(factory.protocolFeeBps(), protocolFeeBps);
        assertEq(factory.streamWindowSeconds(address(0)), streamWindowSeconds);
        assertEq(factory.protocolTreasury(), protocolTreasury);
        assertEq(factory.proposalWindowSeconds(address(0)), 2 days);
        assertEq(factory.votingWindowSeconds(address(0)), 5 days);
        assertEq(factory.maxActiveProposals(address(0)), 7);
        assertEq(factory.quorumBps(address(0)), 7000);
        assertEq(factory.approvalBps(address(0)), 5100);
        assertEq(factory.minSTokenBpsToSubmit(address(0)), 100);
    }
}
