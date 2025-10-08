// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';

/// @title Levr Forwarder v1 Interface
/// @notice Meta-transaction forwarder with multicall support for Levr Protocol
interface ILevrForwarder_v1 {
    // ============ Structs ============

    /// @notice Struct for a single call in a multicall sequence
    /// @param target Target contract to call
    /// @param allowFailure Whether the call is allowed to fail
    /// @param value Amount of ETH to send with the call
    /// @param callData Encoded function call data
    struct SingleCall {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    /// @notice Result of a single call in multicall
    /// @param success Whether the call succeeded
    /// @param returnData Return data from the call
    struct Result {
        bool success;
        bytes returnData;
    }

    // ============ Errors ============

    /// @notice Call failed and was not allowed to fail
    /// @param call The call that failed
    error CallFailed(SingleCall call);

    /// @notice Attempted to call a forbidden function selector on the forwarder itself
    /// @param selector The forbidden function selector
    error ForbiddenSelectorOnSelf(bytes4 selector);

    // ============ Functions ============

    /// @notice Execute multiple calls in a single transaction (ERC2771 mode)
    /// @dev Each call is executed with the caller's address appended (ERC2771)
    ///      Only calls to contracts that trust this forwarder will succeed
    ///      Forwards all msg.value to the calls
    /// @param calls Array of calls to execute
    /// @return results Array of results for each call
    function executeMulticall(
        SingleCall[] calldata calls
    ) external payable returns (Result[] memory results);

    /// @notice Execute a single transaction to any external contract
    /// @dev Executes call FROM the forwarder without appending sender (non-ERC2771)
    ///      Useful for calling external contracts that don't use ERC2771
    ///      Does NOT require target to trust this forwarder
    /// @param target The contract to call
    /// @param data The calldata to send
    /// @return success Whether the call succeeded
    /// @return returnData The return data from the call
    function executeTransaction(
        address target,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData);

    /// @notice Create a digest for signing a forward request
    /// @param req The forward request data
    /// @return digest The EIP-712 digest to sign
    function createDigest(
        ERC2771Forwarder.ForwardRequestData memory req
    ) external view returns (bytes32 digest);
}
