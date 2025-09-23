// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IProtocolFees} from "./IProtocolFees.sol";

/// @notice Minimal interface for the PoolManager - only functions needed for Levr
interface IPoolManager is IProtocolFees {
    /// @notice Thrown when unlock is called, but the contract is already unlocked
    error AlreadyUnlocked();

    /// @notice Thrown when a function is called that requires the contract to be unlocked, but it is not
    error ManagerLocked();

    /// @notice Thrown when a currency is not netted out after the contract is unlocked
    error CurrencyNotSettled();

    /// @notice Takes the first 32 bytes of data and calls the function on the contract with the rest of the data
    /// @param data The data to call unlock with
    /// @return result The return data from the unlock call
    function unlock(
        bytes calldata data
    ) external payable returns (bytes memory result);

    /// @notice Collect protocol fees for the given currency
    /// @param recipient The address to send the fees to
    /// @param currency The currency to collect fees for
    /// @param amount The amount of fees to collect
    /// @return amountCollected The amount of currency successfully withdrawn
    function collectProtocolFees(
        address recipient,
        Currency currency,
        uint256 amount
    ) external returns (uint256 amountCollected);

    /// @notice Get the accrued protocol fees for a currency
    /// @param currency The currency to get fees for
    /// @return amount The amount of accrued fees
    function protocolFeesAccrued(
        Currency currency
    ) external view returns (uint256 amount);
}
