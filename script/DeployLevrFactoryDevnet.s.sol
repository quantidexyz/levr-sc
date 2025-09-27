// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ILevrFactory_v1} from "../src/interfaces/ILevrFactory_v1.sol";
import {LevrFactory_v1} from "../src/LevrFactory_v1.sol";

/**
 * @title DeployLevrFactoryDevnet
 * @notice Deterministic deployment script for LevrFactory_v1 on devnet
 * @dev This script deploys the factory with deterministic addresses for fast UI iteration
 *
 * Environment Variables:
 * - PRIVATE_KEY: Private key for deployment (use same key for deterministic addresses)
 * - FORK_URL: (Optional) RPC URL for custom network/fork. Defaults to local anvil.
 *
 * Usage:
 * PRIVATE_KEY=$DEVNET_PRIVATE_KEY make deploy-devnet-factory  # Uses local anvil
 * PRIVATE_KEY=$DEVNET_PRIVATE_KEY FORK_URL=$BASE_SEPOLIA_RPC_URL make deploy-devnet-factory  # Custom network
 *
 * For anvil fork testing (recommended):
 * 1. Start anvil: make anvil-fork (in one terminal)
 * 2. Deploy: make deploy-devnet-factory (in another terminal)
 *
 * For custom fork/testnet (ensure deployer has ETH):
 * make deploy-devnet-factory FORK_URL=$BASE_SEPOLIA_RPC_URL
 *
 * For deterministic deployment, always use the same PRIVATE_KEY and RPC_URL
 * The Makefile automatically funds the deployer address before deployment
 */
contract DeployLevrFactoryDevnet is Script {
    // Devnet configuration - deterministic values for consistent deployment
    uint16 constant PROTOCOL_FEE_BPS = 50; // 0.5%
    uint32 constant SUBMISSION_DEADLINE_SECONDS = 604800; // 7 days
    uint32 constant STREAM_WINDOW_SECONDS = 2592000; // 30 days
    uint16 constant MAX_SUBMISSION_PER_TYPE = 10;
    uint256 constant MIN_WTOKEN_TO_SUBMIT = 100e18; // 100 tokens (assuming 18 decimals)

    // Transfer tiers in underlying token units (assuming 18 decimals)
    uint256[] private TRANSFER_TIERS = [1e18, 10e18, 100e18]; // 1, 10, 100 tokens

    // Staking boost tiers as percentages (0.03 = 3%, 0.6 = 60%, 0.9 = 90%)
    uint256[] private STAKING_BOOST_TIERS = [
        30000000000000000,
        600000000000000000,
        900000000000000000
    ];

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        // Deployer funding is handled by the Makefile before script execution

        // Use deployer as protocol treasury for devnet simplicity
        address protocolTreasury = deployer;

        console.log("=== LEVR FACTORY DEVNET DEPLOYMENT ===");
        console.log("Deployer Address:", deployer);
        console.log("Deployer Balance:", deployer.balance / 1e18, "ETH");
        console.log("Protocol Treasury:", protocolTreasury);
        console.log("Network Chain ID:", block.chainid);
        console.log("");

        // Build factory configuration
        ILevrFactory_v1.TierConfig[]
            memory transferTiers = new ILevrFactory_v1.TierConfig[](
                TRANSFER_TIERS.length
            );
        for (uint256 i = 0; i < TRANSFER_TIERS.length; i++) {
            transferTiers[i] = ILevrFactory_v1.TierConfig({
                value: TRANSFER_TIERS[i]
            });
        }

        ILevrFactory_v1.TierConfig[]
            memory stakingBoostTiers = new ILevrFactory_v1.TierConfig[](
                STAKING_BOOST_TIERS.length
            );
        for (uint256 i = 0; i < STAKING_BOOST_TIERS.length; i++) {
            stakingBoostTiers[i] = ILevrFactory_v1.TierConfig({
                value: STAKING_BOOST_TIERS[i]
            });
        }

        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1
            .FactoryConfig({
                protocolFeeBps: PROTOCOL_FEE_BPS,
                submissionDeadlineSeconds: SUBMISSION_DEADLINE_SECONDS,
                maxSubmissionPerType: MAX_SUBMISSION_PER_TYPE,
                streamWindowSeconds: STREAM_WINDOW_SECONDS,
                transferTiers: transferTiers,
                stakingBoostTiers: stakingBoostTiers,
                minWTokenToSubmit: MIN_WTOKEN_TO_SUBMIT,
                protocolTreasury: protocolTreasury
            });

        console.log("Factory Configuration:");
        console.log("- Protocol Fee BPS:", config.protocolFeeBps);
        console.log(
            "- Submission Deadline (seconds):",
            config.submissionDeadlineSeconds
        );
        console.log("- Stream Window (seconds):", config.streamWindowSeconds);
        console.log("- Max Submissions Per Type:", config.maxSubmissionPerType);
        console.log(
            "- Min WToken to Submit:",
            config.minWTokenToSubmit / 1e18,
            "tokens"
        );
        console.log("- Transfer Tiers Count:", transferTiers.length);
        console.log("- Staking Boost Tiers Count:", stakingBoostTiers.length);
        console.log("");

        vm.startBroadcast(privateKey);

        // Deploy the factory with deterministic configuration
        LevrFactory_v1 factory = new LevrFactory_v1(config, deployer);

        vm.stopBroadcast();

        // Verification and logging
        address factoryAddress = address(factory);

        console.log("=== DEPLOYMENT SUCCESSFUL ===");
        console.log("Factory Address:", factoryAddress);
        console.log("Factory Owner (Admin):", deployer);
        console.log("");

        // Verify factory configuration
        console.log("=== FACTORY CONFIGURATION VERIFICATION ===");
        console.log("protocolFeeBps:", factory.protocolFeeBps());
        console.log(
            "submissionDeadlineSeconds:",
            factory.submissionDeadlineSeconds()
        );
        console.log("streamWindowSeconds:", factory.streamWindowSeconds());
        console.log("maxSubmissionPerType:", factory.maxSubmissionPerType());
        console.log("minWTokenToSubmit:", factory.minWTokenToSubmit());
        console.log("protocolTreasury:", factory.protocolTreasury());
        console.log("transferTierCount:", factory.getTransferTierCount());
        console.log(
            "stakingBoostTierCount:",
            factory.getStakingBoostTierCount()
        );

        // Log transfer tiers
        console.log("Transfer Tiers:");
        for (uint256 i = 0; i < factory.getTransferTierCount(); i++) {
            console.log("-", i, ":", factory.getTransferTier(i));
        }

        // Log staking boost tiers
        console.log("Staking Boost Tiers:");
        for (uint256 i = 0; i < factory.getStakingBoostTierCount(); i++) {
            console.log("-", i, ":", factory.getStakingBoostTier(i));
        }

        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Use Factory Address in your UI configuration");
        console.log("2. Deploy Clanker tokens via UI or separate script");
        console.log("3. Register projects using factory.register()");
        console.log("4. Test governance and staking flows");
        console.log("");
        console.log("Factory deployment completed successfully!");
    }
}
