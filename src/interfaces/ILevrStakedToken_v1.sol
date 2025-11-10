// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title Levr Staked Token v1 Interface
/// @notice ERC20 representing staked positions; mint/burn controlled by staking contract.
interface ILevrStakedToken_v1 is IERC20 {
    // ============ Errors ============

    /// @notice Revert if already initialized (double initialization prevented)
    error AlreadyInitialized();

    /// @notice Revert if caller is not the deployer/factory
    error OnlyFactory();

    /// @notice Revert if zero address provided
    error ZeroAddress();

    /// @notice Revert if attempting to modify underlying (staked tokens are non-transferable)
    error CannotModifyUnderlying();

    // ============ Events ============

    /// @notice Emitted when tokens are minted to `to`.
    event Mint(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned from `from`.
    event Burn(address indexed from, uint256 amount);

    // ============ Functions ============

    /// @notice Initialize the cloned staked token (clone-only, called once).
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address underlying_,
        address staking_
    ) external;

    /// @notice Mint staked tokens (staking-only).
    function mint(address to, uint256 amount) external;

    /// @notice Burn staked tokens (staking-only).
    function burn(address from, uint256 amount) external;

    /// @notice Decimals of staked token (mirrors underlying).
    function decimals() external view returns (uint8);

    /// @notice Underlying asset being staked.
    function underlying() external view returns (address);

    /// @notice Staking contract that controls mint/burn.
    function staking() external view returns (address);
}
