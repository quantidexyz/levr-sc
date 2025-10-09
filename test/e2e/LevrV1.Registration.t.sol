// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrTreasury_v1} from '../../src/interfaces/ILevrTreasury_v1.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IClankerLpLocker} from '../../src/interfaces/external/IClankerLPLocker.sol';
import {IClankerLpLockerMultiple} from '../../src/interfaces/external/IClankerLpLockerMultiple.sol';
import {IClankerFeeLocker} from '../../src/interfaces/external/IClankerFeeLocker.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrV1_RegistrationE2E is BaseForkTest, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;

    address internal protocolTreasury = address(0xFEE);
    address internal clankerToken;
    address internal clankerFactory; // set from constant
    address constant CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;

    function setUp() public override {
        super.setUp();
        clankerFactory = CLANKER_FACTORY;

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, levrDeployer) = deployFactory(cfg, address(this), CLANKER_FACTORY);
    }

    /**
     * @notice Test registering an existing Clanker token
     * Matches use case: existing-token.screen.tsx register flow
     */
    function test_RegisterExistingToken() public {
        // Deploy a Clanker token first
        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: 'CLK Test',
            symbol: 'CLK',
            clankerFeeBps: 100,
            pairedFeeBps: 100
        });

        // Register the existing token (this is what existing-token.screen does)
        ILevrFactory_v1.Project memory project = factory.register(clankerToken);

        // Verify all project contracts are deployed
        assertTrue(project.treasury != address(0), 'Treasury not deployed');
        assertTrue(project.staking != address(0), 'Staking not deployed');
        assertTrue(project.stakedToken != address(0), 'StakedToken not deployed');
        assertTrue(project.governor != address(0), 'Governor not deployed');

        // Verify project can be retrieved
        ILevrFactory_v1.Project memory retrieved = factory.getProjectContracts(clankerToken);
        assertEq(retrieved.treasury, project.treasury, 'Treasury mismatch');
        assertEq(retrieved.staking, project.staking, 'Staking mismatch');
    }

    /**
     * @notice Test updating fee receiver to staking contract
     * Matches use case: existing-token.screen.tsx update fee receiver flow
     */
    function test_UpdateFeeReceiverToStaking() public {
        // Deploy token
        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: 'CLK Test',
            symbol: 'CLK',
            clankerFeeBps: 100,
            pairedFeeBps: 100
        });

        // Register project (must register before updating fee receiver)
        ILevrFactory_v1.Project memory project = factory.register(clankerToken);
        assertTrue(project.staking != address(0), 'Staking not deployed');

        // Base mainnet LP Locker
        address lpLocker = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;

        // Get initial reward info
        IClankerLpLocker.TokenRewardInfo memory rewardInfo = IClankerLpLocker(lpLocker)
            .tokenRewards(clankerToken);
        address originalRecipient = rewardInfo.rewardRecipients[0];

        // Original recipient should be the tokenAdmin
        assertEq(originalRecipient, address(this), 'Initial recipient should be tokenAdmin');

        // Update fee receiver to staking (this is what existing-token.screen does)
        IClankerLpLockerMultiple(lpLocker).updateRewardRecipient(clankerToken, 0, project.staking);

        // Verify update was successful
        rewardInfo = IClankerLpLocker(lpLocker).tokenRewards(clankerToken);
        assertEq(
            rewardInfo.rewardRecipients[0],
            project.staking,
            'Fee receiver should be staking contract'
        );

        // Verify non-admin cannot update (security check)
        address unauthorized = address(0xBEEF);
        vm.prank(unauthorized);
        vm.expectRevert();
        IClankerLpLockerMultiple(lpLocker).updateRewardRecipient(clankerToken, 0, unauthorized);
    }
}
