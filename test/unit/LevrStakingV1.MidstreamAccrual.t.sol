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
 * @title LevrStakingV1MidstreamAccrualTest
 * @notice Comprehensive tests for mid-stream reward accrual scenarios
 * @dev These tests would have caught the unvested reward loss bug
 */
contract LevrStakingV1MidstreamAccrualTest is Test {
    // ---
    // CONSTANTS

    uint256 constant INITIAL_STAKE = 10_000_000 * 1e18;
    uint256 constant STREAM_WINDOW = 3 days;

    // ---
    // VARIABLES

    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
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
            maxRewardTokens: 50 // Max non-whitelisted reward tokens
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

        // Setup alice with initial stake
        underlying.mint(alice, INITIAL_STAKE);
        vm.startPrank(alice);
        underlying.approve(address(staking), INITIAL_STAKE);
        staking.stake(INITIAL_STAKE);
        vm.stopPrank();
    }

    /// @notice Test that multiple accruals within the same stream window preserve all rewards
    /// @dev With the fix, all rewards should be preserved
    function test_multipleAccrualsWithinStreamWindow() public {
        console2.log('=== MULTIPLE ACCRUALS WITHIN STREAM WINDOW ===\n');

        // First accrual: 600K tokens
        uint256 firstAccrual = 600_000 * 1e18;
        underlying.mint(address(staking), firstAccrual);
        staking.accrueRewards(address(underlying));
        console2.log('First accrual:', firstAccrual / 1e18, 'tokens');

        // Wait 1 day (1/3 of stream)
        vm.warp(block.timestamp + 1 days);
        console2.log('Time passed: 1 day (1/3 of stream)');

        // Second accrual: 1K tokens
        uint256 secondAccrual = 1_000 * 1e18;
        underlying.mint(address(staking), secondAccrual);
        staking.accrueRewards(address(underlying));
        console2.log('Second accrual:', secondAccrual / 1e18, 'tokens');

        // Fast forward to end of second stream
        vm.warp(staking.streamEnd());

        // Claim all rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balanceBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balanceAfterClaim = underlying.balanceOf(alice);

        uint256 claimed = balanceAfterClaim - balanceBefore;
        uint256 totalAccrued = firstAccrual + secondAccrual;

        console2.log('\n=== RESULTS ===');
        console2.log('Total accrued:', totalAccrued / 1e18, 'tokens');
        console2.log('Total claimed:', claimed / 1e18, 'tokens');
        console2.log('Lost:', (totalAccrued - claimed) / 1e18, 'tokens');

        // With the fix, should claim all accrued rewards
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all accrued rewards (fix verified)'
        );
    }

    /// @notice Test that partially vested stream preservation works
    function test_partiallyVestedStreamPreservation() public {
        console2.log('=== PARTIALLY VESTED STREAM PRESERVATION ===\n');

        uint256 accrual = 300_000 * 1e18;

        // Accrue and partially vest (50%)
        underlying.mint(address(staking), accrual);
        staking.accrueRewards(address(underlying));

        vm.warp(block.timestamp + (STREAM_WINDOW / 2));
        uint256 expectedVested = accrual / 2;
        console2.log('Expected vested after 50% time:', expectedVested / 1e18);

        // Accrue small amount mid-stream
        uint256 smallAccrual = 100 * 1e18;
        underlying.mint(address(staking), smallAccrual);
        staking.accrueRewards(address(underlying));

        // Complete new stream
        vm.warp(staking.streamEnd());

        // Check claimable
        uint256 claimable = staking.claimableRewards(alice, address(underlying));
        console2.log('Claimable:', claimable / 1e18);
        console2.log('Expected:', (accrual + smallAccrual) / 1e18);

        // With the fix, should preserve all rewards
        assertApproxEqRel(
            claimable,
            accrual + smallAccrual,
            0.001e18,
            'Should preserve unvested rewards (fix verified)'
        );
    }

    /// @notice Test daily accrual frequency (realistic Clanker fee scenario)
    function test_accrualFrequency_daily() public {
        console2.log('=== DAILY ACCRUAL FREQUENCY ===\n');

        uint256 dailyFees = 10_000 * 1e18;
        uint256 totalAccrued = 0;

        // Simulate 5 days of daily fee accruals during 3-day stream
        for (uint256 day = 0; day < 5; day++) {
            underlying.mint(address(staking), dailyFees);
            staking.accrueRewards(address(underlying));
            totalAccrued += dailyFees;

            console2.log('Day', day);
            console2.log('  Accrued', dailyFees / 1e18);

            vm.warp(block.timestamp + 1 days);
        }

        // Wait for last stream to complete
        vm.warp(block.timestamp + STREAM_WINDOW);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;

        console2.log('\n=== RESULTS ===');
        console2.log('Total accrued over 5 days:', totalAccrued / 1e18);
        console2.log('Total claimed:', claimed / 1e18);
        console2.log('Lost:', (totalAccrued - claimed) / 1e18);

        // With the fix, should claim almost all rewards (within rounding)
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all rewards with daily accruals (fix verified)'
        );
    }

    /// @notice Test hourly accrual frequency (worst case)
    function test_accrualFrequency_hourly() public {
        console2.log('=== HOURLY ACCRUAL FREQUENCY ===\n');

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

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;
        uint256 lost = totalAccrued - claimed;

        console2.log('\n=== RESULTS ===');
        console2.log('Total accrued (24 hours):', totalAccrued / 1e18);
        console2.log('Total claimed:', claimed / 1e18);
        console2.log('Lost:', lost / 1e18);
        console2.log('Loss percentage:', (lost * 100) / totalAccrued, '%');

        // With the fix, should claim almost all rewards
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all rewards with hourly accruals (fix verified)'
        );
    }

    /// @notice Test that unvested rewards are not lost (invariant test)
    function test_unvestedRewardsNotLost() public {
        console2.log('=== UNVESTED REWARDS NOT LOST (INVARIANT) ===\n');

        uint256 firstAccrual = 1_000_000 * 1e18;
        underlying.mint(address(staking), firstAccrual);
        staking.accrueRewards(address(underlying));

        // Wait for 25% of stream
        vm.warp(block.timestamp + (STREAM_WINDOW / 4));

        // Check state before second accrual
        uint256 stakingBalance = underlying.balanceOf(address(staking));
        uint256 escrowBalance = staking.escrowBalance(address(underlying));
        uint256 unaccounted = stakingBalance - escrowBalance;

        console2.log('Before second accrual:');
        console2.log('  Staking balance:', stakingBalance / 1e18);
        console2.log('  Escrow:', escrowBalance / 1e18);
        console2.log('  Unaccounted:', unaccounted / 1e18);

        // Second accrual
        uint256 secondAccrual = 50_000 * 1e18;
        underlying.mint(address(staking), secondAccrual);
        staking.accrueRewards(address(underlying));

        // Check state after second accrual
        stakingBalance = underlying.balanceOf(address(staking));
        escrowBalance = staking.escrowBalance(address(underlying));
        unaccounted = stakingBalance - escrowBalance;

        console2.log('\nAfter second accrual:');
        console2.log('  Staking balance:', stakingBalance / 1e18);
        console2.log('  Escrow:', escrowBalance / 1e18);
        console2.log('  Unaccounted:', unaccounted / 1e18);

        // Complete both streams
        vm.warp(staking.streamEnd());

        // Claim all
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;
        uint256 totalAccrued = firstAccrual + secondAccrual;

        // Final state
        stakingBalance = underlying.balanceOf(address(staking));
        escrowBalance = staking.escrowBalance(address(underlying));
        uint256 stuckRewards = stakingBalance - escrowBalance;

        console2.log('\n=== FINAL STATE ===');
        console2.log('Total accrued:', totalAccrued / 1e18);
        console2.log('Total claimed:', claimed / 1e18);
        console2.log('Stuck in contract:', stuckRewards / 1e18);

        // INVARIANT: No rewards should be stuck (fix verified)
        assertEq(stuckRewards, 0, 'No rewards should be stuck in contract (fix verified)');
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all accrued rewards (fix verified)'
        );
    }

    /// @notice Fuzz test: No rewards should ever be lost regardless of timing
    function testFuzz_noRewardsLost(
        uint256 firstAmount,
        uint256 secondAmount,
        uint256 timeBetweenAccruals
    ) public {
        // Bound inputs to reasonable ranges
        firstAmount = bound(firstAmount, 1000 * 1e18, 10_000_000 * 1e18);
        secondAmount = bound(secondAmount, 100 * 1e18, 1_000_000 * 1e18);
        timeBetweenAccruals = bound(timeBetweenAccruals, 1 hours, STREAM_WINDOW - 1);

        // First accrual
        underlying.mint(address(staking), firstAmount);
        staking.accrueRewards(address(underlying));

        // Wait random time
        vm.warp(block.timestamp + timeBetweenAccruals);

        // Second accrual
        underlying.mint(address(staking), secondAmount);
        staking.accrueRewards(address(underlying));

        // Complete stream
        vm.warp(staking.streamEnd());

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;
        uint256 totalAccrued = firstAmount + secondAmount;

        // INVARIANT: All accrued rewards should be claimable
        // THIS WILL FAIL for most random inputs
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18, // 0.1% tolerance for rounding
            'All accrued rewards should be claimable'
        );
    }

    /// @notice Test scenario: Complete first stream before second accrual (should work)
    function test_accrualAfterStreamComplete() public {
        console2.log('=== ACCRUAL AFTER STREAM COMPLETE (CORRECT USAGE) ===\n');

        // First accrual
        uint256 firstAccrual = 500_000 * 1e18;
        underlying.mint(address(staking), firstAccrual);
        staking.accrueRewards(address(underlying));

        // Wait for COMPLETE stream using streamEnd() to ensure precision
        uint64 streamEnd1 = staking.streamEnd();
        vm.warp(streamEnd1);

        // Second accrual (after first completes)
        uint256 secondAccrual = 100_000 * 1e18;
        underlying.mint(address(staking), secondAccrual);
        staking.accrueRewards(address(underlying));

        // Wait for second stream to complete - claim AT end, not after
        uint64 streamEnd2 = staking.streamEnd();
        vm.warp(streamEnd2);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;
        uint256 totalAccrued = firstAccrual + secondAccrual;

        console2.log('Total accrued:', totalAccrued / 1e18);
        console2.log('Total claimed:', claimed / 1e18);

        // With proper timing, should claim all rewards
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all rewards when streams complete (fix verified)'
        );
    }

    /// @notice Test to verify the fix works for the exact bug scenario
    function test_exactBugReproduction_600K_then_1K_FIXED() public {
        console2.log('=== EXACT BUG REPRODUCTION (600K + 1K) ===\n');

        // Initial accrual: 600K
        uint256 initial = 600_000 * 1e18;
        underlying.mint(address(staking), initial);
        staking.accrueRewards(address(underlying));

        uint64 streamEnd1 = staking.streamEnd();
        console2.log('First stream ends at:', streamEnd1);

        // Wait 1 day (1/3 of stream)
        vm.warp(block.timestamp + 1 days);

        // Mid-stream accrual: 1K
        uint256 midstream = 1_000 * 1e18;
        underlying.mint(address(staking), midstream);
        staking.accrueRewards(address(underlying));

        uint64 streamEnd2 = staking.streamEnd();
        console2.log('Second stream ends at:', streamEnd2);

        // Complete second stream
        vm.warp(streamEnd2);

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

        console2.log('\n=== CONTRACT STATE ===');
        console2.log('Balance:', balance / 1e18);
        console2.log('Escrow:', escrow / 1e18);
        console2.log('Stuck (should be 400K):', stuck / 1e18);

        console2.log('\n=== RESULTS ===');
        console2.log('Total accrued:', (initial + midstream) / 1e18);
        console2.log('Claimed:', claimed / 1e18);
        console2.log('Lost forever:', stuck / 1e18);

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
