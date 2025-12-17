// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from 'forge-std/Script.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../src/LevrDeployer_v1.sol';
import {LevrFeeSplitterFactory_v1} from '../src/LevrFeeSplitterFactory_v1.sol';
import {LevrTreasury_v1} from '../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../src/LevrStakedToken_v1.sol';

/**
 * @title DeployLevr
 * @notice Production deployment script for Levr Protocol v1 on mainnet/testnet
 * @dev Deploys LevrForwarder, LevrDeployer, and LevrFactory with configurable parameters
 *
 * This script integrates with the common.mk deployment system.
 *
 * Supported Networks:
 * - Base Mainnet (8453)
 * - Base Sepolia (84532)
 * - BNB Mainnet (56)
 *
 * Usage:
 * 1. Set environment variables in .env file:
 *    MAINNET_PRIVATE_KEY=0x...  # For mainnet
 *    TESTNET_PRIVATE_KEY=0x...  # For testnet
 *    PROTOCOL_TREASURY=0x...  # Optional, defaults to deployer
 *    ETHERSCAN_KEY=...  # Optional, for verification
 *
 * 2. Run deployment:
 *    make deploy  # Interactive menu will include "Levr"
 *
 * Environment Variables (Required):
 * - PRIVATE_KEY: Deployment key (auto-selected by common.mk based on network)
 *
 * Environment Variables (Optional - special defaults):
 * - PROTOCOL_TREASURY: Address to receive protocol fees (default: deployer address)
 * - MULTISIG_ADDRESS: Final owner for ownership transfer (default: no transfer, deployer keeps ownership)
 *
 * Environment Variables (Optional - with defaults):
 * - PROTOCOL_FEE_BPS: Protocol fee in basis points (default: 50 = 0.5%)
 * - STREAM_WINDOW_SECONDS: Reward streaming window (default: 259200 = 3 days)
 * - PROPOSAL_WINDOW_SECONDS: Governance proposal window (default: 172800 = 2 days)
 * - VOTING_WINDOW_SECONDS: Governance voting window (default: 432000 = 5 days)
 * - MAX_ACTIVE_PROPOSALS: Max concurrent proposals per type (default: 7)
 * - QUORUM_BPS: Minimum participation threshold (default: 7000 = 70%)
 * - APPROVAL_BPS: Minimum approval threshold (default: 5100 = 51%)
 * - MIN_STOKEN_BPS_TO_SUBMIT: Min % of sToken supply to propose (default: 100 = 1%)
 * - MAX_PROPOSAL_AMOUNT_BPS: Max % of sToken supply to propose (default: 500 = 5%)
 * - CLANKER_FACTORY: Clanker factory address (default: auto-selected based on chain ID)
 *
 * Example .env:
 * MAINNET_PRIVATE_KEY=0xabcd...
 * TESTNET_PRIVATE_KEY=0xef01...
 * PROTOCOL_TREASURY=0x1234...  # Optional, defaults to deployer
 * MULTISIG_ADDRESS=0x5678...   # Optional, transfers ownership after deployment
 * PROTOCOL_FEE_BPS=50
 * STREAM_WINDOW_SECONDS=259200
 *
 * Safety checks:
 * - Validates network is supported (Base mainnet/testnet or BNB mainnet)
 * - Validates all configuration parameters
 * - Confirms factory deployment at predicted address
 * - Outputs all deployed addresses for verification
 */
contract DeployLevr is Script {
    // Default configuration values
    uint16 constant DEFAULT_PROTOCOL_FEE_BPS = 50; // 0.5%
    uint32 constant DEFAULT_STREAM_WINDOW_SECONDS = 259200; // 3 days
    uint32 constant DEFAULT_PROPOSAL_WINDOW_SECONDS = 172800; // 2 days
    uint32 constant DEFAULT_VOTING_WINDOW_SECONDS = 432000; // 5 days
    uint16 constant DEFAULT_MAX_ACTIVE_PROPOSALS = 7;
    uint16 constant DEFAULT_QUORUM_BPS = 7000; // 70%
    uint16 constant DEFAULT_APPROVAL_BPS = 5100; // 51%
    uint16 constant DEFAULT_MIN_STOKEN_BPS_TO_SUBMIT = 100; // 1%
    uint16 constant DEFAULT_MAX_PROPOSAL_AMOUNT_BPS = 500; // 5%
    uint16 constant DEFAULT_MINIMUM_QUORUM_BPS = 25; // 0.25% minimum quorum to prevent early capture

    // Deployment parameters struct to avoid stack-too-deep
    struct DeployParams {
        uint256 privateKey;
        address deployer;
        address protocolTreasury;
        address clankerFactory;
        address multisig; // Final owner for ownership transfer (optional)
        uint16 protocolFeeBps;
        uint32 streamWindowSeconds;
        uint32 proposalWindowSeconds;
        uint32 votingWindowSeconds;
        uint16 maxActiveProposals;
        uint16 quorumBps;
        uint16 approvalBps;
        uint16 minSTokenBpsToSubmit;
        uint16 maxProposalAmountBps;
        uint16 minimumQuorumBps;
    }

    /**
     * @notice Get Clanker factory address for the current chain
     * @param chainId The chain ID to get the factory for
     * @return The Clanker factory address
     */
    function getClankerFactory(uint256 chainId) internal pure returns (address) {
        // Base mainnet (8453): 0xE85A59c628F7d27878ACeB4bf3b35733630083a9
        if (chainId == 8453) return 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
        // Base Sepolia (84532): 0xE85A59c628F7d27878ACeB4bf3b35733630083a9
        if (chainId == 84532) return 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
        // BNB Mainnet (56): 0xFb28402068d716C82D8Cd80567d1B0e2539AdFB2
        if (chainId == 56) return 0xFb28402068d716C82D8Cd80567d1B0e2539AdFB2;
        // Fallback for unsupported chains
        revert('Unsupported chain - no Clanker factory available');
    }

    /**
     * @notice Get wrapped native token address for the current chain (WETH/WBNB)
     * @param chainId The chain ID to get the wrapped native token for
     * @return The wrapped native token address
     */
    function getWrappedNative(uint256 chainId) internal pure returns (address) {
        // Base mainnet (8453): WETH
        if (chainId == 8453) return 0x4200000000000000000000000000000000000006;
        // Base Sepolia (84532): WETH
        if (chainId == 84532) return 0x4200000000000000000000000000000000000006;
        // BNB Mainnet (56): WBNB
        if (chainId == 56) return 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        // Fallback for unsupported chains
        revert('Unsupported chain - no wrapped native token available');
    }

    /**
     * @notice Load configuration from environment
     * @return params Deployment parameters
     */
    function loadConfig() internal view returns (DeployParams memory params) {
        params.privateKey = vm.envUint('PRIVATE_KEY');
        params.deployer = vm.addr(params.privateKey);
        params.protocolTreasury = vm.envExists('PROTOCOL_TREASURY')
            ? vm.envAddress('PROTOCOL_TREASURY')
            : params.deployer;
        params.multisig = vm.envExists('MULTISIG_ADDRESS')
            ? vm.envAddress('MULTISIG_ADDRESS')
            : address(0);
        params.protocolFeeBps = vm.envExists('PROTOCOL_FEE_BPS')
            ? uint16(vm.envUint('PROTOCOL_FEE_BPS'))
            : DEFAULT_PROTOCOL_FEE_BPS;
        params.streamWindowSeconds = vm.envExists('STREAM_WINDOW_SECONDS')
            ? uint32(vm.envUint('STREAM_WINDOW_SECONDS'))
            : DEFAULT_STREAM_WINDOW_SECONDS;
        params.proposalWindowSeconds = vm.envExists('PROPOSAL_WINDOW_SECONDS')
            ? uint32(vm.envUint('PROPOSAL_WINDOW_SECONDS'))
            : DEFAULT_PROPOSAL_WINDOW_SECONDS;
        params.votingWindowSeconds = vm.envExists('VOTING_WINDOW_SECONDS')
            ? uint32(vm.envUint('VOTING_WINDOW_SECONDS'))
            : DEFAULT_VOTING_WINDOW_SECONDS;
        params.maxActiveProposals = vm.envExists('MAX_ACTIVE_PROPOSALS')
            ? uint16(vm.envUint('MAX_ACTIVE_PROPOSALS'))
            : DEFAULT_MAX_ACTIVE_PROPOSALS;
        params.quorumBps = vm.envExists('QUORUM_BPS')
            ? uint16(vm.envUint('QUORUM_BPS'))
            : DEFAULT_QUORUM_BPS;
        params.approvalBps = vm.envExists('APPROVAL_BPS')
            ? uint16(vm.envUint('APPROVAL_BPS'))
            : DEFAULT_APPROVAL_BPS;
        params.minSTokenBpsToSubmit = vm.envExists('MIN_STOKEN_BPS_TO_SUBMIT')
            ? uint16(vm.envUint('MIN_STOKEN_BPS_TO_SUBMIT'))
            : DEFAULT_MIN_STOKEN_BPS_TO_SUBMIT;
        params.maxProposalAmountBps = vm.envExists('MAX_PROPOSAL_AMOUNT_BPS')
            ? uint16(vm.envUint('MAX_PROPOSAL_AMOUNT_BPS'))
            : DEFAULT_MAX_PROPOSAL_AMOUNT_BPS;
        params.minimumQuorumBps = vm.envExists('MINIMUM_QUORUM_BPS')
            ? uint16(vm.envUint('MINIMUM_QUORUM_BPS'))
            : DEFAULT_MINIMUM_QUORUM_BPS;
        params.clankerFactory = vm.envExists('CLANKER_FACTORY')
            ? vm.envAddress('CLANKER_FACTORY')
            : getClankerFactory(block.chainid);
    }

    function run() external {
        // Load configuration from environment
        DeployParams memory params = loadConfig();

        // Validate network and display info
        console.log('=== LEVR PROTOCOL V1 DEPLOYMENT ===');
        console.log('Network Chain ID:', block.chainid);
        console.log('Deployer Address:', params.deployer);
        console.log('Deployer Balance:', params.deployer.balance / 1e18, 'ETH');
        console.log('');

        require(
            block.chainid == 8453 || block.chainid == 84532 || block.chainid == 56,
            'Unsupported network - deploy on Base mainnet (8453), Base Sepolia (84532), or BNB Mainnet (56)'
        );

        string memory networkName;
        if (block.chainid == 8453) {
            networkName = 'Base Mainnet';
        } else if (block.chainid == 84532) {
            networkName = 'Base Sepolia';
        } else {
            networkName = 'BNB Mainnet';
        }
        console.log('Network:', networkName);
        console.log('Clanker Factory (auto-selected):', params.clankerFactory);
        if (params.multisig != address(0) && params.multisig != params.deployer) {
            console.log('Multisig (final owner):', params.multisig);
        }
        console.log('');

        // Note: Balance checks are skipped - Foundry validates during broadcast

        // Show if protocol treasury is using default
        if (params.protocolTreasury == params.deployer) {
            console.log('Protocol Treasury: Using deployer address (default)');
        } else {
            console.log('Protocol Treasury:', params.protocolTreasury);
        }
        console.log('');

        // Validate configuration parameters
        require(params.protocolFeeBps <= 10000, 'Protocol fee BPS cannot exceed 100%');
        require(params.streamWindowSeconds >= 1 days, 'Stream window must be at least 1 day');
        require(params.proposalWindowSeconds > 0, 'Proposal window must be positive');
        require(params.votingWindowSeconds > 0, 'Voting window must be positive');
        require(params.maxActiveProposals > 0, 'Max active proposals must be positive');
        require(params.quorumBps <= 10000, 'Quorum BPS cannot exceed 100%');
        require(params.approvalBps <= 10000, 'Approval BPS cannot exceed 100%');
        require(params.minSTokenBpsToSubmit <= 10000, 'Min sToken BPS cannot exceed 100%');
        require(params.maxProposalAmountBps <= 10000, 'Max proposal amount BPS cannot exceed 100%');
        require(params.minimumQuorumBps <= 10000, 'Minimum quorum BPS cannot exceed 100%');
        require(params.clankerFactory != address(0), 'Clanker factory cannot be zero address');

        // Build factory configuration
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: params.protocolFeeBps,
            streamWindowSeconds: params.streamWindowSeconds,
            protocolTreasury: params.protocolTreasury,
            proposalWindowSeconds: params.proposalWindowSeconds,
            votingWindowSeconds: params.votingWindowSeconds,
            maxActiveProposals: params.maxActiveProposals,
            quorumBps: params.quorumBps,
            approvalBps: params.approvalBps,
            minSTokenBpsToSubmit: params.minSTokenBpsToSubmit,
            maxProposalAmountBps: params.maxProposalAmountBps,
            minimumQuorumBps: params.minimumQuorumBps
        });

        console.log('=== DEPLOYMENT CONFIGURATION ===');
        if (params.protocolTreasury == params.deployer) {
            console.log('Protocol Treasury:', params.protocolTreasury, '(deployer - default)');
        } else {
            console.log('Protocol Treasury:', params.protocolTreasury, '(custom)');
        }
        console.log('Clanker Factory:', params.clankerFactory);
        console.log('');
        console.log('Factory Configuration:');
        console.log('- Protocol Fee BPS:', config.protocolFeeBps);
        console.log('- Stream Window (seconds):', config.streamWindowSeconds);
        console.log('- Proposal Window (seconds):', config.proposalWindowSeconds);
        console.log('- Voting Window (seconds):', config.votingWindowSeconds);
        console.log('- Max Active Proposals (per type):', config.maxActiveProposals);
        console.log('- Quorum BPS:', config.quorumBps);
        console.log('- Approval BPS:', config.approvalBps);
        console.log('- Min sToken BPS to Submit:', config.minSTokenBpsToSubmit);
        console.log('- Max Proposal Amount BPS:', config.maxProposalAmountBps);
        console.log('- Minimum Quorum BPS:', config.minimumQuorumBps);
        console.log('');

        // =======================================================================
        // DEPLOYMENT
        // =======================================================================

        console.log('=== STARTING DEPLOYMENT ===');
        console.log('');

        vm.startBroadcast(params.privateKey);

        // 1. Deploy the forwarder (includes executeMulticall support)
        console.log('Deploying LevrForwarder_v1...');
        LevrForwarder_v1 forwarder = new LevrForwarder_v1('LevrForwarder_v1');
        console.log('- Forwarder deployed at:', address(forwarder));
        console.log('');

        // 2. Calculate the factory address BEFORE deploying implementations
        // The factory will be deployed at nonce = vm.getNonce(params.deployer) + 5
        // (current nonce + forwarder=1, +4 implementations, +1 deployer logic, +1 factory)
        uint64 currentNonce = vm.getNonce(params.deployer);
        address predictedFactory = vm.computeCreateAddress(params.deployer, currentNonce + 5);
        console.log('Predicted Factory Address:', predictedFactory);
        console.log('Current Deployer Nonce:', currentNonce);
        console.log('');

        // 3. Deploy implementation contracts with real factory and forwarder addresses
        console.log('Deploying implementation contracts...');
        LevrTreasury_v1 treasuryImpl = new LevrTreasury_v1(predictedFactory, address(forwarder));
        LevrStaking_v1 stakingImpl = new LevrStaking_v1(predictedFactory, address(forwarder));
        LevrGovernor_v1 governorImpl = new LevrGovernor_v1(predictedFactory, address(forwarder));
        LevrStakedToken_v1 stakedTokenImpl = new LevrStakedToken_v1(predictedFactory);
        console.log('- Treasury Implementation:', address(treasuryImpl));
        console.log('- Staking Implementation:', address(stakingImpl));
        console.log('- Governor Implementation:', address(governorImpl));
        console.log('- Staked Token Implementation:', address(stakedTokenImpl));
        console.log('');

        // 4. Deploy the deployer logic contract with predicted factory address and implementations
        console.log('Deploying LevrDeployer_v1...');
        LevrDeployer_v1 levrDeployer = new LevrDeployer_v1(
            predictedFactory,
            address(treasuryImpl),
            address(stakingImpl),
            address(governorImpl),
            address(stakedTokenImpl)
        );
        console.log('- Deployer Logic deployed at:', address(levrDeployer));
        console.log('- Authorized Factory:', levrDeployer.authorizedFactory());
        console.log('');

        // 5. Build initial whitelist (wrapped native token always included)
        address wrappedNative = getWrappedNative(block.chainid);
        address[] memory initialWhitelist = new address[](1);
        initialWhitelist[0] = wrappedNative;
        console.log('Initial whitelist:');
        console.log('- Wrapped Native (WETH/WBNB):', wrappedNative);
        console.log('');

        ILevrFactory_v1.ConfigBounds memory bounds = ILevrFactory_v1.ConfigBounds({
            minStreamWindowSeconds: 1 days,
            minProposalWindowSeconds: 6 hours,
            minVotingWindowSeconds: 2 days,
            minQuorumBps: 2000,
            minApprovalBps: 5000,
            minMinSTokenBpsToSubmit: 100,
            minMinimumQuorumBps: 25
        });

        // 6. Deploy the factory with forwarder, deployer logic, and initial whitelist
        console.log('Deploying LevrFactory_v1...');
        LevrFactory_v1 factory = new LevrFactory_v1(
            config,
            bounds,
            params.deployer,
            address(forwarder),
            address(levrDeployer),
            initialWhitelist
        );
        console.log('- Factory deployed at:', address(factory));

        // Verify the factory was deployed at the predicted address
        require(
            address(factory) == predictedFactory,
            'Factory address mismatch - deployment order changed'
        );
        console.log('- Factory address verified!');
        console.log('');

        // Add Clanker factory to trusted factories list
        console.log('Adding Clanker factory to trusted list...');
        factory.addTrustedClankerFactory(params.clankerFactory);
        console.log('- Clanker factory trusted:', params.clankerFactory);
        console.log('');

        // 7. Deploy the fee splitter deployer (creates per-project splitters)
        console.log('Deploying LevrFeeSplitterFactory_v1...');
        LevrFeeSplitterFactory_v1 feeSplitterFactory = new LevrFeeSplitterFactory_v1(
            address(factory),
            address(forwarder)
        );
        console.log('- LevrFeeSplitterFactory_v1:', address(feeSplitterFactory));
        console.log('');

        // 8. Transfer ownership to multisig (if configured)
        if (params.multisig != address(0) && params.multisig != params.deployer) {
            console.log('=== TRANSFERRING OWNERSHIP TO MULTISIG ===');
            console.log('Multisig address:', params.multisig);
            console.log('');

            factory.transferOwnership(params.multisig);
            console.log('- LevrFactory_v1 ownership transferred');

            console.log('');
            console.log('All ownership transfers complete!');
            console.log('');
        } else {
            console.log('=== SKIPPING OWNERSHIP TRANSFER ===');
            console.log(
                'No multisig configured or same as deployer - ownership remains with deployer'
            );
            console.log('');
        }

        vm.stopBroadcast();

        // =======================================================================
        // POST-DEPLOYMENT VALIDATION
        // =======================================================================

        console.log('=== DEPLOYMENT VERIFICATION ===');

        // Verify factory configuration
        require(factory.protocolFeeBps() == params.protocolFeeBps, 'Protocol fee BPS mismatch');
        require(
            factory.streamWindowSeconds(address(0)) == params.streamWindowSeconds,
            'Stream window mismatch'
        );
        require(
            factory.proposalWindowSeconds(address(0)) == params.proposalWindowSeconds,
            'Proposal window mismatch'
        );
        require(
            factory.votingWindowSeconds(address(0)) == params.votingWindowSeconds,
            'Voting window mismatch'
        );
        require(
            factory.maxActiveProposals(address(0)) == params.maxActiveProposals,
            'Max active proposals mismatch'
        );
        require(factory.quorumBps(address(0)) == params.quorumBps, 'Quorum BPS mismatch');
        require(factory.approvalBps(address(0)) == params.approvalBps, 'Approval BPS mismatch');
        require(
            factory.minSTokenBpsToSubmit(address(0)) == params.minSTokenBpsToSubmit,
            'Min sToken BPS mismatch'
        );
        require(
            factory.maxProposalAmountBps(address(0)) == params.maxProposalAmountBps,
            'Max proposal amount BPS mismatch'
        );
        require(
            factory.minimumQuorumBps(address(0)) == params.minimumQuorumBps,
            'Minimum quorum BPS mismatch'
        );
        require(
            factory.protocolTreasury() == params.protocolTreasury,
            'Protocol treasury mismatch'
        );
        require(factory.trustedForwarder() == address(forwarder), 'Trusted forwarder mismatch');

        console.log('All configuration parameters verified!');
        console.log('');

        // =======================================================================
        // DEPLOYMENT SUMMARY
        // =======================================================================

        console.log('=== DEPLOYMENT SUCCESSFUL ===');
        console.log('');
        console.log('Deployed Contracts:');
        console.log('- LevrForwarder_v1:', address(forwarder));
        console.log('- LevrDeployer_v1:', address(levrDeployer));
        console.log('- LevrFactory_v1:', address(factory));
        console.log('- LevrFeeSplitterFactory_v1:', address(feeSplitterFactory));
        console.log('');
        console.log('Factory Configuration:');
        if (params.multisig != address(0) && params.multisig != params.deployer) {
            console.log('- Owner (Multisig):', params.multisig);
        } else {
            console.log('- Owner (Deployer):', params.deployer);
        }
        console.log('- Protocol Treasury:', params.protocolTreasury);
        console.log('- Clanker Factory:', params.clankerFactory);
        console.log('- Trusted Forwarder:', address(forwarder));
        console.log('');
        console.log('Governance Parameters:');
        console.log('- Proposal Window:', params.proposalWindowSeconds / 1 days, 'days');
        console.log('- Voting Window:', params.votingWindowSeconds / 1 days, 'days');
        console.log('- Max Active Proposals:', params.maxActiveProposals);
        console.log('- Quorum:', params.quorumBps / 100, '%');
        console.log('- Approval Threshold:', params.approvalBps / 100, '%');
        console.log('- Min sToken to Propose:', params.minSTokenBpsToSubmit / 100, '%');
        console.log('- Max Proposal Amount:', params.maxProposalAmountBps / 100, '%');
        console.log('');
        console.log('=== NEXT STEPS ===');
        console.log('1. Verify contracts on block explorer (if applicable)');
        console.log('2. Update UI configuration with factory address');
        console.log('3. Deploy Clanker tokens via UI or separate script');
        console.log('4. Register projects using factory.register()');
        console.log('5. Start governance cycles and test staking flows');
        console.log('');
        console.log('Deployment completed successfully!');
    }
}
