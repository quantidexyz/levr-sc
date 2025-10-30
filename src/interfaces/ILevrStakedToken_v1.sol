// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Levr Staked Token v1 Interface
/// @notice ERC20 representing staked positions; mint/burn controlled by staking contract.
interface ILevrStakedToken_v1 is IERC20 {
    // ============ Events ============

    /// @notice Emitted when tokens are minted to `to`.
    event Mint(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned from `from`.
    event Burn(address indexed from, uint256 amount);

    // ============ Functions ============

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
