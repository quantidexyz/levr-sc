// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from 'forge-std/Script.sol';
import {TipOven_v1} from '../src/TipOven_v1.sol';

/**
 * @title DeployTipOven_v1
 * @notice Deployment script for TipOven_v1 contract
 * @dev Run with:
 * PRIVATE_KEY=$PRIVATE_KEY forge script script/DeployTipOven_v1.s.sol \
 *   --rpc-url $RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast
 */
contract DeployTipOven_v1 is Script {
  function run() external {
    uint256 privateKey = vm.envUint('PRIVATE_KEY');
    address deployer = vm.addr(privateKey);

    address treasury = vm.envOr('TREASURY_ADDRESS', deployer);

    console.log('Deploying TipOven_v1...');
    console.log('Treasury address:', treasury);
    console.log('Deployer address:', deployer);

    vm.startBroadcast(privateKey);

    TipOven_v1 oven = new TipOven_v1(treasury);

    vm.stopBroadcast();

    console.log('TipOven_v1 deployed at:', address(oven));
    console.log('Deployer is Super Admin:', oven.isSuperAdminAddress(deployer));
    console.log('Super Admin Count:', oven.superAdminCount());
    console.log('Treasury:', oven.treasury());
    console.log('Fee Percentage (bps):', oven.feePercentage());
  }
}
