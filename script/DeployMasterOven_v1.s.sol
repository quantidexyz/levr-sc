// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from 'forge-std/Script.sol';
import {MasterOven_v1} from '../src/MasterOven_v1.sol';

/**
 * @title DeployInfoFiVault
 * @notice Deployment script for MasterOven_v1 contract
 * @dev Run with: PRIVATE_KEY=$PRIVATE_KEY forge script script/DeployMasterOven_v1.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployMasterOven_v1 is Script {
  function run() external {
    // Read private key from environment variable
    uint256 privateKey = vm.envUint('PRIVATE_KEY');
    address deployer = vm.addr(privateKey);

    // Read treasury address from environment variable or use deployer address
    address treasury = vm.envOr('TREASURY_ADDRESS', deployer);

    console.log('Deploying MasterOven_v1...');
    console.log('Treasury address:', treasury);
    console.log('Deployer address:', deployer);

    vm.startBroadcast(privateKey);

    MasterOven_v1 vault = new MasterOven_v1(treasury);

    vm.stopBroadcast();

    console.log('MasterOven_v1 deployed at:', address(vault));
    console.log(
      'Deployer is Super Admin:',
      vault.isSuperAdminAddress(deployer)
    );
    console.log('Super Admin Count:', vault.superAdminCount());
    console.log('Treasury:', vault.treasury());
    console.log(
      'Available duration options: ONE_WEEK (7 days), TWO_WEEKS (14 days), ONE_MONTH (30 days)'
    );
  }
}
