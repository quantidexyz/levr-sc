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

    /// @notice Emitted when the treasury is initialized by the factory.
    /// @param underlying Underlying token address
    /// @param governor Project governor address
    /// @param wrapper Project wrapper token address
    event Initialized(
        address indexed underlying,
        address indexed governor,
        address indexed wrapper
    );

    /// @notice Emitted on wrap (mint) operation.
    /// @param sender Caller who provided underlying
    /// @param to Recipient of wrapper tokens
    /// @param amount Underlying amount provided
    /// @param minted Wrapper tokens minted
    /// @param fees Total fees deducted from the operation
    event Wrapped(
        address indexed sender,
        address indexed to,
        uint256 amount,
        uint256 minted,
        uint256 fees
    );

    /// @notice Emitted on unwrap (redeem) operation.
    /// @param sender Caller who burned wrapper
    /// @param to Recipient of underlying
    /// @param amount Wrapper amount burned
    /// @param returned Underlying returned to the recipient
    /// @param fees Total fees deducted from the operation
    event Unwrapped(
        address indexed sender,
        address indexed to,
        uint256 amount,
        uint256 returned,
        uint256 fees
    );

    /// @notice Emitted when project fees are transferred to the governor.
    /// @param amount Amount of fees transferred
    event FeesCollected(uint256 amount);

    /// @notice Wrap underlying into wrapper tokens.
    /// @param amount Underlying amount to deposit
    /// @param to Recipient of wrapper tokens
    /// @return minted Amount of wrapper tokens minted
    function wrap(uint256 amount, address to) external returns (uint256 minted);

    /// @notice Unwrap wrapper into underlying tokens.
    /// @param amount Wrapper amount to burn
    /// @param to Recipient of underlying tokens
    /// @return returned Amount of underlying returned
    function unwrap(
        uint256 amount,
        address to
    ) external returns (uint256 returned);

    /// @notice Execute a governor-authorized transfer of underlying.
    /// @param to Recipient
    /// @param amount Amount to transfer
    function transfer(address to, uint256 amount) external;

    /// @notice Apply a staking boost (no-op placeholder in v1).
    /// @param amount Amount applied to boost logic
    function applyBoost(uint256 amount) external;

    /// @notice Transfer accumulated project fees to the governor.
    function collectFees() external;

    /// @notice Current underlying balance held by the treasury.
    /// @return balance Underlying token balance
    function getUnderlyingBalance() external view returns (uint256 balance);

    /// @notice Accumulated project fee amount pending collection.
    /// @return fees Pending fee amount
    function getCollectedFees() external view returns (uint256 fees);
}
