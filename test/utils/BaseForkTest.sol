// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

contract BaseForkTest is Test {
    uint256 internal forkId;

    function setUp() public virtual {
        forkId = _forkBaseMainnet();
        assertEq(block.chainid, 8453, "Wrong fork chainId");
    }

    function _forkBaseMainnet() internal returns (uint256) {
        string memory url = vm.rpcUrl("base-mainnet");
        uint256 id = vm.createSelectFork(url);
        return id;
    }
}
