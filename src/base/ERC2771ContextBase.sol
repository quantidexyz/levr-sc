// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC2771Context} from '@openzeppelin/contracts/metatx/ERC2771Context.sol';
import {Context} from '@openzeppelin/contracts/utils/Context.sol';

/**
 * @title ERC2771ContextBase
 * @notice Base contract that provides ERC2771Context overrides for multiple inheritance scenarios
 * @dev Used when contracts inherit from both ReentrancyGuard (or other Context-based contracts)
 *      and ERC2771Context to resolve the diamond inheritance pattern
 */
abstract contract ERC2771ContextBase is ERC2771Context {
  /**
   * @dev Constructor that passes the trusted forwarder to ERC2771Context
   * @param trustedForwarder The address of the trusted forwarder
   */
  constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {}

  /**
   * @dev Override required due to multiple inheritance
   * @return sender The real sender extracted from calldata if called via trusted forwarder
   */
  function _msgSender() internal view virtual override(ERC2771Context) returns (address sender) {
    return ERC2771Context._msgSender();
  }

  /**
   * @dev Override required due to multiple inheritance
   * @return data The real calldata if called via trusted forwarder
   */
  function _msgData() internal view virtual override(ERC2771Context) returns (bytes calldata) {
    return ERC2771Context._msgData();
  }

  /**
   * @dev Override required due to multiple inheritance
   * @return length The context suffix length (20 bytes for appended sender address)
   */
  function _contextSuffixLength() internal view virtual override(ERC2771Context) returns (uint256) {
    return ERC2771Context._contextSuffixLength();
  }
}
