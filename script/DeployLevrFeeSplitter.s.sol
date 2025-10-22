// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from 'forge-std/Script.sol';
import {LevrFeeSplitterDeployer_v1} from '../src/LevrFeeSplitterDeployer_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';

/**
 * @title DeployLevrFeeSplitter
 * @notice Production deployment script for LevrFeeSplitterDeployer_v1
 * @dev Deploys the fee splitter DEPLOYER that creates per-project fee splitters
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
 * - Tests basic deployer functionality
 * - Outputs deployed address for verification
 *
 * Architecture:
 * The LevrFeeSplitterDeployer_v1 is a DEPLOYER contract that:
 * - Creates dedicated fee splitters for each project
 * - Each project gets its own isolated fee splitter instance
 * - Prevents token mixing between projects (solves WETH/USDC collision)
 * - Supports deterministic deployment via CREATE2
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

        console.log('=== LEVR FEE SPLITTER DEPLOYER V1 DEPLOYMENT ===');
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
        console.log('Fee Splitter Deployer Details:');
        console.log('- Type: Deployer (creates per-project splitters)');
        console.log('- Architecture: One splitter per project (isolated balances)');
        console.log('- Access Control: Per-project (token admin only)');
        console.log('- Distribution: Permissionless (anyone can trigger)');
        console.log('- Meta-transactions: Enabled (via trusted forwarder)');
        console.log('- CREATE2 Support: Yes (deterministic addresses)');
        console.log('');

        // =======================================================================
        // DEPLOYMENT
        // =======================================================================

        console.log('=== STARTING DEPLOYMENT ===');
        console.log('');

        vm.startBroadcast(privateKey);

        // Deploy the fee splitter deployer
        console.log('Deploying LevrFeeSplitterDeployer_v1...');
        LevrFeeSplitterDeployer_v1 feeSplitterDeployer = new LevrFeeSplitterDeployer_v1(
            factoryAddress,
            trustedForwarder
        );
        console.log('- Fee Splitter Deployer deployed at:', address(feeSplitterDeployer));
        console.log('');

        vm.stopBroadcast();

        // =======================================================================
        // POST-DEPLOYMENT VALIDATION
        // =======================================================================

        console.log('=== DEPLOYMENT VERIFICATION ===');

        // Verify factory configuration
        require(
            feeSplitterDeployer.factory() == factoryAddress,
            'Factory address mismatch in deployed contract'
        );
        console.log('[OK] Factory address verified:', feeSplitterDeployer.factory());

        // Verify trusted forwarder
        require(
            feeSplitterDeployer.trustedForwarder() == trustedForwarder,
            'Trusted forwarder mismatch in deployed contract'
        );
        console.log('[OK] Trusted forwarder verified:', feeSplitterDeployer.trustedForwarder());

        // Verify the deployer is functional (basic test)
        // Check that getSplitter returns zero for a random address
        address randomToken = address(0x1234567890123456789012345678901234567890);
        address splitter = feeSplitterDeployer.getSplitter(randomToken);
        require(
            splitter == address(0),
            'Unexpected initial state - random token should not have splitter'
        );
        console.log('[OK] Basic functionality test passed');

        console.log('[OK] All deployment checks passed!');
        console.log('');

        // =======================================================================
        // DEPLOYMENT SUMMARY
        // =======================================================================

        console.log('=== DEPLOYMENT SUCCESSFUL ===');
        console.log('');
        console.log('Deployed Contract:');
        console.log('- LevrFeeSplitterDeployer_v1:', address(feeSplitterDeployer));
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
        console.log('The LevrFeeSplitterDeployer_v1 is now deployed!');
        console.log('');
        console.log('Step 1: Deploy Fee Splitter for Your Project');
        console.log('');
        console.log('  // Deploy splitter for your Clanker token');
        console.log('  address splitter = deployer.deploy(clankerToken);');
        console.log('');
        console.log('  // Or use CREATE2 for deterministic address');
        console.log('  bytes32 salt = keccak256("my-project");');
        console.log('  address splitter = deployer.deployDeterministic(clankerToken, salt);');
        console.log('');
        console.log('Step 2: Configure Splits (Token Admin Only)');
        console.log('');
        console.log('  LevrFeeSplitter_v1(splitter).configureSplits([');
        console.log('    SplitConfig(stakingAddress, 8000),  // 80% to staking');
        console.log('    SplitConfig(treasuryAddress, 2000)  // 20% to treasury');
        console.log('  ]);');
        console.log('');
        console.log('Step 3: Update LP Locker Reward Recipient');
        console.log('');
        console.log('  IClankerLpLockerMultiple(lpLocker).updateRewardRecipient(');
        console.log('    clankerToken,');
        console.log('    0, // reward index');
        console.log("    address(splitter)  // Your project's splitter");
        console.log('  );');
        console.log('');
        console.log('Step 4: Distribute Fees (Anyone Can Call)');
        console.log('');
        console.log('  // Single token distribution');
        console.log('  LevrFeeSplitter_v1(splitter).distribute(WETH);');
        console.log('');
        console.log('  // Batch distribution (gas efficient)');
        console.log('  LevrFeeSplitter_v1(splitter).distributeBatch([WETH, token]);');
        console.log('');
        console.log('View Functions:');
        console.log('- deployer.getSplitter(clankerToken)');
        console.log('- deployer.computeDeterministicAddress(clankerToken, salt)');
        console.log('- splitter.getSplits()');
        console.log('- splitter.isSplitsConfigured()');
        console.log('- splitter.pendingFees(rewardToken)');
        console.log('- splitter.pendingFeesInclBalance(rewardToken)');
        console.log('');

        // =======================================================================
        // INTEGRATION EXAMPLES
        // =======================================================================

        console.log('=== INTEGRATION EXAMPLES ===');
        console.log('');
        console.log('Example 1: Complete Setup Flow');
        console.log('');
        console.log('  // 1. Deploy fee splitter for project');
        console.log('  address splitter = deployer.deploy(clankerToken);');
        console.log('');
        console.log('  // 2. Configure splits');
        console.log('  SplitConfig[] memory splits = new SplitConfig[](2);');
        console.log('  splits[0] = SplitConfig(stakingAddress, 7000); // 70%');
        console.log('  splits[1] = SplitConfig(teamWallet, 3000);     // 30%');
        console.log('  LevrFeeSplitter_v1(splitter).configureSplits(splits);');
        console.log('');
        console.log('  // 3. Update LP locker to use splitter');
        console.log('  lpLocker.updateRewardRecipient(clankerToken, 0, splitter);');
        console.log('');
        console.log('Example 2: Deterministic Deployment + Multicall');
        console.log('');
        console.log('  // Predict address');
        console.log('  bytes32 salt = keccak256("my-project");');
        console.log('  address predicted = deployer.computeDeterministicAddress(');
        console.log('    clankerToken,');
        console.log('    salt');
        console.log('  );');
        console.log('');
        console.log('  // Deploy + configure in ONE transaction via forwarder multicall');
        console.log('  SingleCall[] memory calls = new SingleCall[](2);');
        console.log('  calls[0] = SingleCall({');
        console.log('    target: address(deployer),');
        console.log('    allowFailure: false,');
        console.log(
            '    callData: abi.encodeCall(deployer.deployDeterministic, (clankerToken, salt))'
        );
        console.log('  });');
        console.log('  calls[1] = SingleCall({');
        console.log('    target: predicted,');
        console.log('    allowFailure: false,');
        console.log('    callData: abi.encodeCall(LevrFeeSplitter_v1.configureSplits, (splits))');
        console.log('  });');
        console.log('  forwarder.executeMulticall(calls);');
        console.log('');

        // =======================================================================
        // NEXT STEPS
        // =======================================================================

        console.log('=== NEXT STEPS ===');
        console.log('');
        console.log('1. Verify contract on block explorer:');
        console.log('   - Contract:', address(feeSplitterDeployer));
        console.log('   - Network:', networkName);
        console.log('');
        console.log('2. Update frontend configuration:');
        console.log('   - Add FEE_SPLITTER_DEPLOYER_ADDRESS to environment');
        console.log('   - Integrate deployer UI for project setup');
        console.log('   - Add fee splitter management UI per project');
        console.log('');
        console.log('3. Document for projects:');
        console.log('   - How to deploy their fee splitter');
        console.log('   - How to configure splits');
        console.log('   - How to update reward recipient');
        console.log('   - How distributions work');
        console.log('');
        console.log('4. Test with a project:');
        console.log('   - Deploy test Clanker token');
        console.log('   - Deploy fee splitter via deployer');
        console.log('   - Configure test splits');
        console.log('   - Verify distribution works correctly');
        console.log('');
        console.log('Deployment completed successfully!');
        console.log('');
    }
}
