// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from 'forge-std/Script.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../src/LevrDeployer_v1.sol';
import {LevrFeeSplitterFactory_v1} from '../src/LevrFeeSplitterFactory_v1.sol';

/**
 * @title DeployLevr
 * @notice Production deployment script for Levr Protocol v1 on mainnet/testnet
 * @dev Deploys LevrForwarder, LevrDeployer, and LevrFactory with configurable parameters
 *
 * This script integrates with the common.mk deployment system.
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
 * PROTOCOL_FEE_BPS=50
 * STREAM_WINDOW_SECONDS=259200
 *
 * Safety checks:
 * - Validates network is supported (Base mainnet/testnet only)
 * - Locks required gas amount based on current gas price (with 20% buffer)
 * - Verifies deployer has sufficient ETH balance before proceeding
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
    uint16 constant DEFAULT_MAX_REWARD_TOKENS = 50; // Max non-whitelisted reward tokens

    // Estimated gas costs for deployment (conservative estimates)
    uint256 constant ESTIMATED_FORWARDER_GAS = 500_000; // ~0.0005 ETH at 1 gwei
    uint256 constant ESTIMATED_DEPLOYER_GAS = 300_000; // ~0.0003 ETH at 1 gwei
    uint256 constant ESTIMATED_FACTORY_GAS = 3_000_000; // ~0.003 ETH at 1 gwei
    uint256 constant ESTIMATED_FEE_SPLITTER_GAS = 500_000; // ~0.0005 ETH at 1 gwei
    uint256 constant TOTAL_ESTIMATED_GAS =
        ESTIMATED_FORWARDER_GAS +
            ESTIMATED_DEPLOYER_GAS +
            ESTIMATED_FACTORY_GAS +
            ESTIMATED_FEE_SPLITTER_GAS; // ~4.3M gas

    // Minimum ETH balance required (gas estimate * gas price + 20% buffer)
    uint256 constant SAFETY_BUFFER_BPS = 2000; // 20% buffer
    uint256 constant MIN_DEPLOYER_BALANCE = 0.1 ether; // Fallback minimum

    // Deployment parameters struct to avoid stack-too-deep
    struct DeployParams {
        uint256 privateKey;
        address deployer;
        address protocolTreasury;
        address clankerFactory;
        uint16 protocolFeeBps;
        uint32 streamWindowSeconds;
        uint32 proposalWindowSeconds;
        uint32 votingWindowSeconds;
        uint16 maxActiveProposals;
        uint16 quorumBps;
        uint16 approvalBps;
        uint16 minSTokenBpsToSubmit;
        uint16 maxProposalAmountBps;
        uint16 maxRewardTokens;
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
        // Fallback for unsupported chains
        revert('Unsupported chain - no Clanker factory available');
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
        params.maxRewardTokens = vm.envExists('MAX_REWARD_TOKENS')
            ? uint16(vm.envUint('MAX_REWARD_TOKENS'))
            : DEFAULT_MAX_REWARD_TOKENS;
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
            block.chainid == 8453 || block.chainid == 84532,
            'Unsupported network - deploy on Base mainnet (8453) or Base Sepolia (84532)'
        );

        string memory networkName = block.chainid == 8453 ? 'Base Mainnet' : 'Base Sepolia';
        console.log('Network:', networkName);
        console.log('Clanker Factory (auto-selected):', params.clankerFactory);
        console.log('');

        // =======================================================================
        // GAS REQUIREMENT VALIDATION (Lock Required Amount)
        // =======================================================================

        console.log('=== GAS REQUIREMENT VALIDATION ===');

        // Scope for gas calculations to avoid stack-too-deep
        {
            uint256 currentGasPrice = tx.gasprice > 0 ? tx.gasprice : 1 gwei;
            uint256 estimatedCostWei = TOTAL_ESTIMATED_GAS * currentGasPrice;
            uint256 requiredWithBuffer = estimatedCostWei +
                ((estimatedCostWei * SAFETY_BUFFER_BPS) / 10000);
            uint256 requiredBalance = requiredWithBuffer > MIN_DEPLOYER_BALANCE
                ? requiredWithBuffer
                : MIN_DEPLOYER_BALANCE;

            console.log('Current Gas Price:', currentGasPrice / 1 gwei, 'gwei');
            console.log('Estimated Total Gas:', TOTAL_ESTIMATED_GAS);
            console.log('Estimated Cost:', estimatedCostWei / 1e18, 'ETH');
            console.log('Required (with 20% buffer):', requiredBalance / 1e18, 'ETH');
            console.log('Deployer Balance:', params.deployer.balance / 1e18, 'ETH');

            require(
                params.deployer.balance >= requiredBalance,
                string(
                    abi.encodePacked(
                        'Insufficient deployer balance - need at least ',
                        vm.toString(requiredBalance / 1e18),
                        ' ETH'
                    )
                )
            );

            console.log('[OK] Sufficient balance locked for deployment');
            console.log('');
        }

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
            maxRewardTokens: params.maxRewardTokens
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
        console.log('- Max Reward Tokens (non-whitelisted):', config.maxRewardTokens);
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

        // 2. Calculate the factory address before deploying deployer logic
        // The factory will be deployed at nonce = vm.getNonce(params.deployer) + 1
        // (current nonce is after forwarder, +1 for deployer logic, +1 for factory)
        uint64 currentNonce = vm.getNonce(params.deployer);
        address predictedFactory = vm.computeCreateAddress(params.deployer, currentNonce + 1);
        console.log('Predicted Factory Address:', predictedFactory);
        console.log('Current Deployer Nonce:', currentNonce);
        console.log('');

        // 3. Deploy the deployer logic contract with predicted factory address
        console.log('Deploying LevrDeployer_v1...');
        LevrDeployer_v1 levrDeployer = new LevrDeployer_v1(predictedFactory);
        console.log('- Deployer Logic deployed at:', address(levrDeployer));
        console.log('- Authorized Factory:', levrDeployer.authorizedFactory());
        console.log('');

        // 4. Deploy the factory with forwarder and deployer logic
        console.log('Deploying LevrFactory_v1...');
        LevrFactory_v1 factory = new LevrFactory_v1(
            config,
            params.deployer,
            address(forwarder),
            params.clankerFactory,
            address(levrDeployer)
        );
        console.log('- Factory deployed at:', address(factory));

        // Verify the factory was deployed at the predicted address
        require(
            address(factory) == predictedFactory,
            'Factory address mismatch - deployment order changed'
        );
        console.log('- Factory address verified!');
        console.log('');

        // 5. Deploy the fee splitter deployer (creates per-project splitters)
        console.log('Deploying LevrFeeSplitterFactory_v1...');
        LevrFeeSplitterFactory_v1 feeSplitterFactory = new LevrFeeSplitterFactory_v1(
            address(factory),
            address(forwarder)
        );
        console.log('- LevrFeeSplitterFactory_v1:', address(feeSplitterFactory));
        console.log('');

        vm.stopBroadcast();

        // =======================================================================
        // POST-DEPLOYMENT VALIDATION
        // =======================================================================

        console.log('=== DEPLOYMENT VERIFICATION ===');

        // Verify factory configuration
        require(factory.protocolFeeBps() == params.protocolFeeBps, 'Protocol fee BPS mismatch');
        require(
            factory.streamWindowSeconds() == params.streamWindowSeconds,
            'Stream window mismatch'
        );
        require(
            factory.proposalWindowSeconds() == params.proposalWindowSeconds,
            'Proposal window mismatch'
        );
        require(
            factory.votingWindowSeconds() == params.votingWindowSeconds,
            'Voting window mismatch'
        );
        require(
            factory.maxActiveProposals() == params.maxActiveProposals,
            'Max active proposals mismatch'
        );
        require(factory.quorumBps() == params.quorumBps, 'Quorum BPS mismatch');
        require(factory.approvalBps() == params.approvalBps, 'Approval BPS mismatch');
        require(
            factory.minSTokenBpsToSubmit() == params.minSTokenBpsToSubmit,
            'Min sToken BPS mismatch'
        );
        require(
            factory.maxProposalAmountBps() == params.maxProposalAmountBps,
            'Max proposal amount BPS mismatch'
        );
        require(factory.maxRewardTokens() == params.maxRewardTokens, 'Max reward tokens mismatch');
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
        console.log('- Owner (Admin):', params.deployer);
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
