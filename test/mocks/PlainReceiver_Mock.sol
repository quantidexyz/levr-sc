// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract PlainReceiver_Mock {
    event PlainExecuted(address sender, uint256 value, bytes data);

    function callMe(bytes calldata payload) external payable {
        emit PlainExecuted(msg.sender, msg.value, payload);
    }
}

