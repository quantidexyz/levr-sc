// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Treasury v1 Interface
/// @notice Per-project treasury handling wrap/unwrap and governance execution.
interface ILevrTreasury_v1 {
    /// @notice Revert if caller is not the project governor.
    error OnlyGovernor();

    /// @notice Revert if caller is not the project wrapper.
    error OnlyWrapper();

    /// @notice Revert if zero address is provided.
    error ZeroAddress();

    /// @notice Revert if invalid amount is provided.
    error InvalidAmount();

    /// @notice Revert if user attempts to unstake more than staked.
    error InsufficientStake();

    // no staking state in treasury in the new model

    /// @notice Emitted when the treasury is initialized by the factory.
    /// @param underlying Underlying token address
    /// @param governor Project governor address
    /// @param wrapper Project wrapper token address
    event Initialized(
        address indexed underlying,
        address indexed governor,
        address indexed wrapper
    );

    // no wrap/unwrap in the new model

    // rewards are handled by staking module

    // no wrap/unwrap in the new model

    /// @notice Execute a governor-authorized transfer of underlying.
    /// @param to Recipient
    /// @param amount Amount to transfer
    function transfer(address to, uint256 amount) external;

    // boosts/rewards accrue via staking module, not treasury

    // rewards accrual moved to staking module

    /// @notice Current underlying balance held by the treasury.
    /// @return balance Underlying token balance
    function getUnderlyingBalance() external view returns (uint256 balance);

    /// @notice Address of the underlying token this treasury manages.
    function underlying() external view returns (address);

    // no staking functions in treasury in the new model
}
