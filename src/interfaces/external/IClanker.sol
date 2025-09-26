// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";

// Clanker main interface (aka Factory) for token deployment
interface IClanker {
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

    struct PoolConfig {
        address hook;
        address pairedToken;
        int24 tickIfToken0IsClanker;
        int24 tickSpacing;
        bytes poolData;
    }

    struct LockerConfig {
        address locker;
        address[] rewardAdmins;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
        bytes lockerData;
    }

    struct ExtensionConfig {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct MevModuleConfig {
        address mevModule;
        bytes mevModuleData;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        PoolConfig poolConfig;
        LockerConfig lockerConfig;
        MevModuleConfig mevModuleConfig;
        ExtensionConfig[] extensionConfigs;
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
    ) external returns (address tokenAddress);

    function deployToken(
        DeploymentConfig calldata deploymentConfig
    ) external payable returns (address tokenAddress);
}
