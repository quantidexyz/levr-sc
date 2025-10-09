// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';

/// @title Levr Factory Deployment Helper
/// @notice Helper contract for deploying LevrFactory_v1 with all dependencies in tests
/// @dev Handles the complex deployment sequence: forwarder → predict factory → deployer logic → factory
contract LevrFactoryDeployHelper is Test {
    /// @notice Deploy a complete factory with forwarder and deployer logic
    /// @dev This handles the tricky nonce calculation to ensure deployer logic is authorized
    /// @param cfg Factory configuration
    /// @param owner Factory owner address
    /// @param clankerFactory Clanker factory address (use 0xE85A59c628F7d27878ACeB4bf3b35733630083a9 for Base)
    /// @return factory The deployed factory
    /// @return forwarder The deployed forwarder
    /// @return levrDeployer The deployed deployer logic
    function deployFactory(
        ILevrFactory_v1.FactoryConfig memory cfg,
        address owner,
        address clankerFactory
    )
        internal
        returns (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, LevrDeployer_v1 levrDeployer)
    {
        // Step 1: Deploy forwarder
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        // Step 2: Calculate factory address (will be deployed at next nonce + 1)
        // Current nonce is after forwarder, +1 for deployer logic, +1 for factory
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), currentNonce + 1);

        // Step 3: Deploy deployer logic with predicted factory address
        levrDeployer = new LevrDeployer_v1(predictedFactory);

        // Step 4: Deploy factory
        factory = new LevrFactory_v1(
            cfg,
            owner,
            address(forwarder),
            clankerFactory,
            address(levrDeployer)
        );

        // Step 5: Verify factory was deployed at predicted address
        require(
            address(factory) == predictedFactory,
            'LevrFactoryDeployHelper: Factory address mismatch'
        );
        require(
            levrDeployer.authorizedFactory() == address(factory),
            'LevrFactoryDeployHelper: Deployer authorization failed'
        );
    }

    /// @notice Deploy factory with default Base mainnet Clanker factory
    /// @param cfg Factory configuration
    /// @param owner Factory owner address
    /// @return factory The deployed factory
    /// @return forwarder The deployed forwarder
    /// @return levrDeployer The deployed deployer logic
    function deployFactoryWithDefaultClanker(
        ILevrFactory_v1.FactoryConfig memory cfg,
        address owner
    )
        internal
        returns (LevrFactory_v1 factory, LevrForwarder_v1 forwarder, LevrDeployer_v1 levrDeployer)
    {
        // Base mainnet Clanker factory
        address clankerFactory = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
        return deployFactory(cfg, owner, clankerFactory);
    }

    /// @notice Create default factory configuration for tests
    /// @param protocolTreasury Protocol treasury address
    /// @return cfg Default configuration
    function createDefaultConfig(
        address protocolTreasury
    ) internal pure returns (ILevrFactory_v1.FactoryConfig memory cfg) {
        cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000, // 70%
            approvalBps: 5100, // 51%
            minSTokenBpsToSubmit: 100 // 1%
        });
    }
}
