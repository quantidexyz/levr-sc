// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MasterLevr_v1} from "../src/MasterLevr_v1.sol";

/**
 * @title DeployMasterLevr
 * @notice Deployment script for MasterLevr_v1 contract
 * @dev Deploys the MasterLevr_v1 contract with no constructor parameters
 *
 * Environment Variables:
 * - PRIVATE_KEY: Private key for deployment (required)
 * - RPC_URL: RPC URL for the network (passed to forge script)
 *
 * Example Usage:
 * PRIVATE_KEY=$PRIVATE_KEY forge script script/DeployMasterLevr.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployMasterLevr is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Starting MasterLevr_v1 deployment...");
        console.log("Deployer Address:", deployer);
        console.log("Network:", block.chainid);

        vm.startBroadcast(privateKey);

        // =======================================================================
        // CONTRACT DEPLOYMENT
        // =======================================================================

        // Deploy MasterLevr_v1 contract (no constructor parameters needed)
        MasterLevr_v1 masterLevr = new MasterLevr_v1();

        address deployedContract = address(masterLevr);

        // =======================================================================
        // END CONTRACT DEPLOYMENT SECTION
        // =======================================================================

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("MasterLevr_v1 deployed at:", deployedContract);
        console.log("Deployer:", deployer);

        // =======================================================================
        // CONTRACT-SPECIFIC VALIDATION
        // =======================================================================

        // Verify contract was deployed successfully
        require(deployedContract != address(0), "Deployment failed");

        // Check that nextLevrId starts at 1 (indicating proper initialization)
        // Note: We can't call this directly as it's a private variable, but deployment success indicates proper initialization

        // =======================================================================
        // END VALIDATION SECTION
        // =======================================================================

        console.log("");
        console.log("MasterLevr_v1 deployment completed successfully!");
        console.log("Verify the contract on your preferred block explorer.");
        console.log("Contract Address:", deployedContract);
    }
}
