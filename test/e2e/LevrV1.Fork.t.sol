// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseForkTest} from "../utils/BaseForkTest.sol";
import {LevrFactory_v1} from "../../src/LevrFactory_v1.sol";
import {ILevrFactory_v1} from "../../src/interfaces/ILevrFactory_v1.sol";
import {ILevrGovernor_v1} from "../../src/interfaces/ILevrGovernor_v1.sol";
import {ILevrStaking_v1} from "../../src/interfaces/ILevrStaking_v1.sol";
import {ILevrTreasury_v1} from "../../src/interfaces/ILevrTreasury_v1.sol";
import {ClankerDeployer} from "../utils/ClankerDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LevrV1_ForkE2E is BaseForkTest {
    LevrFactory_v1 internal factory;

    address internal protocolTreasury = address(0xFEE);
    address internal clankerToken;
    address internal clankerFactory; // set from constant
    address constant DEFAULT_CLANKER_FACTORY =
        0xE85A59c628F7d27878ACeB4bf3b35733630083a9;

    function setUp() public override {
        super.setUp();
        clankerFactory = DEFAULT_CLANKER_FACTORY;

        ILevrFactory_v1.TierConfig[]
            memory transferTiers = new ILevrFactory_v1.TierConfig[](3);
        transferTiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
        transferTiers[1] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
        transferTiers[2] = ILevrFactory_v1.TierConfig({value: 100_000 ether});

        ILevrFactory_v1.TierConfig[]
            memory boostTiers = new ILevrFactory_v1.TierConfig[](3);
        boostTiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
        boostTiers[1] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
        boostTiers[2] = ILevrFactory_v1.TierConfig({value: 100_000 ether});

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1
            .FactoryConfig({
                protocolFeeBps: 0,
                submissionDeadlineSeconds: 7 days,
                maxSubmissionPerType: 0,
                streamWindowSeconds: 3 days,
                transferTiers: transferTiers,
                stakingBoostTiers: boostTiers,
                minWTokenToSubmit: 0,
                protocolTreasury: protocolTreasury
            });
        factory = new LevrFactory_v1(cfg, address(this));
    }

    function test_register_project_and_basic_flow() public {
        // Always deploy a zero-supply Clanker token on fork for testing
        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployZeroSupply(
            clankerFactory,
            address(this),
            "CLK Test",
            "CLK"
        );

        (address governor, ) = factory.register(
            clankerToken,
            ILevrFactory_v1.RegisterParams({
                treasury: address(0),
                extraConfig: bytes("")
            })
        );

        (address treasury, , address staking, address stakedToken) = factory
            .getProjectContracts(clankerToken);
        assertTrue(
            treasury != address(0) &&
                staking != address(0) &&
                stakedToken != address(0)
        );

        // If caller holds some underlying on fork, try a minimal stake
        uint256 bal = IERC20(clankerToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(clankerToken).approve(staking, bal);
            ILevrStaking_v1(staking).stake(bal);
        }

        // Governor can create a dummy boost proposal and execute it immediately
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(1, 0);
        ILevrGovernor_v1(governor).execute(pid);

        // Treasury balance read works on live token
        uint256 tBal = ILevrTreasury_v1(treasury).getUnderlyingBalance();
        tBal;
    }
}
