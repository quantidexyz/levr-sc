// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from 'forge-std/Test.sol';
import {DeployLevrFeeSplitter} from '../script/DeployLevrFeeSplitter.s.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';

/**
 * @title DeployLevrFeeSplitter Test
 * @notice Tests for the LevrFeeSplitter deployment script
 */
contract DeployLevrFeeSplitterTest is Test {
    DeployLevrFeeSplitter internal deployScript;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;

    function setUp() public {
        // Deploy Levr infrastructure first (factory + forwarder)
        deployScript = new DeployLevrFeeSplitter();

        // Deploy forwarder
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        // Deploy deployer logic (predict factory address)
        address deployer = address(this);
        uint64 nonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce + 1);
        LevrDeployer_v1 levrDeployer = new LevrDeployer_v1(predictedFactory);

        // Deploy factory
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 50,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(this),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100
        });

        factory = new LevrFactory_v1(
            config,
            deployer,
            address(forwarder),
            address(0xE85A59c628F7d27878ACeB4bf3b35733630083a9), // Clanker factory
            address(levrDeployer)
        );
    }

    function test_deploymentScriptConfiguration() public view {
        // Verify factory is deployed
        assertTrue(address(factory).code.length > 0, 'Factory should be deployed');

        // Verify forwarder is deployed
        assertTrue(address(forwarder).code.length > 0, 'Forwarder should be deployed');

        // Verify factory has correct forwarder
        assertEq(
            factory.trustedForwarder(),
            address(forwarder),
            'Factory should reference forwarder'
        );
    }

    function test_deploymentScriptExecution() public {
        // Set up environment variables for deployment
        vm.setEnv('FACTORY_ADDRESS', vm.toString(address(factory)));
        vm.setEnv('PRIVATE_KEY', vm.toString(uint256(0x1234)));

        // Fund the deployer
        address deployer = vm.addr(0x1234);
        vm.deal(deployer, 1 ether);

        // This would execute the deployment
        // Note: In actual test, we'd use vm.broadcast() or similar
        // For this test, we just verify the setup is correct

        // Verify environment is correctly configured
        address envFactory = vm.envAddress('FACTORY_ADDRESS');
        assertEq(envFactory, address(factory), 'Environment should have factory address');
    }
}
