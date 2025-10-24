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
 * - Verifies deployer has sufficient ETH balance
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

    // Minimum ETH balance required for deployment (0.1 ETH)
    uint256 constant MIN_DEPLOYER_BALANCE = 0.1 ether;

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

    function run() external {
        // =======================================================================
        // CONFIGURATION - READ FROM ENVIRONMENT
        // =======================================================================

        uint256 privateKey = vm.envUint('PRIVATE_KEY');
        address deployer = vm.addr(privateKey);

        // Optional: Protocol treasury (defaults to deployer for testing)
        address protocolTreasury = vm.envExists('PROTOCOL_TREASURY')
            ? vm.envAddress('PROTOCOL_TREASURY')
            : deployer;

        // Optional: Configuration parameters with defaults
        uint16 protocolFeeBps = vm.envExists('PROTOCOL_FEE_BPS')
            ? uint16(vm.envUint('PROTOCOL_FEE_BPS'))
            : DEFAULT_PROTOCOL_FEE_BPS;

        uint32 streamWindowSeconds = vm.envExists('STREAM_WINDOW_SECONDS')
            ? uint32(vm.envUint('STREAM_WINDOW_SECONDS'))
            : DEFAULT_STREAM_WINDOW_SECONDS;

        uint32 proposalWindowSeconds = vm.envExists('PROPOSAL_WINDOW_SECONDS')
            ? uint32(vm.envUint('PROPOSAL_WINDOW_SECONDS'))
            : DEFAULT_PROPOSAL_WINDOW_SECONDS;

        uint32 votingWindowSeconds = vm.envExists('VOTING_WINDOW_SECONDS')
            ? uint32(vm.envUint('VOTING_WINDOW_SECONDS'))
            : DEFAULT_VOTING_WINDOW_SECONDS;

        uint16 maxActiveProposals = vm.envExists('MAX_ACTIVE_PROPOSALS')
            ? uint16(vm.envUint('MAX_ACTIVE_PROPOSALS'))
            : DEFAULT_MAX_ACTIVE_PROPOSALS;

        uint16 quorumBps = vm.envExists('QUORUM_BPS')
            ? uint16(vm.envUint('QUORUM_BPS'))
            : DEFAULT_QUORUM_BPS;

        uint16 approvalBps = vm.envExists('APPROVAL_BPS')
            ? uint16(vm.envUint('APPROVAL_BPS'))
            : DEFAULT_APPROVAL_BPS;

        uint16 minSTokenBpsToSubmit = vm.envExists('MIN_STOKEN_BPS_TO_SUBMIT')
            ? uint16(vm.envUint('MIN_STOKEN_BPS_TO_SUBMIT'))
            : DEFAULT_MIN_STOKEN_BPS_TO_SUBMIT;

        uint16 maxProposalAmountBps = vm.envExists('MAX_PROPOSAL_AMOUNT_BPS')
            ? uint16(vm.envUint('MAX_PROPOSAL_AMOUNT_BPS'))
            : DEFAULT_MAX_PROPOSAL_AMOUNT_BPS;

        // =======================================================================
        // PRE-DEPLOYMENT VALIDATION
        // =======================================================================

        console.log('=== LEVR PROTOCOL V1 DEPLOYMENT ===');
        console.log('Network Chain ID:', block.chainid);
        console.log('Deployer Address:', deployer);
        console.log('Deployer Balance:', deployer.balance / 1e18, 'ETH');
        console.log('');

        // Validate network is supported (Base mainnet or Base Sepolia)
        require(
            block.chainid == 8453 || block.chainid == 84532,
            'Unsupported network - deploy on Base mainnet (8453) or Base Sepolia (84532)'
        );

        // Get Clanker factory address for this chain (can be overridden via env)
        address clankerFactory = vm.envExists('CLANKER_FACTORY')
            ? vm.envAddress('CLANKER_FACTORY')
            : getClankerFactory(block.chainid);

        // Display network name
        string memory networkName = block.chainid == 8453 ? 'Base Mainnet' : 'Base Sepolia';
        console.log('Network:', networkName);
        console.log('Clanker Factory (auto-selected):', clankerFactory);

        // Show if protocol treasury is using default
        if (protocolTreasury == deployer) {
            console.log('Protocol Treasury: Using deployer address (default)');
        } else {
            console.log('Protocol Treasury:', protocolTreasury);
        }
        console.log('');

        // Validate deployer has sufficient ETH
        require(
            deployer.balance >= MIN_DEPLOYER_BALANCE,
            'Insufficient deployer balance - need at least 0.1 ETH'
        );

        // Validate configuration parameters
        require(protocolFeeBps <= 10000, 'Protocol fee BPS cannot exceed 100%');
        require(streamWindowSeconds >= 1 days, 'Stream window must be at least 1 day');
        require(proposalWindowSeconds > 0, 'Proposal window must be positive');
        require(votingWindowSeconds > 0, 'Voting window must be positive');
        require(maxActiveProposals > 0, 'Max active proposals must be positive');
        require(quorumBps <= 10000, 'Quorum BPS cannot exceed 100%');
        require(approvalBps <= 10000, 'Approval BPS cannot exceed 100%');
        require(minSTokenBpsToSubmit <= 10000, 'Min sToken BPS cannot exceed 100%');
        require(maxProposalAmountBps <= 10000, 'Max proposal amount BPS cannot exceed 100%');
        require(clankerFactory != address(0), 'Clanker factory cannot be zero address');

        // Build factory configuration
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: protocolFeeBps,
            streamWindowSeconds: streamWindowSeconds,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: proposalWindowSeconds,
            votingWindowSeconds: votingWindowSeconds,
            maxActiveProposals: maxActiveProposals,
            quorumBps: quorumBps,
            approvalBps: approvalBps,
            minSTokenBpsToSubmit: minSTokenBpsToSubmit,
            maxProposalAmountBps: maxProposalAmountBps
        });

        console.log('=== DEPLOYMENT CONFIGURATION ===');
        if (protocolTreasury == deployer) {
            console.log('Protocol Treasury:', protocolTreasury, '(deployer - default)');
        } else {
            console.log('Protocol Treasury:', protocolTreasury, '(custom)');
        }
        console.log('Clanker Factory:', clankerFactory);
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
        console.log('');

        // =======================================================================
        // DEPLOYMENT
        // =======================================================================

        console.log('=== STARTING DEPLOYMENT ===');
        console.log('');

        vm.startBroadcast(privateKey);

        // 1. Deploy the forwarder (includes executeMulticall support)
        console.log('Deploying LevrForwarder_v1...');
        LevrForwarder_v1 forwarder = new LevrForwarder_v1('LevrForwarder_v1');
        console.log('- Forwarder deployed at:', address(forwarder));
        console.log('');

        // 2. Calculate the factory address before deploying deployer logic
        // The factory will be deployed at nonce = vm.getNonce(deployer) + 1
        // (current nonce is after forwarder, +1 for deployer logic, +1 for factory)
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, currentNonce + 1);
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
            deployer,
            address(forwarder),
            clankerFactory,
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
        require(factory.protocolFeeBps() == protocolFeeBps, 'Protocol fee BPS mismatch');
        require(factory.streamWindowSeconds() == streamWindowSeconds, 'Stream window mismatch');
        require(
            factory.proposalWindowSeconds() == proposalWindowSeconds,
            'Proposal window mismatch'
        );
        require(factory.votingWindowSeconds() == votingWindowSeconds, 'Voting window mismatch');
        require(
            factory.maxActiveProposals() == maxActiveProposals,
            'Max active proposals mismatch'
        );
        require(factory.quorumBps() == quorumBps, 'Quorum BPS mismatch');
        require(factory.approvalBps() == approvalBps, 'Approval BPS mismatch');
        require(factory.minSTokenBpsToSubmit() == minSTokenBpsToSubmit, 'Min sToken BPS mismatch');
        require(
            factory.maxProposalAmountBps() == maxProposalAmountBps,
            'Max proposal amount BPS mismatch'
        );
        require(factory.protocolTreasury() == protocolTreasury, 'Protocol treasury mismatch');
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
        console.log('- Owner (Admin):', deployer);
        console.log('- Protocol Treasury:', protocolTreasury);
        console.log('- Clanker Factory:', clankerFactory);
        console.log('- Trusted Forwarder:', address(forwarder));
        console.log('');
        console.log('Governance Parameters:');
        console.log('- Proposal Window:', proposalWindowSeconds / 1 days, 'days');
        console.log('- Voting Window:', votingWindowSeconds / 1 days, 'days');
        console.log('- Max Active Proposals:', maxActiveProposals);
        console.log('- Quorum:', quorumBps / 100, '%');
        console.log('- Approval Threshold:', approvalBps / 100, '%');
        console.log('- Min sToken to Propose:', minSTokenBpsToSubmit / 100, '%');
        console.log('- Max Proposal Amount:', maxProposalAmountBps / 100, '%');
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
