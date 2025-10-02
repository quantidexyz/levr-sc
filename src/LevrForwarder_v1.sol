// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
import {ERC2771Context} from '@openzeppelin/contracts/metatx/ERC2771Context.sol';
import {Context} from '@openzeppelin/contracts/utils/Context.sol';
import {ILevrForwarder_v1} from './interfaces/ILevrForwarder_v1.sol';

/**
 * @title LevrForwarder_v1
 * @notice Meta-transaction forwarder with multicall support for Levr Protocol
 * @dev Extends OpenZeppelin's ERC2771Forwarder and adds executeMulticall functionality
 *      Based on Inverter's TransactionForwarder_v1 pattern
 */
contract LevrForwarder_v1 is ILevrForwarder_v1, ERC2771Forwarder {
  constructor(string memory name) ERC2771Forwarder(name) {}

  /// @inheritdoc ILevrForwarder_v1
  function executeMulticall(SingleCall[] calldata calls) external returns (Result[] memory results) {
    uint256 length = calls.length;
    results = new Result[](length);

    SingleCall calldata calli;
    bytes memory data;

    // Execute each call in sequence
    for (uint256 i = 0; i < length; i++) {
      calli = calls[i];

      // Check if the target trusts this forwarder
      if (!_isTrustedByTarget(calli.target)) {
        revert ERC2771UntrustfulTarget(calli.target, address(this));
      }

      // Append the real caller's address to calldata
      // This will be extracted by ERC2771Context in the target contract
      data = abi.encodePacked(calli.callData, msg.sender);

      // Execute the call
      (bool success, bytes memory returnData) = calli.target.call(data);

      // Check if failure is allowed
      if (!success && !calli.allowFailure) {
        revert CallFailed(calli);
      }

      // Store result
      results[i] = Result(success, returnData);
    }
  }

  /// @inheritdoc ILevrForwarder_v1
  function createDigest(ERC2771Forwarder.ForwardRequestData memory req) external view returns (bytes32 digest) {
    return _hashTypedDataV4(_getStructHash(req));
  }

  // ============ Internal Functions ============

  /// @notice Check if a target contract trusts this forwarder
  /// @param target The contract to check
  /// @return Whether the target trusts this forwarder
  /// @dev Override the internal function from ERC2771Forwarder to make it accessible
  function _isTrustedByTarget(address target) internal view override returns (bool) {
    return super._isTrustedByTarget(target);
  }

  /// @notice Get the struct hash for EIP-712 signing
  /// @param req The forward request data
  /// @return The keccak256 hash of the encoded request
  function _getStructHash(ERC2771Forwarder.ForwardRequestData memory req) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          _FORWARD_REQUEST_TYPEHASH,
          req.from,
          req.to,
          req.value,
          req.gas,
          nonces(req.from),
          req.deadline,
          keccak256(req.data)
        )
      );
  }
}
