// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {MockClankerFactory} from '../mocks/MockClankerFactory.sol';

/// @title Levr Factory Deployment Helper
/// @notice Helper contract for deploying LevrFactory_v1 with all dependencies in tests
/// @dev Handles the complex deployment sequence: forwarder → predict factory → deployer logic → factory
contract LevrFactoryDeployHelper is Test {
    /// @dev Store the mock Clanker factory address for use in tests
    address internal mockClankerFactory;

    /// @dev Cached implementations for creating test instances
    LevrTreasury_v1 internal _treasuryImpl;
    LevrStaking_v1 internal _stakingImpl;
    LevrGovernor_v1 internal _governorImpl;

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

        // Step 2: Calculate factory address (will be deployed after implementations and deployer)
        // Current nonce is after forwarder, +3 implementations, +1 deployer logic, +1 for factory
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), currentNonce + 4);

        // Step 3: Deploy implementation contracts with predicted factory
        LevrTreasury_v1 treasuryImpl = new LevrTreasury_v1(predictedFactory, address(forwarder));
        LevrStaking_v1 stakingImpl = new LevrStaking_v1(address(forwarder), predictedFactory);
        LevrGovernor_v1 governorImpl = new LevrGovernor_v1(address(forwarder), predictedFactory);

        // Step 4: Deploy deployer logic with predicted factory address and implementations
        // Note: StakedToken is deployed as new instance per project, not cloned
        levrDeployer = new LevrDeployer_v1(
            predictedFactory,
            address(treasuryImpl),
            address(stakingImpl),
            address(governorImpl)
        );

        // Step 5: Deploy mock WETH at hardcoded Base WETH address (if not already deployed)
        address weth = 0x4200000000000000000000000000000000000006; // Base WETH
        if (weth.code.length == 0) {
            // Deploy MockERC20 at this address using deployCodeTo
            deployCodeTo('MockERC20', abi.encode('Wrapped Ether', 'WETH'), weth);
        }

        // Step 6: Build initial whitelist (WETH for Base)
        address[] memory initialWhitelist = new address[](1);
        initialWhitelist[0] = weth;

        // Step 7: Deploy factory with initial whitelist
        factory = new LevrFactory_v1(
            cfg,
            owner,
            address(forwarder),
            address(levrDeployer),
            initialWhitelist
        );

        // Step 8: Verify factory was deployed at predicted address
        require(
            address(factory) == predictedFactory,
            'LevrFactoryDeployHelper: Factory address mismatch'
        );
        require(
            levrDeployer.authorizedFactory() == address(factory),
            'LevrFactoryDeployHelper: Deployer authorization failed'
        );

        // Step 9: Add Clanker factory to trusted list if provided
        if (clankerFactory != address(0)) {
            vm.prank(owner);
            factory.addTrustedClankerFactory(clankerFactory);
        }
    }

    /// @notice Deploy factory with default Base mainnet Clanker factory (or mock for unit tests)
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
        // Base mainnet Clanker factory address
        address clankerFactory = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;

        // If running in unit test mode (Clanker factory not deployed), deploy a mock factory
        // In fork tests, the real Clanker factory will have code deployed
        if (clankerFactory.code.length == 0) {
            MockClankerFactory mockFactory = new MockClankerFactory();
            clankerFactory = address(mockFactory);
            mockClankerFactory = clankerFactory;
        }

        return deployFactory(cfg, owner, clankerFactory);
    }

    /// @notice Register a token with the mock Clanker factory (for unit tests)
    /// @dev This allows MockERC20 tokens to pass Clanker factory validation
    /// @param token Token address to register
    function registerTokenWithMockClanker(address token) internal {
        if (mockClankerFactory != address(0)) {
            MockClankerFactory(mockClankerFactory).registerToken(token);
        }
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
    /// @param rewardTokens Array of reward tokens to whitelist (e.g., WETH, USDC)
    /// @dev This initializes staking with reward tokens automatically whitelisted via initialWhitelistedTokens
    function initializeStakingWithRewardTokens(
        LevrStaking_v1 staking,
        address underlying,
        address stakedToken,
        address treasury,
        address[] memory rewardTokens
    ) internal {
        // Initialize staking with reward tokens already whitelisted
        // Note: underlying is always whitelisted automatically, separate from the array
        // Factory address is set in constructor, not in initialize
        staking.initialize(underlying, stakedToken, treasury, rewardTokens);
    }

    /// @notice Helper to initialize staking with a single reward token whitelisted
    /// @param staking The staking contract to initialize
    /// @param underlying The underlying token address
    /// @param stakedToken The staked token address
    /// @param treasury The treasury address
    /// @param rewardToken Single reward token to whitelist (e.g., WETH)
    /// @dev Convenience wrapper for single token case
    function initializeStakingWithRewardToken(
        LevrStaking_v1 staking,
        address underlying,
        address stakedToken,
        address treasury,
        address rewardToken
    ) internal {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = rewardToken;
        initializeStakingWithRewardTokens(
            staking,
            underlying,
            stakedToken,
            treasury,
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

    /// @notice Create a staked token for unit tests
    /// @dev Deploys a new instance per call (not cloned)
    function createStakedToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address underlying,
        address staking
    ) internal returns (LevrStakedToken_v1) {
        // Deploy new instance directly (no clone pattern)
        return new LevrStakedToken_v1(name, symbol, decimals, underlying, staking);
    }

    /// @notice Create an initialized governor for unit tests
    /// @dev Uses clone pattern with cached implementations. Creates implementation on first call.
    function createGovernor(
        address forwarder,
        address factory,
        address treasury,
        address staking,
        address stakedToken,
        address underlying
    ) internal returns (LevrGovernor_v1) {
        // Deploy implementation if not yet created
        if (address(_governorImpl) == address(0)) {
            _governorImpl = new LevrGovernor_v1(forwarder, factory);
        }

        address clone = Clones.clone(address(_governorImpl));
        // Only factory can initialize - use prank to initialize as factory
        vm.prank(factory);
        LevrGovernor_v1(clone).initialize(treasury, staking, stakedToken, underlying);
        return LevrGovernor_v1(clone);
    }

    /// @notice Create an initialized staking contract for unit tests
    /// @dev Uses clone pattern with cached implementations. Creates implementation on first call.
    function createStaking(address forwarder, address factory) internal returns (LevrStaking_v1) {
        // Deploy implementation if not yet created
        if (address(_stakingImpl) == address(0)) {
            _stakingImpl = new LevrStaking_v1(forwarder, factory);
        }

        address clone = Clones.clone(address(_stakingImpl));
        return LevrStaking_v1(clone);
    }

    /// @notice Create an initialized treasury contract for unit tests
    /// @dev Uses clone pattern with cached implementations. Creates implementation on first call.
    function createTreasury(address forwarder, address factory) internal returns (LevrTreasury_v1) {
        // Deploy implementation if not yet created
        if (address(_treasuryImpl) == address(0)) {
            _treasuryImpl = new LevrTreasury_v1(factory, forwarder);
        }

        address clone = Clones.clone(address(_treasuryImpl));
        return LevrTreasury_v1(clone);
    }

    /// @notice Create a deployer for tests (handles test cases that need deployer directly)
    /// @dev For tests that validate deployer behavior
    function createDeployer(address factory) internal returns (LevrDeployer_v1) {
        // For test deployer, use mock implementations
        LevrTreasury_v1 ti = new LevrTreasury_v1(factory, address(0));
        LevrStaking_v1 si = new LevrStaking_v1(address(0), factory);
        LevrGovernor_v1 gi = new LevrGovernor_v1(address(0), factory);

        return new LevrDeployer_v1(factory, address(ti), address(si), address(gi));
    }
}
