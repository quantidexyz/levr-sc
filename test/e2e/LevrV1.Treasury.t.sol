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

contract LevrV1_TreasuryE2E is BaseForkTest {
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

    function test_headless_treasury_airdrop_and_boost_flow() public {
        // 1) Pre-deploy a headless treasury (no underlying yet)
        address headlessTreasury = factory.deployTreasury();
        assertTrue(headlessTreasury != address(0));

        // 2) Deploy Clanker token with airdrop extension enabled and admin set to headless treasury
        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFullWithOptions({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: "CLK Air",
            symbol: "CLKA",
            clankerFeeBps: 100,
            pairedFeeBps: 100,
            enableAirdrop: true,
            airdropAdmin: headlessTreasury,
            airdropBps: 1000, // 10% supply to airdrop extension
            airdropData: bytes("")
        });

        // 3) Verify airdrop extension received allocation (on Base mainnet airdrop holds funds)
        address airdropExt = 0xf652B3610D75D81871bf96DB50825d9af28391E0;
        uint256 extBal = IERC20(clankerToken).balanceOf(airdropExt);
        assertGt(extBal, 0, "no airdrop minted to extension");

        // 4) Move some airdrop from extension to treasury (simulate extension forwarding)
        uint256 boostAmt = extBal > 1_000 ether ? 1_000 ether : extBal;
        vm.prank(airdropExt);
        IERC20(clankerToken).transfer(headlessTreasury, boostAmt);

        // 5) Register the project using the pre-deployed treasury
        (address governor, ) = factory.register(
            clankerToken,
            ILevrFactory_v1.RegisterParams({
                treasury: headlessTreasury,
                extraConfig: bytes("")
            })
        );
        (, , address staking, ) = factory.getProjectContracts(clankerToken);

        // 6) Stake some user funds to be eligible for rewards
        uint256 userGot = _acquireFromLocker(address(this), 1_000 ether);
        if (userGot > 0) {
            uint256 stakeAmt = userGot / 2;
            IERC20(clankerToken).approve(staking, stakeAmt);
            ILevrStaking_v1(staking).stake(stakeAmt);
        }

        // 7) Execute a boost using the airdrop forwarded to treasury
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt, 0);
        ILevrGovernor_v1(governor).execute(pid);

        // 8) Streaming and claim sanity check
        vm.warp(block.timestamp + 1 hours);
        address[] memory toks = new address[](1);
        toks[0] = clankerToken;
        uint256 balBefore = IERC20(clankerToken).balanceOf(address(this));
        ILevrStaking_v1(staking).claimRewards(toks, address(this));
        uint256 balAfter = IERC20(clankerToken).balanceOf(address(this));
        uint256 claimed = balAfter - balBefore;
        assertGt(claimed, 0, "nothing claimed after boost");
    }

    function test_user_stake_boost_claim_unstake_flow() public {
        // Use default factory config from setUp()
        (
            address governor,
            address treasury,
            address staking,
            address stakedToken
        ) = _deployRegisterAndGet(address(factory));

        // Get some underlying to the user from locker and split between stake and treasury funding
        uint256 userGot = _acquireFromLocker(address(this), 1_000 ether);
        assertTrue(userGot > 0, "need some tokens to stake");
        uint256 stakeAmt = userGot / 2;
        uint256 boostAmt = userGot - stakeAmt;

        // Stake half
        IERC20(clankerToken).approve(staking, stakeAmt);
        ILevrStaking_v1(staking).stake(stakeAmt);
        assertEq(
            ILevrStaking_v1(staking).stakedBalanceOf(address(this)),
            stakeAmt
        );

        // Fund treasury with the rest
        IERC20(clankerToken).transfer(treasury, boostAmt);

        // Boost via governor using treasury funds
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt, 0);
        ILevrGovernor_v1(governor).execute(pid);

        // Let some time pass and claim; with streaming, claim ~ boostAmt * elapsed/window
        vm.warp(block.timestamp + 1 hours);
        address[] memory toks = new address[](1);
        toks[0] = clankerToken;
        uint256 balBefore = IERC20(clankerToken).balanceOf(address(this));
        ILevrStaking_v1(staking).claimRewards(toks, address(this));
        uint256 balAfter = IERC20(clankerToken).balanceOf(address(this));
        uint256 claimed = balAfter - balBefore;
        assertApproxEqRel(claimed, (boostAmt * 1 hours) / (3 days), 3e16);

        // Unstake
        uint256 stakeBal = ILevrStaking_v1(staking).stakedBalanceOf(
            address(this)
        );
        ILevrStaking_v1(staking).unstake(stakeBal, address(this));
        assertEq(ILevrStaking_v1(staking).stakedBalanceOf(address(this)), 0);
        // Staked token total supply should drop to zero
        assertEq(IERC20(stakedToken).totalSupply(), 0);
    }

    function test_treasury_registration_frontrun_protection() public {
        // First deploy a Clanker token that both Alice and Bob will try to register with
        ClankerDeployer d = new ClankerDeployer();
        address sharedClankerToken = d.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: "Shared Token",
            symbol: "SHR",
            clankerFeeBps: 100,
            pairedFeeBps: 100
        });

        // Alice deploys a headless treasury
        address alice = address(0x1111);
        vm.prank(alice);
        address aliceTreasury = factory.deployTreasury();

        // Bob tries to frontrun Alice's registration by registering the shared token with Alice's treasury
        address bob = address(0x2222);
        vm.prank(bob);

        // Bob tries to register the shared token with Alice's treasury - should fail
        vm.expectRevert(
            ILevrFactory_v1.UnauthorizedTreasuryRegistration.selector
        );
        factory.register(
            sharedClankerToken,
            ILevrFactory_v1.RegisterParams({
                treasury: aliceTreasury,
                extraConfig: bytes("")
            })
        );

        // Alice can successfully register the shared token with her own treasury
        vm.prank(alice);
        (address governor, ) = factory.register(
            sharedClankerToken,
            ILevrFactory_v1.RegisterParams({
                treasury: aliceTreasury,
                extraConfig: bytes("")
            })
        );

        // Verify Alice's treasury is registered with the shared token
        (, address registeredGovernor, , ) = factory.getProjectContracts(
            sharedClankerToken
        );
        assertEq(registeredGovernor, governor);
    }

    function test_apy_views_work_correctly() public {
        // Deploy and register project
        (
            address governor,
            address treasury,
            address staking,
            address stakedToken
        ) = _deployRegisterAndGet(address(factory));

        // Get tokens for staking and boosting
        uint256 userGot = _acquireFromLocker(address(this), 10_000 ether);
        assertTrue(userGot > 0, "need tokens from locker");

        // Stake 50% of tokens
        uint256 stakeAmt = userGot / 2;
        IERC20(clankerToken).approve(staking, stakeAmt);
        ILevrStaking_v1(staking).stake(stakeAmt);

        // Verify initial state: no rewards accrued yet
        uint256 initialApr = ILevrStaking_v1(staking).aprBps(address(this));
        uint256 initialRate = ILevrStaking_v1(staking).rewardRatePerSecond(
            clankerToken
        );
        assertEq(initialApr, 0, "initial APR should be 0");
        assertEq(initialRate, 0, "initial reward rate should be 0");

        // Fund treasury and execute boost
        uint256 boostAmt = userGot - stakeAmt;
        IERC20(clankerToken).transfer(treasury, boostAmt);
        uint256 pid = ILevrGovernor_v1(governor).proposeBoost(boostAmt, 0);
        ILevrGovernor_v1(governor).execute(pid);

        // Now check APR and reward rate calculations
        uint256 aprAfterBoost = ILevrStaking_v1(staking).aprBps(address(this));
        uint256 rateAfterBoost = ILevrStaking_v1(staking).rewardRatePerSecond(
            clankerToken
        );

        // APR calculation: (boostAmt * 365 days / 3 days) * 10000 / stakeAmt
        // rate = boostAmt / 3 days
        uint256 expectedRate = boostAmt / 3 days;
        uint256 expectedAnnual = expectedRate * 365 days;
        uint256 expectedAprBps = (expectedAnnual * 10_000) / stakeAmt;

        assertApproxEqRel(
            aprAfterBoost,
            expectedAprBps,
            1e16,
            "APR should match calculation"
        ); // 1% tolerance
        assertApproxEqRel(
            rateAfterBoost,
            expectedRate,
            1e16,
            "reward rate should match calculation"
        );

        // Let some time pass and check rate doesn't change (linear emission)
        vm.warp(block.timestamp + 1 hours);
        uint256 rateAfterTime = ILevrStaking_v1(staking).rewardRatePerSecond(
            clankerToken
        );
        assertEq(
            rateAfterTime,
            rateAfterBoost,
            "rate should not change during stream"
        );

        // APR should remain the same (annualized)
        uint256 aprAfterTime = ILevrStaking_v1(staking).aprBps(address(this));
        assertEq(
            aprAfterTime,
            aprAfterBoost,
            "APR should not change during stream"
        );

        // Claim some rewards and verify APR still works
        vm.warp(block.timestamp + 1 days);
        address[] memory toks = new address[](1);
        toks[0] = clankerToken;
        ILevrStaking_v1(staking).claimRewards(toks, address(this));

        uint256 aprAfterClaim = ILevrStaking_v1(staking).aprBps(address(this));
        assertEq(
            aprAfterClaim,
            aprAfterBoost,
            "APR should remain same after claim"
        );

        // Test edge case: unstake all, APR should become 0
        ILevrStaking_v1(staking).unstake(stakeAmt, address(this));
        uint256 aprAfterUnstake = ILevrStaking_v1(staking).aprBps(
            address(this)
        );
        assertEq(aprAfterUnstake, 0, "APR should be 0 when no tokens staked");

        // Rate should still exist (stream continues)
        uint256 rateAfterUnstake = ILevrStaking_v1(staking).rewardRatePerSecond(
            clankerToken
        );
        assertEq(
            rateAfterUnstake,
            expectedRate,
            "rate should continue after unstake"
        );
    }
}
