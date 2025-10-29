// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Midstream Accrual Tests - Consolidation
 * @notice Tests for mid-stream reward accrual scenarios (frequency & edge cases)
 * @dev Consolidated: Removed duplicates covered in LevrStakingV1.t.sol
 *      Kept: Frequency tests and specific bug reproductions
 */
contract LevrStakingV1MidstreamAccrualTest is Test {
    uint256 constant INITIAL_STAKE = 10_000_000 * 1e18;
    uint256 constant STREAM_WINDOW = 3 days;

    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;

    address alice = address(0xA11CE);
    address treasury = address(0x1234);

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: uint32(STREAM_WINDOW),
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            maxRewardTokens: 50
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));
        underlying = new MockERC20('Underlying Token', 'UND');
        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        vm.prank(address(factory));
        staking.initialize(address(underlying), address(stakedToken), treasury, address(factory));

        underlying.mint(alice, INITIAL_STAKE);
        vm.startPrank(alice);
        underlying.approve(address(staking), INITIAL_STAKE);
        staking.stake(INITIAL_STAKE);
        vm.stopPrank();
    }

    /// @notice Test daily accrual frequency (realistic Clanker fee scenario)
    function test_accrualFrequency_daily() public {
        uint256 dailyFees = 10_000 * 1e18;
        uint256 totalAccrued = 0;

        // Simulate 5 days of daily fee accruals during 3-day stream
        for (uint256 day = 0; day < 5; day++) {
            underlying.mint(address(staking), dailyFees);
            staking.accrueRewards(address(underlying));
            totalAccrued += dailyFees;
            vm.warp(block.timestamp + 1 days);
        }

        // Wait for last stream to complete
        vm.warp(block.timestamp + STREAM_WINDOW);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;

        // With the fix, should claim almost all rewards (within rounding)
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all rewards with daily accruals'
        );
    }

    /// @notice Test hourly accrual frequency (worst case stress test)
    function test_accrualFrequency_hourly() public {
        uint256 hourlyFees = 100 * 1e18;
        uint256 totalAccrued = 0;
        uint256 hoursToTest = 24; // Test first day

        for (uint256 hour = 0; hour < hoursToTest; hour++) {
            underlying.mint(address(staking), hourlyFees);
            staking.accrueRewards(address(underlying));
            totalAccrued += hourlyFees;
            vm.warp(block.timestamp + 1 hours);
        }

        // Complete last stream
        vm.warp(block.timestamp + STREAM_WINDOW);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;

        // Hourly accruals should all be preserved
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all rewards with hourly accruals'
        );
    }

    /// @notice Exact bug reproduction: 600K then 1K midstream
    function test_exactBugReproduction_600K_then_1K_FIXED() public {
        // Initial accrual: 600K
        uint256 initial = 600_000 * 1e18;
        underlying.mint(address(staking), initial);
        staking.accrueRewards(address(underlying));

        // Wait 1 day (1/3 of stream)
        vm.warp(block.timestamp + 1 days);

        // Mid-stream accrual: 1K
        uint256 midstream = 1_000 * 1e18;
        underlying.mint(address(staking), midstream);
        staking.accrueRewards(address(underlying));

        // Complete second stream
        vm.warp(staking.streamEnd());

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;

        // Measure what's stuck AFTER claiming
        uint256 balance = underlying.balanceOf(address(staking));
        uint256 escrow = staking.escrowBalance(address(underlying));
        uint256 stuck = balance - escrow;

        // Verify the FIX: should claim ALL rewards with nothing stuck
        assertEq(stuck, 0, 'No rewards should be stuck (FIX VERIFIED)');
        assertApproxEqRel(
            claimed,
            initial + midstream,
            0.001e18,
            'Should claim all accrued rewards (FIX VERIFIED)'
        );
    }
}
