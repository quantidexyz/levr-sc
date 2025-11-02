// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

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

        // Step 4: Deploy mock WETH at hardcoded Base WETH address (if not already deployed)
        address weth = 0x4200000000000000000000000000000000000006; // Base WETH
        if (weth.code.length == 0) {
            // Deploy MockERC20 at this address using deployCodeTo
            deployCodeTo('MockERC20', abi.encode('Wrapped Ether', 'WETH'), weth);
        }

        // Step 5: Build initial whitelist (WETH for Base)
        address[] memory initialWhitelist = new address[](1);
        initialWhitelist[0] = weth;

        // Step 6: Deploy factory with initial whitelist
        factory = new LevrFactory_v1(
            cfg,
            owner,
            address(forwarder),
            address(levrDeployer),
            initialWhitelist
        );

        // Step 7: Verify factory was deployed at predicted address
        require(
            address(factory) == predictedFactory,
            'LevrFactoryDeployHelper: Factory address mismatch'
        );
        require(
            levrDeployer.authorizedFactory() == address(factory),
            'LevrFactoryDeployHelper: Deployer authorization failed'
        );

        // Step 8: Add Clanker factory to trusted list if provided
        if (clankerFactory != address(0)) {
            vm.prank(owner);
            factory.addTrustedClankerFactory(clankerFactory);
        }
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
            minSTokenBpsToSubmit: 100, // 1%
            maxProposalAmountBps: 500, // 5%
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });
    }

    /// @notice Helper to initialize staking with reward tokens already whitelisted
    /// @param staking The staking contract to initialize
    /// @param underlying The underlying token address
    /// @param stakedToken The staked token address
    /// @param treasury The treasury address
    /// @param factory The factory address (or test contract address for tests)
    /// @param rewardTokens Array of reward tokens to whitelist (e.g., WETH, USDC)
    /// @dev This initializes staking with reward tokens automatically whitelisted via initialWhitelistedTokens
    function initializeStakingWithRewardTokens(
        LevrStaking_v1 staking,
        address underlying,
        address stakedToken,
        address treasury,
        address factory,
        address[] memory rewardTokens
    ) internal {
        // Initialize staking with reward tokens already whitelisted
        // Note: underlying is always whitelisted automatically, separate from the array
        staking.initialize(underlying, stakedToken, treasury, factory, rewardTokens);
    }

    /// @notice Helper to initialize staking with a single reward token whitelisted
    /// @param staking The staking contract to initialize
    /// @param underlying The underlying token address
    /// @param stakedToken The staked token address
    /// @param treasury The treasury address
    /// @param factory The factory address (or test contract address for tests)
    /// @param rewardToken Single reward token to whitelist (e.g., WETH)
    /// @dev Convenience wrapper for single token case
    function initializeStakingWithRewardToken(
        LevrStaking_v1 staking,
        address underlying,
        address stakedToken,
        address treasury,
        address factory,
        address rewardToken
    ) internal {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = rewardToken;
        initializeStakingWithRewardTokens(
            staking,
            underlying,
            stakedToken,
            treasury,
            factory,
            rewardTokens
        );
    }

    /// @notice Helper to whitelist a dynamically created reward token (for tokens created during tests)
    /// @param staking The staking contract
    /// @param token Token to whitelist
    /// @param tokenAdmin Admin address (typically the underlying token admin)
    /// @dev Use this only for tokens created dynamically in tests. Prefer initializeStakingWithRewardTokens for common tokens.
    function whitelistRewardToken(
        LevrStaking_v1 staking,
        address token,
        address tokenAdmin
    ) internal {
        vm.prank(tokenAdmin);
        staking.whitelistToken(token);
        require(staking.isTokenWhitelisted(token), 'Token not whitelisted');
    }

    /// @notice Helper to whitelist a token and verify it was whitelisted
    /// @param staking The staking contract
    /// @param token Token to whitelist
    /// @param tokenAdmin Admin address (will be pranked)
    /// @dev Deprecated: Use whitelistRewardToken for clarity
    function setupAndWhitelistToken(
        LevrStaking_v1 staking,
        address token,
        address tokenAdmin
    ) internal {
        whitelistRewardToken(staking, token, tokenAdmin);
    }
}
