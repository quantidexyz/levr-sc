// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Levr Wrapped ERC20 Interface
/// @notice ERC20 wrapper for an underlying token with treasury-controlled mint/burn.
interface ILevrERC20 is IERC20 {
    /// @notice Emitted when `amount` tokens are minted to `to`.
    /// @param to Recipient of minted tokens
    /// @param amount Amount minted
    event Mint(address indexed to, uint256 amount);

    /// @notice Emitted when `amount` tokens are burned from `from`.
    /// @param from Address burned from
    /// @param amount Amount burned
    event Burn(address indexed from, uint256 amount);

    /// @notice Mint wrapper tokens. Callable only by the project treasury.
    /// @param to Recipient of minted tokens
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn wrapper tokens. Callable only by the project treasury.
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external;

    /// @notice Decimals of the wrapper (mirrors underlying).
    /// @return decimals_ Decimals value
    function decimals() external view returns (uint8 decimals_);

    /// @notice Address of the underlying token being wrapped.
    /// @return token Address of underlying ERC20
    function underlying() external view returns (address token);
}
