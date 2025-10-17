// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from 'forge-std/Script.sol';
import {LevrFeeSplitter_v1} from '../src/LevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';

/**
 * @title DeployLevrFeeSplitter
 * @notice Production deployment script for LevrFeeSplitter_v1 singleton
 * @dev Deploys the singleton fee splitter contract that manages fee distribution for all Clanker projects
 *
 * This script integrates with the common.mk deployment system.
 *
 * Usage:
 * 1. Set environment variables in .env file:
 *    MAINNET_PRIVATE_KEY=0x...  # For mainnet
 *    TESTNET_PRIVATE_KEY=0x...  # For testnet
 *    FACTORY_ADDRESS=0x...      # Required: Deployed LevrFactory_v1 address
 *    TRUSTED_FORWARDER=0x...    # Optional: Auto-detected from factory if not provided
 *
 * 2. Run deployment:
 *    make deploy  # Interactive menu will include "LevrFeeSplitter"
 *
 * Environment Variables (Required):
 * - PRIVATE_KEY: Deployment key (auto-selected by common.mk based on network)
 * - FACTORY_ADDRESS: Address of deployed LevrFactory_v1 contract
 *
 * Environment Variables (Optional):
 * - TRUSTED_FORWARDER: Address of trusted forwarder (default: queried from factory)
 *
 * Example .env:
 * MAINNET_PRIVATE_KEY=0xabcd...
 * TESTNET_PRIVATE_KEY=0xef01...
 * FACTORY_ADDRESS=0x1234...
 * # TRUSTED_FORWARDER=0x5678...  # Optional, auto-detected
 *
 * Safety checks:
 * - Verifies deployer has sufficient ETH balance
 * - Validates factory address exists and is a contract
 * - Confirms trusted forwarder is valid
 * - Tests basic fee splitter functionality
 * - Outputs deployed address for verification
 *
 * Architecture:
 * The LevrFeeSplitter_v1 is a SINGLETON contract that:
 * - Manages fee distribution for ALL Clanker projects
 * - Each project configures its own splits (identified by clankerToken address)
 * - Only token admins can configure splits for their projects
 * - Anyone can trigger permissionless distribution
 * - Supports meta-transactions via trusted forwarder
 */
contract DeployLevrFeeSplitter is Script {
    // Minimum ETH balance required for deployment (0.05 ETH)
    uint256 constant MIN_DEPLOYER_BALANCE = 0.05 ether;

    function run() external {
        // =======================================================================
        // CONFIGURATION - READ FROM ENVIRONMENT
        // =======================================================================

        uint256 privateKey = vm.envUint('PRIVATE_KEY');
        address deployer = vm.addr(privateKey);

        // Required: Factory address
        require(vm.envExists('FACTORY_ADDRESS'), 'FACTORY_ADDRESS environment variable required');
        address factoryAddress = vm.envAddress('FACTORY_ADDRESS');

        console.log('=== LEVR FEE SPLITTER V1 DEPLOYMENT ===');
        console.log('Network Chain ID:', block.chainid);
        console.log('Deployer Address:', deployer);
        console.log('Deployer Balance:', deployer.balance / 1e18, 'ETH');
        console.log('');

        // =======================================================================
        // PRE-DEPLOYMENT VALIDATION
        // =======================================================================

        console.log('=== PRE-DEPLOYMENT VALIDATION ===');

        // Validate network is supported (Base mainnet or Base Sepolia)
        require(
            block.chainid == 8453 || block.chainid == 84532,
            'Unsupported network - deploy on Base mainnet (8453) or Base Sepolia (84532)'
        );

        // Display network name
        string memory networkName = block.chainid == 8453 ? 'Base Mainnet' : 'Base Sepolia';
        console.log('Network:', networkName);
        console.log('');

        // Validate deployer has sufficient ETH
        require(
            deployer.balance >= MIN_DEPLOYER_BALANCE,
            'Insufficient deployer balance - need at least 0.05 ETH'
        );
        console.log('[OK] Deployer has sufficient ETH balance');

        // Validate factory address is a contract
        require(factoryAddress != address(0), 'Factory address cannot be zero');
        uint256 factoryCodeSize;
        assembly {
            factoryCodeSize := extcodesize(factoryAddress)
        }
        require(factoryCodeSize > 0, 'Factory address is not a contract');
        console.log('[OK] Factory address is a valid contract:', factoryAddress);

        // Query trusted forwarder from factory (or use override)
        address trustedForwarder;
        if (vm.envExists('TRUSTED_FORWARDER')) {
            trustedForwarder = vm.envAddress('TRUSTED_FORWARDER');
            console.log('[INFO] Using provided trusted forwarder (override):', trustedForwarder);
        } else {
            // Query from factory
            try ILevrFactory_v1(factoryAddress).trustedForwarder() returns (address forwarder) {
                trustedForwarder = forwarder;
                console.log('[OK] Trusted forwarder queried from factory:', trustedForwarder);
            } catch {
                revert('Failed to query trusted forwarder from factory - verify factory address');
            }
        }

        // Validate trusted forwarder
        require(trustedForwarder != address(0), 'Trusted forwarder cannot be zero');
        uint256 forwarderCodeSize;
        assembly {
            forwarderCodeSize := extcodesize(trustedForwarder)
        }
        require(forwarderCodeSize > 0, 'Trusted forwarder is not a contract');
        console.log('[OK] Trusted forwarder is a valid contract');

        console.log('');

        // =======================================================================
        // DEPLOYMENT CONFIGURATION SUMMARY
        // =======================================================================

        console.log('=== DEPLOYMENT CONFIGURATION ===');
        console.log('Factory Address:', factoryAddress);
        console.log('Trusted Forwarder:', trustedForwarder);
        console.log('Deployer:', deployer);
        console.log('');
        console.log('Fee Splitter Details:');
        console.log('- Type: Singleton (manages all projects)');
        console.log('- Access Control: Per-project (token admin only)');
        console.log('- Distribution: Permissionless (anyone can trigger)');
        console.log('- Meta-transactions: Enabled (via trusted forwarder)');
        console.log('');

        // =======================================================================
        // DEPLOYMENT
        // =======================================================================

        console.log('=== STARTING DEPLOYMENT ===');
        console.log('');

        vm.startBroadcast(privateKey);

        // Deploy the singleton fee splitter
        console.log('Deploying LevrFeeSplitter_v1...');
        LevrFeeSplitter_v1 feeSplitter = new LevrFeeSplitter_v1(factoryAddress, trustedForwarder);
        console.log('- Fee Splitter deployed at:', address(feeSplitter));
        console.log('');

        vm.stopBroadcast();

        // =======================================================================
        // POST-DEPLOYMENT VALIDATION
        // =======================================================================

        console.log('=== DEPLOYMENT VERIFICATION ===');

        // Verify factory configuration
        require(
            feeSplitter.factory() == factoryAddress,
            'Factory address mismatch in deployed contract'
        );
        console.log('[OK] Factory address verified:', feeSplitter.factory());

        // Verify the fee splitter is functional (basic test)
        // Check that isSplitsConfigured returns false for a random address
        address randomToken = address(0x1234567890123456789012345678901234567890);
        bool isConfigured = feeSplitter.isSplitsConfigured(randomToken);
        require(!isConfigured, 'Unexpected initial state - random token should not be configured');
        console.log('[OK] Basic functionality test passed');

        console.log('[OK] All deployment checks passed!');
        console.log('');

        // =======================================================================
        // DEPLOYMENT SUMMARY
        // =======================================================================

        console.log('=== DEPLOYMENT SUCCESSFUL ===');
        console.log('');
        console.log('Deployed Contract:');
        console.log('- LevrFeeSplitter_v1:', address(feeSplitter));
        console.log('');
        console.log('Configuration:');
        console.log('- Factory:', factoryAddress);
        console.log('- Trusted Forwarder:', trustedForwarder);
        console.log('- Network:', networkName);
        console.log('');

        // =======================================================================
        // USAGE INSTRUCTIONS
        // =======================================================================

        console.log('=== USAGE INSTRUCTIONS ===');
        console.log('');
        console.log('The LevrFeeSplitter_v1 singleton is now deployed!');
        console.log('');
        console.log('For Token Admins (per-project configuration):');
        console.log('');
        console.log('1. Configure splits for your project:');
        console.log('   feeSplitter.configureSplits(clankerToken, splits)');
        console.log('   - splits must sum to 10,000 bps (100%)');
        console.log('   - Only token admin can configure');
        console.log('   - Can reconfigure at any time');
        console.log('');
        console.log('2. Update LP locker reward recipient:');
        console.log('   IClankerLpLockerMultiple(lpLocker).updateRewardRecipient(');
        console.log('     clankerToken,');
        console.log('     0, // reward index');
        console.log('     address(feeSplitter)');
        console.log('   )');
        console.log('');
        console.log('For Users (permissionless distribution):');
        console.log('');
        console.log('1. Distribute single token fees:');
        console.log('   feeSplitter.distribute(clankerToken, rewardToken)');
        console.log('');
        console.log('2. Distribute multiple tokens (batch):');
        console.log('   feeSplitter.distributeBatch(clankerToken, [WETH, token])');
        console.log('');
        console.log('3. After distribution to staking, trigger manual accrual:');
        console.log('   ILevrStaking_v1(staking).accrueRewards(rewardToken)');
        console.log('');
        console.log('View Functions:');
        console.log('- feeSplitter.getSplits(clankerToken)');
        console.log('- feeSplitter.isSplitsConfigured(clankerToken)');
        console.log('- feeSplitter.pendingFees(clankerToken, rewardToken)');
        console.log('- feeSplitter.getStakingAddress(clankerToken)');
        console.log('');

        // =======================================================================
        // INTEGRATION EXAMPLES
        // =======================================================================

        console.log('=== INTEGRATION EXAMPLES ===');
        console.log('');
        console.log('Example 1: Configure 50/50 split (staking/team)');
        console.log('');
        console.log('  SplitConfig[] memory splits = new SplitConfig[](2);');
        console.log('  splits[0] = SplitConfig({');
        console.log('    receiver: stakingAddress,');
        console.log('    bps: 5000  // 50%');
        console.log('  });');
        console.log('  splits[1] = SplitConfig({');
        console.log('    receiver: teamWallet,');
        console.log('    bps: 5000  // 50%');
        console.log('  });');
        console.log('  feeSplitter.configureSplits(clankerToken, splits);');
        console.log('');
        console.log('Example 2: Batch distribute WETH + Clanker token fees');
        console.log('');
        console.log('  address[] memory tokens = new address[](2);');
        console.log('  tokens[0] = WETH;');
        console.log('  tokens[1] = clankerToken;');
        console.log('  feeSplitter.distributeBatch(clankerToken, tokens);');
        console.log('');

        // =======================================================================
        // NEXT STEPS
        // =======================================================================

        console.log('=== NEXT STEPS ===');
        console.log('');
        console.log('1. Verify contract on block explorer:');
        console.log('   - Contract:', address(feeSplitter));
        console.log('   - Network:', networkName);
        console.log('');
        console.log('2. Update frontend configuration:');
        console.log('   - Add FEE_SPLITTER_ADDRESS to environment');
        console.log('   - Integrate fee splitter UI for token admins');
        console.log('   - Add distribution triggers for users');
        console.log('');
        console.log('3. Document for projects:');
        console.log('   - How to configure splits');
        console.log('   - How to update reward recipient');
        console.log('   - How distributions work');
        console.log('');
        console.log('4. Test with a project:');
        console.log('   - Deploy test Clanker token');
        console.log('   - Configure test splits');
        console.log('   - Verify distribution works correctly');
        console.log('');
        console.log('Deployment completed successfully!');
        console.log('');
    }
}
