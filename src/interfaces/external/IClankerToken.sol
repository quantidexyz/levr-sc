// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title IClankerToken
/// @notice Interface for Clanker-deployed tokens
interface IClankerToken is IERC20 {
  error NotAdmin();
  error NotOriginalAdmin();
  error AlreadyVerified();

  event Verified(address indexed admin, address indexed token);
  event UpdateImage(string image);
  event UpdateMetadata(string metadata);
  event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);

  /// @notice Update the admin address
  /// @param admin_ New admin address
  function updateAdmin(address admin_) external;

  /// @notice Update the image URL
  /// @param image_ New image URL
  function updateImage(string memory image_) external;

  /// @notice Update the metadata
  /// @param metadata_ New metadata
  function updateMetadata(string memory metadata_) external;

  /// @notice Verify the token (can only be called by original admin once)
  function verify() external;

  /// @notice Check if the token is verified
  /// @return True if verified, false otherwise
  function isVerified() external view returns (bool);

  /// @notice Get the current admin address
  /// @return The current admin address
  function admin() external view returns (address);

  /// @notice Get the original admin address (immutable)
  /// @return The original admin address
  function originalAdmin() external view returns (address);

  /// @notice Get the image URL
  /// @return The image URL
  function imageUrl() external view returns (string memory);

  /// @notice Get the metadata
  /// @return The metadata string
  function metadata() external view returns (string memory);

  /// @notice Get the context
  /// @return The context string
  function context() external view returns (string memory);

  /// @notice Get all token data in one call
  /// @return originalAdmin The original admin address
  /// @return admin The current admin address
  /// @return image The image URL
  /// @return metadata The metadata string
  /// @return context The context string
  function allData()
    external
    view
    returns (address originalAdmin, address admin, string memory image, string memory metadata, string memory context);
}
