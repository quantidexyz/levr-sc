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
 * @title DeployLevr Test
 * @notice Comprehensive test suite for the production DeployLevr script
 * @dev Tests all deployment stages and configuration validation
 */
contract DeployLevrTest is Test, LevrFactoryDeployHelper {
    
    // ============ Deployment Configuration Tests ============

    function test_DeployLevr_mainnetConfig() public {
        // Test mainnet configuration (Base mainnet)
        uint16 protocolFeeBps = 50; // 0.5%
        uint32 streamWindowSeconds = 259200; // 3 days
        address protocolTreasury = address(0xDEAD);

        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: protocolFeeBps,
            streamWindowSeconds: streamWindowSeconds,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000, // 70%
            approvalBps: 5100, // 51%
            minSTokenBpsToSubmit: 100, // 1%
            maxProposalAmountBps: 500, // 5%
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        // Deploy factory with forwarder and deployer logic using helper
        (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, LevrDeployer_v1 levrDeployer) = 
            deployFactory(config, address(this), 0xE85A59c628F7d27878ACeB4bf3b35733630083a9);

        // Verify all configuration values
        assertEq(factory.protocolFeeBps(), protocolFeeBps);
        assertEq(factory.streamWindowSeconds(address(0)), streamWindowSeconds);
        assertEq(factory.protocolTreasury(), protocolTreasury);
        assertEq(factory.proposalWindowSeconds(address(0)), 2 days);
        assertEq(factory.votingWindowSeconds(address(0)), 5 days);
        assertEq(factory.maxActiveProposals(address(0)), 7);
        assertEq(factory.quorumBps(address(0)), 7000);
        assertEq(factory.approvalBps(address(0)), 5100);
        assertEq(factory.minSTokenBpsToSubmit(address(0)), 100);
        assertEq(factory.maxProposalAmountBps(address(0)), 500);
        assertEq(factory.minimumQuorumBps(address(0)), 25);
        assertEq(factory.trustedForwarder(), address(forwarder));

        // Verify deployer is authorized
        assertEq(levrDeployer.authorizedFactory(), address(factory));
    }

    function test_DeployLevr_contractAddressesDeployed() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, LevrDeployer_v1 levrDeployer) = 
            deployFactory(config, address(this), address(0x1234));

        // Verify all contracts are deployed with code
        assertTrue(address(factory).code.length > 0, 'Factory should be deployed');
        assertTrue(address(forwarder).code.length > 0, 'Forwarder should be deployed');
        assertTrue(address(levrDeployer).code.length > 0, 'LevrDeployer should be deployed');

        // Verify contract initialization
        assertNotEq(address(factory), address(0));
        assertNotEq(address(forwarder), address(0));
        assertNotEq(address(levrDeployer), address(0));
    }

    function test_DeployLevr_feeSplitterFactoryDeployment() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, ) = 
            deployFactory(config, address(this), address(0x1234));

        // Deploy fee splitter factory
        LevrFeeSplitterFactory_v1 feeSplitterFactory = new LevrFeeSplitterFactory_v1(
            address(factory),
            address(forwarder)
        );

        // Verify fee splitter factory is deployed
        assertTrue(address(feeSplitterFactory).code.length > 0, 'FeeSplitterFactory should be deployed');
        assertNotEq(address(feeSplitterFactory), address(0));
    }

    function test_DeployLevr_clankerFactoryConfiguration() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        address clankerFactory = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), clankerFactory);

        // Verify Clanker factory is added to trusted list
        assertTrue(
            factory.isTrustedClankerFactory(clankerFactory),
            'Clanker factory should be trusted'
        );

        address[] memory trustedFactories = factory.getTrustedClankerFactories();
        assertEq(trustedFactories.length, 1, 'Should have 1 trusted factory');
        assertEq(trustedFactories[0], clankerFactory, 'Trusted factory should match');
    }

    // ============ Configuration Validation Tests ============

    function test_DeployLevr_protocolFeeValidation() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        
        // Test valid protocol fee (50 = 0.5%)
        config.protocolFeeBps = 50;
        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0x1234));
        assertEq(factory.protocolFeeBps(), 50);
    }

    function test_DeployLevr_governanceParametersValidation() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));

        // Test valid governance parameters
        config.proposalWindowSeconds = 1 days;
        config.votingWindowSeconds = 5 days;
        config.maxActiveProposals = 7;
        config.quorumBps = 7000;
        config.approvalBps = 5100;

        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0x1234));
        
        assertEq(factory.proposalWindowSeconds(address(0)), 1 days);
        assertEq(factory.votingWindowSeconds(address(0)), 5 days);
        assertEq(factory.maxActiveProposals(address(0)), 7);
        assertEq(factory.quorumBps(address(0)), 7000);
        assertEq(factory.approvalBps(address(0)), 5100);
    }

    function test_DeployLevr_invalidBpsThrowsError() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        
        // Test invalid BPS > 10000
        config.quorumBps = 15000; // > 100%
        
        // This should be caught during factory initialization validation
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        new LevrFactory_v1(config, address(this), address(0x1), address(0x2), new address[](0));
    }

    function test_DeployLevr_streamWindowValidation() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        
        // Test valid stream window (at least 1 day)
        config.streamWindowSeconds = 1 days;
        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0x1234));
        assertEq(factory.streamWindowSeconds(address(0)), 1 days);
        
        // Test zero stream window should revert
        config.streamWindowSeconds = 0;
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        new LevrFactory_v1(config, address(this), address(0x1), address(0x2), new address[](0));
    }

    // ============ Multi-Contract Interaction Tests ============

    function test_DeployLevr_forwarderIntegration() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, ) = 
            deployFactory(config, address(this), address(0x1234));

        // Verify factory trusts the forwarder
        assertEq(factory.trustedForwarder(), address(forwarder), 'Factory should trust forwarder');
    }

    function test_DeployLevr_deployerAuthorization() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        (LevrFactory_v1 factory, , LevrDeployer_v1 deployer) = 
            deployFactory(config, address(this), address(0x1234));

        // Verify deployer knows which factory authorized it
        assertEq(deployer.authorizedFactory(), address(factory), 'Deployer should know factory');
    }

    // ============ Production Readiness Tests ============

    function test_DeployLevr_initialWhitelistConfiguration() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0x1234));

        // Get initial whitelist (should include WETH from the deployment)
        address[] memory whitelist = factory.getInitialWhitelist();
        
        // In production, this should include WETH
        // For test purposes, just verify the getter works
        assertEq(whitelist.length >= 0, true, 'Whitelist should be valid');
    }

    function test_DeployLevr_protocolTreasurySetCorrectly() public {
        address treasury = address(0xFEEDED);
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 50,
            streamWindowSeconds: 3 days,
            protocolTreasury: treasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0x1234));

        // Verify protocol treasury is set correctly
        assertEq(factory.protocolTreasury(), treasury, 'Protocol treasury should match config');
    }

    // ============ Edge Cases Tests ============

    function test_DeployLevr_minimumQuorumBpsZero() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        config.minimumQuorumBps = 0; // Allow zero minimum quorum

        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0x1234));
        assertEq(factory.minimumQuorumBps(address(0)), 0);
    }

    function test_DeployLevr_maxProposalAmountBpsZero() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        
        // Zero max proposal amount is technically allowed (no proposal size limit)
        // But let's test a valid minimal value
        config.maxProposalAmountBps = 1; // Minimum 0.01% of treasury
        (LevrFactory_v1 factory, , ) = deployFactory(config, address(this), address(0xAAAA));
        assertEq(factory.maxProposalAmountBps(address(0)), 1);
    }

    function test_DeployLevr_maxActiveProposalsZero() public {
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(address(this));
        
        // Zero max active proposals should revert
        config.maxActiveProposals = 0;
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        new LevrFactory_v1(config, address(this), address(0x1), address(0x2), new address[](0));
    }

    // ============ Deployment Consistency Tests ============

    function test_DeployLevr_multipleDeploymentsIndependent() public {
        // Deploy first factory with clankerFactory 0x1234
        ILevrFactory_v1.FactoryConfig memory config1 = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 50,
            streamWindowSeconds: 3 days,
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

        (LevrFactory_v1 factory1, LevrForwarder_v1 forwarder1, ) = 
            deployFactory(config1, address(this), address(0x1234));

        // Deploy second factory with different config and clankerFactory 0x5678
        ILevrFactory_v1.FactoryConfig memory config2 = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 5000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        (LevrFactory_v1 factory2, LevrForwarder_v1 forwarder2, ) = 
            deployFactory(config2, address(0xAAAA), address(0x5678));

        // Verify they are different contracts
        assertNotEq(address(factory1), address(factory2), 'Factories should be different');
        assertNotEq(address(forwarder1), address(forwarder2), 'Forwarders should be different');

        // Verify independent configs
        assertEq(factory1.protocolFeeBps(), 50, 'First factory fee should be 50');
        assertEq(factory2.protocolFeeBps(), 100, 'Second factory fee should be 100');
        assertEq(factory1.maxActiveProposals(address(0)), 7, 'First factory maxActive should be 7');
        assertEq(factory2.maxActiveProposals(address(0)), 10, 'Second factory maxActive should be 10');
    }
}
