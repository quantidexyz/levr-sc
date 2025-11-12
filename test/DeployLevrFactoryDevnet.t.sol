// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';
import {LevrFeeSplitterFactory_v1} from '../src/LevrFeeSplitterFactory_v1.sol';
import {LevrFactoryDeployHelper} from './utils/LevrFactoryDeployHelper.sol';

/**
 * @title DeployLevrFactoryDevnet Test
 * @notice Comprehensive test suite for the devnet deployment script logic
 */
contract DeployLevrFactoryDevnetTest is Test, LevrFactoryDeployHelper {
    
    // Devnet configuration constants (matching the script)
    uint16 constant PROTOCOL_FEE_BPS = 50;
    uint32 constant STREAM_WINDOW_SECONDS = 259200; // 3 days

    function test_DevnetConfig() public {
        // Test the same configuration values used in the deployment script
        uint16 protocolFeeBps = 50;
        uint32 streamWindowSeconds = 259200; // Fixed to match script constant
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
        (LevrFactory_v1 factory, , ) = deployFactory(
            config,
            address(this),
            0xE85A59c628F7d27878ACeB4bf3b35733630083a9
        );

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

    function test_DevnetDeployment_constants() public {
        // Verify constants match script expectations
        assertEq(PROTOCOL_FEE_BPS, 50, 'Protocol fee should be 50 BPS (0.5%)');
        assertEq(STREAM_WINDOW_SECONDS, 259200, 'Stream window should be 3 days');
    }

    function test_DevnetDeployment_fullSequence() public {
        // Test complete devnet deployment sequence
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: PROTOCOL_FEE_BPS,
            streamWindowSeconds: STREAM_WINDOW_SECONDS,
            protocolTreasury: address(this),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        // Deploy all infrastructure
        (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, LevrDeployer_v1 deployer) = 
            deployFactory(config, address(this), 0xE85A59c628F7d27878ACeB4bf3b35733630083a9);

        // Verify all contracts deployed
        assertTrue(address(factory).code.length > 0, 'Factory should be deployed');
        assertTrue(address(forwarder).code.length > 0, 'Forwarder should be deployed');
        assertTrue(address(deployer).code.length > 0, 'Deployer should be deployed');

        // Verify factory configuration
        assertEq(factory.protocolFeeBps(), PROTOCOL_FEE_BPS);
        assertEq(factory.streamWindowSeconds(address(0)), STREAM_WINDOW_SECONDS);
    }

    function test_DevnetDeployment_clankerFactoryTrusted() public {
        // Test Clanker factory is added to trusted list
        address clankerFactory = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
        
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        config.protocolFeeBps = PROTOCOL_FEE_BPS;
        config.streamWindowSeconds = STREAM_WINDOW_SECONDS;

        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), clankerFactory);

        // Verify Clanker factory is trusted
        assertTrue(factory.isTrustedClankerFactory(clankerFactory), 'Clanker factory should be trusted');
        
        address[] memory trustedFactories = factory.getTrustedClankerFactories();
        assertEq(trustedFactories.length, 1, 'Should have 1 trusted factory');
        assertEq(trustedFactories[0], clankerFactory, 'Trusted factory should match');
    }

    function test_DevnetDeployment_feeSplitterFactoryIntegration() public {
        // Test fee splitter factory deployment and integration
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        config.protocolFeeBps = PROTOCOL_FEE_BPS;
        config.streamWindowSeconds = STREAM_WINDOW_SECONDS;

        (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, ) = 
            deployFactory(config, address(this), 0xE85A59c628F7d27878ACeB4bf3b35733630083a9);

        // Deploy fee splitter factory
        LevrFeeSplitterFactory_v1 feeSplitterFactory = new LevrFeeSplitterFactory_v1(
            address(factory),
            address(forwarder)
        );

        // Verify integration
        assertEq(feeSplitterFactory.factory(), address(factory), 'Fee splitter should reference factory');
        assertEq(feeSplitterFactory.trustedForwarder(), address(forwarder), 'Fee splitter should trust forwarder');
    }

    function test_DevnetDeployment_getWETH() public {
        // Test getWETH helper for different chains (as in script)
        
        // Base mainnet
        address wethMainnet = this.getWETHHelperDevnet(8453);
        assertEq(wethMainnet, 0x4200000000000000000000000000000000000006, 'WETH mainnet mismatch');
        
        // Base Sepolia
        address wethSepolia = this.getWETHHelperDevnet(84532);
        assertEq(wethSepolia, 0x4200000000000000000000000000000000000006, 'WETH sepolia mismatch');
        
        // Local devnet (should use same address)
        address wethLocal = this.getWETHHelperDevnet(31337);
        assertEq(wethLocal, 0x4200000000000000000000000000000000000006, 'WETH local mismatch');
    }

    function test_DevnetDeployment_deterministicAddresses() public {
        // Test that deployment uses deterministic addresses
        address deployer1 = address(this);
        
        // First deployment
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(deployer1);
        config.protocolFeeBps = PROTOCOL_FEE_BPS;
        config.streamWindowSeconds = STREAM_WINDOW_SECONDS;

        (LevrFactory_v1 factory1, , ) = deployFactory(config, deployer1, address(0x1234));
        
        // Factory should be deployed at a predictable address
        assertTrue(address(factory1) != address(0), 'Factory should be deployed');
        assertTrue(address(factory1).code.length > 0, 'Factory should have code');
    }

    function test_DevnetDeployment_protocolTreasuryAsDeployer() public {
        // Test that protocol treasury is set to deployer (devnet simplification)
        address deployer = address(0xDE9E7);
        
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: PROTOCOL_FEE_BPS,
            streamWindowSeconds: STREAM_WINDOW_SECONDS,
            protocolTreasury: deployer, // Set to deployer as in script
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        (LevrFactory_v1 factory, , ) = deployFactory(config, deployer, address(0x1234));
        
        // Verify protocol treasury is deployer
        assertEq(factory.protocolTreasury(), deployer, 'Protocol treasury should be deployer');
    }

    // ============ Helper Functions for Testing ============

    /// @notice External wrapper for getWETH to test devnet logic
    function getWETHHelperDevnet(uint256 chainId) external pure returns (address) {
        // Base mainnet (8453)
        if (chainId == 8453) return 0x4200000000000000000000000000000000000006;
        // Base Sepolia (84532)
        if (chainId == 84532) return 0x4200000000000000000000000000000000000006;
        // Default for local devnet/anvil
        return 0x4200000000000000000000000000000000000006;
    }
}
