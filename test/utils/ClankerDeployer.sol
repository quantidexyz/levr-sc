// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IClanker} from "../../src/interfaces/external/IClanker.sol";
import {IClankerHookV2} from "../../src/interfaces/external/IClankerHookV2.sol";

/// @notice Test utility to deploy a Clanker token with full pooled factory path (SDK-style) on Base Mainnet.
contract ClankerDeployer {
    // Hardcoded contract addresses on Base Mainnet
    address internal constant STATIC_FEE_HOOK =
        0xb429d62f8f3bFFb98CdB9569533eA23bF0Ba28CC;
    address internal constant DYNAMIC_FEE_HOOK =
        0xd60D6B218116cFd801E28F78d011a203D2b068Cc;
    address internal constant MEV_MODULE_V2 =
        0xebB25BB797D82CB78E1bc70406b13233c0854413;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant LOCKER =
        0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
    // Optional airdrop extension (Base Mainnet anchor for fork)
    address internal constant AIRDROP_EXTENSION_DEFAULT =
        0xf652B3610D75D81871bf96DB50825d9af28391E0;

    // ABI for extensionData encoding: (admin, merkleRoot, lockupDuration, vestingDuration)
    struct AirdropOpts {
        address admin;
        bytes32 merkleRoot;
        uint256 lockupDuration;
        uint256 vestingDuration;
    }

    // Locker instantiation data structure (matches SDK ABI)
    struct ClankerLpLockerInstantiation {
        uint8[] feePreference;
    }

    function _staticFeeData(
        uint24 clankerFeeBps,
        uint24 pairedFeeBps
    ) internal pure returns (bytes memory) {
        // SDK uses uniBps = bps * 100
        uint24 clankerUniBps = uint24(uint256(clankerFeeBps) * 100);
        uint24 pairedUniBps = uint24(uint256(pairedFeeBps) * 100);
        return abi.encode(clankerUniBps, pairedUniBps);
    }

    function deployFactoryStaticFull(
        address clankerFactory,
        address tokenAdmin,
        string memory name,
        string memory symbol,
        uint24 clankerFeeBps,
        uint24 pairedFeeBps
    ) external returns (address token) {
        token = deployFactoryStaticFullWithOptions(
            clankerFactory,
            tokenAdmin,
            name,
            symbol,
            clankerFeeBps,
            pairedFeeBps,
            false,
            address(0),
            0,
            bytes("")
        );
    }

    /// @notice Deploy with optional airdrop extension that allocates a percentage of supply to an extension
    /// @param enableAirdrop If true, attach an airdrop extension
    /// @param airdropAdmin Admin/recipient address passed to extension data encoding
    /// @param airdropBps Portion (in bps) allocated to the airdrop extension (0-10000)
    /// @param airdropData Raw extension data payload; if empty, defaults may apply
    function deployFactoryStaticFullWithOptions(
        address clankerFactory,
        address tokenAdmin,
        string memory name,
        string memory symbol,
        uint24 clankerFeeBps,
        uint24 pairedFeeBps,
        bool enableAirdrop,
        address airdropAdmin,
        uint16 airdropBps,
        bytes memory airdropData
    ) public returns (address token) {
        require(clankerFactory != address(0), "INVALID_FACTORY");
        if (tokenAdmin == address(0)) tokenAdmin = msg.sender;

        // Use hardcoded addresses for Base Sepolia
        address hook = STATIC_FEE_HOOK;
        address pairedToken = WETH;
        address locker = LOCKER;
        address mevModule = MEV_MODULE_V2;

        // Default pool configuration
        int24 tickIfToken0IsClanker = -230400; // Default tick for WETH pair
        int24 tickSpacing = 200; // Standard tick spacing

        IClanker.TokenConfig memory tcfg = IClanker.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: name,
            symbol: symbol,
            salt: keccak256(
                abi.encodePacked(name, symbol, block.timestamp, tokenAdmin)
            ),
            image: "",
            metadata: "",
            context: "test",
            originatingChainId: block.chainid
        });

        // Use v4.1 hooks format for static/dynamic fee hooks
        IClankerHookV2.PoolInitializationData memory pid = IClankerHookV2
            .PoolInitializationData({
                extension: address(0),
                extensionData: bytes(""),
                feeData: _staticFeeData(clankerFeeBps, pairedFeeBps)
            });
        bytes memory poolData = abi.encode(pid);

        IClanker.PoolConfig memory pcfg = IClanker.PoolConfig({
            hook: hook,
            pairedToken: pairedToken,
            tickIfToken0IsClanker: tickIfToken0IsClanker,
            tickSpacing: tickSpacing,
            poolData: poolData
        });

        // Simplified locker config with single recipient (tokenAdmin)
        uint8[] memory feePreferences = new uint8[](1);
        feePreferences[0] = 0; // FeeIn.Both
        bytes memory lockerData = abi.encode(
            ClankerLpLockerInstantiation({feePreference: feePreferences})
        );

        int24[] memory tickLowers = new int24[](1);
        tickLowers[0] = -230400; // Same as starting tick
        int24[] memory tickUppers = new int24[](1);
        tickUppers[0] = -120000; // Simple position range
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10000; // 100%
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = tokenAdmin;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = tokenAdmin;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10000; // 100%

        IClanker.LockerConfig memory lcfg = IClanker.LockerConfig({
            locker: locker,
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLowers,
            tickUpper: tickUppers,
            positionBps: positionBps,
            lockerData: lockerData
        });

        // SDK uses mevModuleData with sniper auction init data for V2 modules (mandatory)
        bytes memory mevModuleData = abi.encode(
            uint24(666_777),
            uint24(41_673),
            uint256(15)
        );
        IClanker.MevModuleConfig memory mcfg = IClanker.MevModuleConfig({
            mevModule: mevModule,
            mevModuleData: mevModuleData
        });

        IClanker.ExtensionConfig[] memory ecfg;
        if (enableAirdrop) {
            bytes memory extData = airdropData;
            if (extData.length == 0) {
                // Default simple encoding compatible with Clanker Airdrop V2 style: (admin, merkleRoot, lockup, vesting)
                AirdropOpts memory opts = AirdropOpts({
                    admin: airdropAdmin == address(0)
                        ? tokenAdmin
                        : airdropAdmin,
                    merkleRoot: bytes32(0),
                    lockupDuration: 1 days,
                    vestingDuration: 0 days
                });
                extData = abi.encode(
                    opts.admin,
                    opts.merkleRoot,
                    opts.lockupDuration,
                    opts.vestingDuration
                );
            }
            ecfg = new IClanker.ExtensionConfig[](1);
            ecfg[0] = IClanker.ExtensionConfig({
                extension: AIRDROP_EXTENSION_DEFAULT,
                msgValue: 0,
                extensionBps: airdropBps,
                extensionData: extData
            });
        } else {
            ecfg = new IClanker.ExtensionConfig[](0);
        }

        IClanker.DeploymentConfig memory dcfg = IClanker.DeploymentConfig({
            tokenConfig: tcfg,
            poolConfig: pcfg,
            lockerConfig: lcfg,
            mevModuleConfig: mcfg,
            extensionConfigs: ecfg
        });

        token = IClanker(clankerFactory).deployToken(dcfg);
    }
}
