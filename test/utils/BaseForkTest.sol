// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

contract BaseForkTest is Test {
    uint256 internal forkId;

    function setUp() public virtual {
        forkId = _forkBaseSepolia();
        assertEq(block.chainid, 84532, "Wrong fork chainId");
    }

    function _forkBaseSepolia() internal returns (uint256) {
        string memory url = vm.rpcUrl("base-sepolia");
        uint256 id = vm.createSelectFork(url);
        return id;
    }
}
