// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';

/// @notice Helper contract whose receive hook always reverts, used to test ETHTransferFailed
contract RejectingReceiver_Mock {
    LevrForwarder_v1 public lastForwarder;

    /// @notice Deploys a forwarder with this contract recorded as deployer
    function deployForwarder(string memory name) external returns (LevrForwarder_v1) {
        lastForwarder = new LevrForwarder_v1(name);
        return lastForwarder;
    }

    /// @notice Calls withdrawTrappedETH on the provided forwarder
    function triggerWithdraw(LevrForwarder_v1 forwarder) external {
        forwarder.withdrawTrappedETH();
    }

    receive() external payable {
        revert('RejectingReceiver: cannot receive ETH');
    }
}
