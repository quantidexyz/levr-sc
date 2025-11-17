// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from 'forge-std/Script.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';

/// @title Transfer Factory Ownership Script
/// @notice FIX [H-4]: Transfer LevrFactory_v1 ownership to Gnosis Safe multisig
/// @dev Run this after deploying the Gnosis Safe multisig
contract TransferFactoryOwnership is Script {
    function run() external {
        // Load environment variables
        address factoryAddress = vm.envAddress('LEVR_FACTORY_ADDRESS');
        address multisigAddress = vm.envAddress('GNOSIS_SAFE_ADDRESS');

        require(factoryAddress != address(0), 'LEVR_FACTORY_ADDRESS not set');
        require(multisigAddress != address(0), 'GNOSIS_SAFE_ADDRESS not set');

        console2.log('=== Transfer Factory Ownership ===');
        console2.log('Factory:', factoryAddress);
        console2.log('New Owner (Multisig):', multisigAddress);
        console2.log('');

        LevrFactory_v1 factory = LevrFactory_v1(factoryAddress);

        // Verify current owner
        address currentOwner = factory.owner();
        console2.log('Current Owner:', currentOwner);
        console2.log('Deployer:', msg.sender);
        require(currentOwner == msg.sender, 'Caller is not current owner');

        // Start broadcasting transactions
        vm.startBroadcast();

        // Transfer ownership
        console2.log('');
        console2.log('Transferring ownership to multisig...');
        factory.transferOwnership(multisigAddress);

        vm.stopBroadcast();

        // Verify transfer
        address newOwner = factory.owner();
        console2.log('');
        console2.log('Transfer Complete!');
        console2.log('New Owner:', newOwner);

        require(newOwner == multisigAddress, 'Ownership transfer failed');

        console2.log('');
        console2.log('=== SUCCESS ===');
        console2.log('Factory ownership transferred to multisig');
        console2.log('');
        console2.log('Next Steps:');
        console2.log('1. Verify on BaseScan:', factoryAddress);
        console2.log('2. Test multisig by calling a view function');
        console2.log('3. Update spec/MULTISIG.md with signer details');
        console2.log('4. Announce to community');
    }
}

/// @title Deploy Gnosis Safe Helper
/// @notice Helper script to document Gnosis Safe deployment
/// @dev Gnosis Safe should be deployed via https://app.safe.global
contract DeployMultisigHelper is Script {
    function run() external pure {
        console2.log('=== Gnosis Safe Deployment Guide ===');
        console2.log('');
        console2.log('IMPORTANT: Deploy Gnosis Safe via official interface');
        console2.log('URL: https://app.safe.global/');
        console2.log('');
        console2.log('Configuration:');
        console2.log('  Network: Base Mainnet (Chain ID: 8453)');
        console2.log('  Threshold: 3');
        console2.log('  Signers: 5');
        console2.log('');
        console2.log('Steps:');
        console2.log('1. Connect wallet to Base Mainnet');
        console2.log('2. Go to https://app.safe.global/');
        console2.log('3. Click "Create New Safe"');
        console2.log('4. Add 5 signer addresses');
        console2.log('5. Set threshold to 3');
        console2.log('6. Review and deploy');
        console2.log('7. Save the Safe address');
        console2.log('');
        console2.log('After deployment:');
        console2.log('  export GNOSIS_SAFE_ADDRESS=<your-safe-address>');
        console2.log('  export LEVR_FACTORY_ADDRESS=<factory-address>');
        console2.log('');
        console2.log('Then run:');
        console2.log('  forge script script/TransferFactoryOwnership.s.sol \\');
        console2.log('    --rpc-url $BASE_RPC_URL \\');
        console2.log('    --broadcast \\');
        console2.log('    --verify');
        console2.log('');
    }
}
