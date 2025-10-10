// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager, SwapParams} from '@uniswapV4-core/interfaces/IPoolManager.sol';
import {PoolId} from '@uniswapV4-core/types/PoolId.sol';
import {PoolKey} from '@uniswapV4-core/types/PoolKey.sol';

import {IClankerHook} from './IClankerHook.sol';

interface IClankerHookV2 is IClankerHook {
    error OnlyThis();
    error MevModuleNotOperational();
    error Unauthorized();
    error OnlyFactoryPoolsCanHaveExtensions();
    error PoolExtensionNotEnabled();

    event PoolExtensionSuccess(PoolId poolId);
    event PoolExtensionFailed(PoolId poolId, SwapParams swapParams);
    event MevModuleSetFee(PoolId poolId, uint24 fee);
    event PoolExtensionRegistered(PoolId indexed poolId, address indexed extension);

    struct PoolInitializationData {
        address extension;
        bytes extensionData;
        bytes feeData;
    }

    struct PoolSwapData {
        bytes mevModuleSwapData;
        bytes poolExtensionSwapData;
    }

    function mevModuleSetFee(PoolKey calldata poolKey, uint24 fee) external;

    function mevModuleOperational(PoolId poolId) external returns (bool);
    function mevModuleEnabled(PoolId poolId) external view returns (bool);
    function poolCreationTimestamp(PoolId poolId) external view returns (uint256);
    function MAX_MEV_MODULE_DELAY() external view returns (uint256);
    function MAX_LP_FEE() external view returns (uint24);
    function MAX_MEV_LP_FEE() external view returns (uint24);
}
