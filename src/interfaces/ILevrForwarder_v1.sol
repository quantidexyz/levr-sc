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
  /// @param callData Encoded function call data
  struct SingleCall {
    address target;
    bool allowFailure;
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

  // ============ Functions ============

  /// @notice Execute multiple calls in a single transaction
  /// @dev Each call is executed with the caller's address appended (ERC2771)
  ///      Only calls to contracts that trust this forwarder will succeed
  /// @param calls Array of calls to execute
  /// @return results Array of results for each call
  function executeMulticall(SingleCall[] calldata calls) external returns (Result[] memory results);

  /// @notice Create a digest for signing a forward request
  /// @param req The forward request data
  /// @return digest The EIP-712 digest to sign
  function createDigest(
    ERC2771Forwarder.ForwardRequestData memory req
  ) external view returns (bytes32 digest);
}

