// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Levr Treasury v1 Interface
/// @notice Per-project treasury handling governance execution.
interface ILevrTreasury_v1 {
    // ============ Errors ============

    /// @notice Revert if caller is not the project governor.
    error OnlyGovernor();

    /// @notice Revert if caller is not the factory.
    error OnlyFactory();

    /// @notice Revert if treasury is already initialized.
    error AlreadyInitialized();

    /// @notice Revert if zero address is provided.
    error ZeroAddress();

    /// @notice Revert if invalid amount is provided.
    error InvalidAmount();

    // ============ Events ============

    /// @notice Emitted when the treasury is initialized by the factory.
    /// @param underlying Underlying token address
    /// @param governor Project governor address
    event Initialized(address indexed underlying, address indexed governor);

    /// @notice Emitted when the governor executes a token transfer.
    /// @param token ERC20 token address transferred from the treasury
    /// @param to Recipient of the transfer
    /// @param amount Amount transferred
    event TransferExecuted(address indexed token, address indexed to, uint256 amount);

    // ============ Functions ============

    /// @notice Initialize the treasury (called once by factory during deployment).
    /// @param governor_ Governor contract address
    /// @param underlying_ Underlying token address
    function initialize(address governor_, address underlying_) external;

    /// @notice Execute a governor-authorized transfer of any ERC20 token.
    /// @param token ERC20 token address (underlying, WETH, or any ERC20)
    /// @param to Recipient
    /// @param amount Amount to transfer
    function transfer(address token, address to, uint256 amount) external;
}
