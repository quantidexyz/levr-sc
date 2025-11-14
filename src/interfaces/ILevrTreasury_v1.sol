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

    /// @notice Current underlying balance held by the treasury.
    /// @return balance Underlying token balance
    function getUnderlyingBalance() external view returns (uint256 balance);

    /// @notice Address of the underlying token this treasury manages.
    function underlying() external view returns (address);

    /// @notice Address of the governor contract that can authorize transfers.
    function governor() external view returns (address);

    /// @notice Address of the staking contract for boost operations.
    function staking() external view returns (address);
}
