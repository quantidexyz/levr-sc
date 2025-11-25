// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';

/// @notice Contract that attempts to reenter the forwarder while being called via executeTransaction
contract ReentrantAttacker_Mock {
    ILevrForwarder_v1 public immutable forwarder;

    constructor(ILevrForwarder_v1 forwarder_) {
        forwarder = forwarder_;
    }

    function attack() external {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](0);
        forwarder.executeMulticall(calls);
    }
}
