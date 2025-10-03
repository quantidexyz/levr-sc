// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';

contract BaseForkTest is Test {
  uint256 internal forkId;

  // Pin to a specific block for better fork caching
  // Update this block number periodically as needed
  // Block 36000000 is from Oct 2024, after Clanker v4 deployment
  uint256 internal constant FORK_BLOCK_NUMBER = 36000000;

  function setUp() public virtual {
    forkId = _forkBaseMainnet();
    assertEq(block.chainid, 8453, 'Wrong fork chainId');
  }

  function _forkBaseMainnet() internal returns (uint256) {
    string memory url = vm.rpcUrl('base-mainnet');
    // Pin to specific block for deterministic and cacheable fork
    uint256 id = vm.createSelectFork(url, FORK_BLOCK_NUMBER);
    return id;
  }
}
