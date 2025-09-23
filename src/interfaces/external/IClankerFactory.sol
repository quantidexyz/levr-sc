// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";

// Clanker Factory interface for token deployment
interface IClankerFactory {
    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string metadata;
        string context;
        uint256 originatingChainId;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        // Additional deployment config would go here
    }

    event TokenCreated(
        address indexed tokenAddress,
        address indexed tokenAdmin,
        string tokenImage,
        string tokenName,
        string tokenSymbol,
        string tokenMetadata,
        string tokenContext,
        address poolHook,
        PoolId poolId,
        address pairedToken,
        address locker,
        address mevModule
    );

    function deployTokenZeroSupply(
        TokenConfig calldata config
    ) external returns (address);

    function deployToken(
        DeploymentConfig calldata config
    ) external returns (address);
}
