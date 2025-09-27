// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ILevrFactory_v1} from "../src/interfaces/ILevrFactory_v1.sol";
import {LevrFactory_v1} from "../src/LevrFactory_v1.sol";

/**
 * @title DeployLevrFactoryDevnet Test
 * @notice Unit test for the devnet deployment script logic
 */
contract DeployLevrFactoryDevnetTest is Test {
    function test_DevnetConfig() public {
        // Test the same configuration values used in the deployment script
        uint16 protocolFeeBps = 50;
        uint32 submissionDeadlineSeconds = 604800;
        uint32 streamWindowSeconds = 2592000;
        uint16 maxSubmissionPerType = 10;
        uint256 minWTokenToSubmit = 100e18;
        address protocolTreasury = address(this);

        uint256[] memory transferTiers = new uint256[](3);
        transferTiers[0] = 1e18;
        transferTiers[1] = 10e18;
        transferTiers[2] = 100e18;

        uint256[] memory stakingBoostTiers = new uint256[](3);
        stakingBoostTiers[0] = 30000000000000000; // 0.03
        stakingBoostTiers[1] = 600000000000000000; // 0.6
        stakingBoostTiers[2] = 900000000000000000; // 0.9

        // Build configuration structs
        ILevrFactory_v1.TierConfig[]
            memory transferTierConfigs = new ILevrFactory_v1.TierConfig[](
                transferTiers.length
            );
        for (uint256 i = 0; i < transferTiers.length; i++) {
            transferTierConfigs[i] = ILevrFactory_v1.TierConfig({
                value: transferTiers[i]
            });
        }

        ILevrFactory_v1.TierConfig[]
            memory stakingBoostTierConfigs = new ILevrFactory_v1.TierConfig[](
                stakingBoostTiers.length
            );
        for (uint256 i = 0; i < stakingBoostTiers.length; i++) {
            stakingBoostTierConfigs[i] = ILevrFactory_v1.TierConfig({
                value: stakingBoostTiers[i]
            });
        }

        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1
            .FactoryConfig({
                protocolFeeBps: protocolFeeBps,
                submissionDeadlineSeconds: submissionDeadlineSeconds,
                maxSubmissionPerType: maxSubmissionPerType,
                streamWindowSeconds: streamWindowSeconds,
                transferTiers: transferTierConfigs,
                stakingBoostTiers: stakingBoostTierConfigs,
                minWTokenToSubmit: minWTokenToSubmit,
                protocolTreasury: protocolTreasury
            });

        // Deploy factory with config
        LevrFactory_v1 factory = new LevrFactory_v1(config, address(this));

        // Verify configuration
        assertEq(factory.protocolFeeBps(), protocolFeeBps);
        assertEq(
            factory.submissionDeadlineSeconds(),
            submissionDeadlineSeconds
        );
        assertEq(factory.streamWindowSeconds(), streamWindowSeconds);
        assertEq(factory.maxSubmissionPerType(), maxSubmissionPerType);
        assertEq(factory.minWTokenToSubmit(), minWTokenToSubmit);
        assertEq(factory.protocolTreasury(), protocolTreasury);

        // Verify tiers
        assertEq(factory.getTransferTierCount(), 3);
        assertEq(factory.getStakingBoostTierCount(), 3);

        for (uint256 i = 0; i < transferTiers.length; i++) {
            assertEq(factory.getTransferTier(i), transferTiers[i]);
        }

        for (uint256 i = 0; i < stakingBoostTiers.length; i++) {
            assertEq(factory.getStakingBoostTier(i), stakingBoostTiers[i]);
        }
    }
}
