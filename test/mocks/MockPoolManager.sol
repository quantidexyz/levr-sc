// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IPoolManager} from "../../src/interfaces/external/IPoolManager.sol";

contract MockPoolManager is IPoolManager {
    mapping(Currency => uint256) private _protocolFeesAccrued;
    bool private _harvestCalled;
    address private masterLevr;
    address private _protocolFeeController;

    function setProtocolFeesAccrued(
        Currency currency,
        uint256 amount
    ) external {
        _protocolFeesAccrued[currency] = amount;
    }

    function setMasterLevr(address _masterLevr) external {
        masterLevr = _masterLevr;
        _protocolFeeController = _masterLevr; // Set as fee controller by default
    }

    function setProtocolFeeController(address controller) external {
        _protocolFeeController = controller;
    }

    function protocolFeesAccrued(
        Currency currency
    ) external view returns (uint256) {
        return _protocolFeesAccrued[currency];
    }

    function unlock(
        bytes calldata data
    ) external payable returns (bytes memory) {
        // For this mock, we'll directly call the masterLevr's unlockCallback
        // In the real v4, this would be a callback to the calling contract
        // For simplicity, assume the data is the callback data for MasterLevr_v1
        (bool success, bytes memory result) = address(masterLevr).call(
            abi.encodeWithSignature("unlockCallback(bytes)", data)
        );

        require(success, "Callback failed");
        _harvestCalled = true; // Mark that harvest was called
        return result;
    }

    function collectProtocolFees(
        address recipient,
        Currency currency,
        uint256 amount
    ) external returns (uint256 amountCollected) {
        amountCollected = _protocolFeesAccrued[currency];
        if (amountCollected > amount) {
            amountCollected = amount;
        }

        _protocolFeesAccrued[currency] -= amountCollected;
        _harvestCalled = true;

        // For testing, assume the recipient gets the tokens
        // In a real implementation, this would transfer tokens
    }

    function harvestCalled() external view returns (bool) {
        return _harvestCalled;
    }

    // Stub implementations for other interface methods

    function protocolFeeController() external view returns (address) {
        return _protocolFeeController;
    }

    function setProtocolFee(PoolKey memory, uint24) external pure {
        revert("Not implemented in mock");
    }
}
