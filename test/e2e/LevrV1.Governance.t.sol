// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseForkTest} from "../utils/BaseForkTest.sol";
import {LevrFactory_v1} from "../../src/LevrFactory_v1.sol";
import {ILevrFactory_v1} from "../../src/interfaces/ILevrFactory_v1.sol";
import {ILevrGovernor_v1} from "../../src/interfaces/ILevrGovernor_v1.sol";
import {ILevrStaking_v1} from "../../src/interfaces/ILevrStaking_v1.sol";
import {ClankerDeployer} from "../utils/ClankerDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LevrV1_GovernanceE2E is BaseForkTest {
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

    function _deployRegisterAndGet(
        address fac
    )
        internal
        returns (
            address governor,
            address treasury,
            address staking,
            address stakedToken
        )
    {
        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: "CLK Test",
            symbol: "CLK",
            clankerFeeBps: 100,
            pairedFeeBps: 100
        });

        (governor, ) = LevrFactory_v1(fac).register(
            clankerToken,
            ILevrFactory_v1.RegisterParams({
                treasury: address(0),
                extraConfig: bytes("")
            })
        );
        (treasury, , staking, stakedToken) = LevrFactory_v1(fac)
            .getProjectContracts(clankerToken);
    }

    function _acquireFromLocker(
        address to,
        uint256 desired
    ) internal returns (uint256 acquired) {
        address locker = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
        uint256 lockerBalance = IERC20(clankerToken).balanceOf(locker);
        if (lockerBalance == 0) return 0;
        acquired = desired <= lockerBalance ? desired : lockerBalance;
        vm.prank(locker);
        IERC20(clankerToken).transfer(to, acquired);
    }

    function test_transfer_proposal_and_tier_validation() public {
        (address governor, address treasury, , ) = _deployRegisterAndGet(
            address(factory)
        );

        // Ensure treasury has some funds (from locker or user)
        uint256 treasBal = IERC20(clankerToken).balanceOf(treasury);
        if (treasBal == 0) {
            uint256 got = _acquireFromLocker(address(this), 1_000 ether);
            if (got > 0) {
                IERC20(clankerToken).transfer(treasury, got);
                treasBal = got;
            }
        }
        assertTrue(treasBal > 0, "treasury needs funds");

        // Valid transfer within tier 0 and within treasury balance
        address receiver = address(0xBEEF);
        uint256 recvBefore = IERC20(clankerToken).balanceOf(receiver);
        uint256 cap = ILevrFactory_v1(address(factory)).getTransferTier(0);
        uint256 amount = treasBal < cap ? treasBal : cap;
        if (amount == 0) amount = treasBal;
        uint256 pid = ILevrGovernor_v1(governor).proposeTransfer(
            receiver,
            amount,
            "ops",
            0
        );
        ILevrGovernor_v1(governor).execute(pid);
        uint256 recvAfter = IERC20(clankerToken).balanceOf(receiver);
        assertEq(recvAfter - recvBefore, amount);

        // Exceed tier limit should revert
        uint256 tooMuch = cap + 1;
        vm.expectRevert(ILevrGovernor_v1.InvalidAmount.selector);
        ILevrGovernor_v1(governor).proposeTransfer(
            receiver,
            tooMuch,
            "too much",
            0
        );
    }

    function test_min_balance_gating_and_deadline_enforcement() public {
        // Create stricter config
        ILevrFactory_v1.TierConfig[]
            memory ttiers = new ILevrFactory_v1.TierConfig[](1);
        ttiers[0] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
        ILevrFactory_v1.TierConfig[]
            memory btiers = new ILevrFactory_v1.TierConfig[](1);
        btiers[0] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1
            .FactoryConfig({
                protocolFeeBps: 0,
                submissionDeadlineSeconds: 1 days,
                maxSubmissionPerType: 0,
                streamWindowSeconds: 3 days,
                transferTiers: ttiers,
                stakingBoostTiers: btiers,
                minWTokenToSubmit: 1,
                protocolTreasury: protocolTreasury
            });
        LevrFactory_v1 strictFactory = new LevrFactory_v1(cfg, address(this));

        (
            address governor,
            address treasury,
            address staking,

        ) = _deployRegisterAndGet(address(strictFactory));

        // Without stake, proposing should revert
        vm.expectRevert(ILevrGovernor_v1.NotAuthorized.selector);
        ILevrGovernor_v1(governor).proposeBoost(100 ether, 0);

        // Get tokens and stake part to satisfy minWTokenToSubmit (set to 1 wei)
        uint256 userGot = _acquireFromLocker(address(this), 1_000 ether);
        assertTrue(userGot > 0, "need tokens from locker");
        uint256 stakeAmt = userGot / 2;
        uint256 sendAmt = userGot - stakeAmt;
        IERC20(clankerToken).approve(staking, stakeAmt);
        ILevrStaking_v1(staking).stake(stakeAmt);

        // Now propose succeeds: fund treasury from user's remaining balance if needed
        uint256 tBal = IERC20(clankerToken).balanceOf(treasury);
        if (tBal == 0 && sendAmt > 0) {
            IERC20(clankerToken).transfer(treasury, sendAmt);
            tBal = sendAmt;
        }
        uint256 boostAmt = tBal / 2;
        if (boostAmt == 0) boostAmt = tBal;
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt, 0);

        // After deadline passes, execute should revert
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ILevrGovernor_v1.DeadlinePassed.selector);
        ILevrGovernor_v1(governor).execute(pid);
    }
}
