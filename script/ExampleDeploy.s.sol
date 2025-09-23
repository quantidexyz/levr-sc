// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

/**
 * @title ExampleDeploy
 * @notice Generic deployment script that can be adapted for any contract
 * @dev This is an example template for deploying contracts. Customize the contract import and constructor call as needed.
 *
 * Environment Variables:
 * - CONTRACT_NAME: Name of the contract to deploy (optional, defaults to "ExampleContract")
 * - PRIVATE_KEY: Private key for deployment (required)
 * - TREASURY_ADDRESS: Treasury address (optional, defaults to deployer)
 * - RPC_URL: RPC URL for the network (passed to forge script)
 *
 * Example Usage:
 * PRIVATE_KEY=$PRIVATE_KEY forge script script/ExampleDeploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 *
 * To customize for your contract:
 * 1. Import your contract at the top
 * 2. Modify the deployment logic in the run() function
 * 3. Update constructor arguments as needed
 * 4. Add contract-specific validation and logging
 */

// Import your contract here - replace with your actual contract
// import {YourContract} from '../src/YourContract.sol';

contract ExampleDeploy is Script {
    function run() external {
        // Read deployment configuration from environment variables
        string memory contractName;
        if (vm.envExists("CONTRACT_NAME")) {
            contractName = vm.envString("CONTRACT_NAME");
        } else {
            contractName = "ExampleContract";
        }
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        // Optional parameters - customize based on your contract's needs
        address treasury;
        if (vm.envExists("TREASURY_ADDRESS")) {
            treasury = vm.envAddress("TREASURY_ADDRESS");
        } else {
            treasury = deployer;
        }

        console.log("Starting deployment...");
        console.log("Contract Name:", contractName);
        console.log("Deployer Address:", deployer);
        console.log("Treasury Address:", treasury);
        console.log("Network:", block.chainid);

        vm.startBroadcast(privateKey);

        // =======================================================================
        // CONTRACT DEPLOYMENT - MODIFY THIS SECTION FOR YOUR CONTRACT
        // =======================================================================

        // Example deployment - replace with your actual contract deployment
        // YourContract yourContract = new YourContract(treasury);
        // For demonstration, we'll deploy a simple example contract
        // Remove this and replace with your actual deployment logic

        address deployedContract;

        // Placeholder deployment - replace with actual contract
        // deployedContract = address(yourContract);

        // =======================================================================
        // END CONTRACT DEPLOYMENT SECTION
        // =======================================================================

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Contract deployed at:", deployedContract);
        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);

        // =======================================================================
        // CONTRACT-SPECIFIC VALIDATION - ADD YOUR VALIDATION LOGIC HERE
        // =======================================================================

        // Example validation - replace with checks specific to your contract
        // console.log('Contract owner:', yourContract.owner());
        // console.log('Contract initialized:', yourContract.initialized());

        // =======================================================================
        // END VALIDATION SECTION
        // =======================================================================

        console.log("");
        console.log("Deployment completed successfully!");
        console.log("Verify the contract on your preferred block explorer.");
    }
}
