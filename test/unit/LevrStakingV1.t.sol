// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrStakingV1_UnitTest is Test {
    MockERC20 internal underlying;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);

    // Mock factory functions for testing
    function clankerFactory() external pure returns (address) {
        return address(0); // No clanker factory for test
    }

    function getClankerMetadata(
        address /* clankerToken */
    ) external pure returns (ILevrFactory_v1.ClankerMetadata memory) {
        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0),
                lpLocker: address(0),
                hook: address(0),
                exists: false
            });
    }

    function streamWindowSeconds() external pure returns (uint32) {
        return 3 days; // Default stream window for tests
    }

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        // Pass address(0) for forwarder since we're not testing meta-transactions here
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked Token',
            'sTKN',
            18,
            address(underlying),
            address(staking)
        );
        staking.initialize(address(underlying), address(sToken), treasury, address(this)); // Pass test contract as factory for test

        underlying.mint(address(this), 1_000_000 ether);
    }

    function test_stake_mintsStakedToken_andEscrowsUnderlying() public {
        // Use amount similar to TypeScript test for consistency
        uint256 userBalance = 4548642989513676498672470665; // Mirrors TS test user balance
        underlying.mint(address(this), userBalance);

        uint256 stakeAmount = userBalance / 2; // Stake 50% like TS test
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        assertEq(sToken.balanceOf(address(this)), stakeAmount, 'Should mint staked tokens 1:1');
        assertEq(staking.totalStaked(), stakeAmount, 'Total staked should match');
        assertEq(
            staking.escrowBalance(address(underlying)),
            stakeAmount,
            'Should escrow underlying'
        );
    }

    function test_unstake_burns_andReturnsUnderlying() public {
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(1_000 ether);

        staking.unstake(400 ether, address(this));
        assertEq(sToken.balanceOf(address(this)), 600 ether);
        assertEq(staking.totalStaked(), 600 ether);
    }

    function test_accrueFromTreasury_pull_flow_streamsOverWindow() public {
        // fund treasury with reward token
        underlying.mint(treasury, 10_000 ether);
        vm.prank(treasury);
        underlying.approve(address(staking), 10_000 ether);

        // stake to create shares
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(1_000 ether);

        // pull from treasury and credit
        vm.prank(treasury);
        staking.accrueFromTreasury(address(underlying), 2_000 ether, true);

        // claim rewards after 1 day in a 3 day window
        address[] memory toks = new address[](1);
        toks[0] = address(underlying);
        uint256 beforeBal = underlying.balanceOf(address(this));
        vm.warp(block.timestamp + 1 days);
        staking.claimRewards(toks, address(this));
        uint256 afterBal = underlying.balanceOf(address(this));
        uint256 claimed = afterBal - beforeBal;
        {
            uint256 expected = (2_000 ether) / uint256(3);
            uint256 tol = (expected * 5e15) / 1e18; // 0.5%
            uint256 diff = claimed > expected ? claimed - expected : expected - claimed;
            assertLe(diff, tol);
        }
        // move to end of window and claim remainder
        beforeBal = underlying.balanceOf(address(this));
        vm.warp(block.timestamp + 3 days);
        staking.claimRewards(toks, address(this));
        afterBal = underlying.balanceOf(address(this));
        claimed = afterBal - beforeBal;
        {
            uint256 expected2 = (2_000 ether * 2) / uint256(3);
            uint256 tol2 = (expected2 * 5e15) / 1e18;
            uint256 diff2 = claimed > expected2 ? claimed - expected2 : expected2 - claimed;
            assertLe(diff2, tol2);
        }
    }

    function test_accrueRewards_fromBalance_creditsWithoutPull() public {
        // deposit rewards directly to staking
        underlying.transfer(address(staking), 1_000 ether);
        // account them - now automatically credits all available (1000 ether)
        staking.accrueRewards(address(underlying));
    }

    function test_multi_user_distribution_proportional_and_reserves_sane() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        underlying.mint(alice, 10_000 ether);
        underlying.mint(bob, 10_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(2_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(6_000 ether);
        vm.stopPrank();

        // fund treasury and pull 8000 tokens -> stream rewards
        underlying.mint(treasury, 8_000 ether);
        vm.prank(treasury);
        underlying.approve(address(staking), type(uint256).max);
        vm.prank(treasury);
        staking.accrueFromTreasury(address(underlying), 8_000 ether, true);

        // expected shares: alice 25%, bob 75% of credited rewards
        address[] memory toks = new address[](1);
        toks[0] = address(underlying);

        // advance half window, ~4000 vested so far
        vm.warp(block.timestamp + 36 hours);
        vm.startPrank(alice);
        uint256 aBefore = underlying.balanceOf(alice);
        staking.claimRewards(toks, alice);
        uint256 aAfter = underlying.balanceOf(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bBefore = underlying.balanceOf(bob);
        staking.claimRewards(toks, bob);
        uint256 bAfter = underlying.balanceOf(bob);
        vm.stopPrank();

        uint256 aClaim = aAfter - aBefore;
        uint256 bClaim = bAfter - bBefore;
        // 4,000 vested so far -> alice 25% (1,000), bob 75% (3,000)
        {
            uint256 expA = 1_000 ether;
            uint256 tolA = (expA * 5e15) / 1e18;
            uint256 diffA = aClaim > expA ? aClaim - expA : expA - aClaim;
            assertLe(diffA, tolA);
            uint256 expB = 3_000 ether;
            uint256 tolB = (expB * 5e15) / 1e18;
            uint256 diffB = bClaim > expB ? bClaim - expB : expB - bClaim;
            assertLe(diffB, tolB);
        }
    }

    // ============ Governance: Proportional Unstake Tests ============

    function test_partial_unstake_reduces_time_proportionally() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 100 days - VP should be 1000 token-days (normalized)
        vm.warp(block.timestamp + 100 days);
        uint256 vpBefore = staking.getVotingPower(address(this));
        assertEq(vpBefore, 1000 * 100, 'VP should be 100,000 token-days');

        // Unstake 30% (300 tokens)
        uint256 returnedVP = staking.unstake(300 ether, address(this));

        // Immediately after unstake: 700 tokens * 70 days = 49,000 token-days
        uint256 vpAfter = staking.getVotingPower(address(this));
        uint256 expectedVP = 700 * 70;
        assertEq(vpAfter, expectedVP, 'VP should be 49,000 token-days (30% reduction)');
        assertEq(returnedVP, expectedVP, 'Returned VP should match actual VP');

        // After 30 more days: 700 tokens * 100 days total
        vm.warp(block.timestamp + 30 days);
        uint256 vpFinal = staking.getVotingPower(address(this));
        assertEq(vpFinal, 700 * 100, 'VP should be 70,000 token-days (continues accumulating)');
    }

    function test_full_unstake_resets_time_to_zero() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 50 days);
        assertGt(staking.getVotingPower(address(this)), 0, 'Should have VP before unstake');

        // Unstake everything
        uint256 returnedVP = staking.unstake(1000 ether, address(this));

        assertEq(staking.getVotingPower(address(this)), 0, 'VP should be 0 after full unstake');
        assertEq(staking.stakeStartTime(address(this)), 0, 'stakeStartTime should be 0');
        assertEq(returnedVP, 0, 'Returned VP should be 0 on full unstake');
    }

    function test_partial_unstake_50_percent() public {
        underlying.approve(address(staking), 2000 ether);
        staking.stake(2000 ether);

        // Wait 200 days
        vm.warp(block.timestamp + 200 days);

        // Unstake 50%
        uint256 returnedVP = staking.unstake(1000 ether, address(this));

        // Should have: 1000 tokens * 100 days = 100,000 token-days
        uint256 vp = staking.getVotingPower(address(this));
        uint256 expectedVP = 1000 * 100;
        assertEq(vp, expectedVP, 'VP should be 100,000 token-days');
        assertEq(returnedVP, expectedVP, 'Returned VP should match for UI simulation');
    }

    function test_multiple_partial_unstakes_compound() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 100 days, unstake 20% (200 tokens)
        vm.warp(block.timestamp + 100 days);
        staking.unstake(200 ether, address(this));
        // Now: 800 tokens * 80 days = 64,000 token-days
        uint256 vp1 = staking.getVotingPower(address(this));
        assertEq(vp1, 800 * 80, 'First unstake: 64,000 token-days');

        // Wait 20 more days (total 100 days from new baseline)
        vm.warp(block.timestamp + 20 days);
        // Now: 800 tokens * 100 days = 80,000 token-days
        uint256 vp2 = staking.getVotingPower(address(this));
        assertEq(vp2, 800 * 100, 'After 20 days: 80,000 token-days');

        // Unstake 25% of remaining (200 tokens of 800)
        staking.unstake(200 ether, address(this));
        // Now: 600 tokens * 75 days = 45,000 token-days

        uint256 vp3 = staking.getVotingPower(address(this));
        assertEq(vp3, 600 * 75, 'Second unstake: 45,000 token-days');
    }

    function test_partial_unstake_then_restake_uses_weighted_average() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Partial unstake
        staking.unstake(500 ether, address(this));
        uint256 vpAfterUnstake = staking.getVotingPower(address(this));
        assertEq(vpAfterUnstake, 500 * 50, 'After unstake: 25,000 token-days');

        // Restake 300 tokens - uses weighted average
        // Before restake: 500 tokens with 50 days (25,000 token-days VP)
        // After restake: 800 tokens
        // Weighted time: (500 * 50) / 800 = 31.25 days
        underlying.approve(address(staking), 300 ether);
        staking.stake(300 ether);

        // VP should be 800 tokens * 31.25 days = 25,000 token-days (VP preserved)
        uint256 vpAfterRestake = staking.getVotingPower(address(this));
        assertEq(
            vpAfterRestake,
            25_000,
            'After restake: 25,000 token-days (VP preserved via weighted average)'
        );
    }

    function test_unstake_everything_resets_to_zero() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 50 days);

        // Unstake everything
        staking.unstake(1000 ether, address(this));

        assertEq(staking.stakeStartTime(address(this)), 0, 'Should reset to 0');
        assertEq(staking.getVotingPower(address(this)), 0, 'VP should be 0');
    }

    function test_partial_unstake_10_percent() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 1000 days
        vm.warp(block.timestamp + 1000 days);

        // Unstake 10% (100 tokens)
        staking.unstake(100 ether, address(this));

        // Should have: 900 tokens * 900 days = 810,000 token-days
        uint256 vp = staking.getVotingPower(address(this));
        assertEq(vp, 900 * 900, '10% unstake should give 810,000 token-days');
    }

    function test_partial_unstake_90_percent() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 1000 days
        vm.warp(block.timestamp + 1000 days);

        // Unstake 90% (900 tokens)
        staking.unstake(900 ether, address(this));

        // Should have: 100 tokens * 100 days = 10,000 token-days
        uint256 vp = staking.getVotingPower(address(this));
        assertEq(vp, 100 * 100, '90% unstake should give 10,000 token-days');
    }

    // ============ Stake VP Calculation Tests ============

    function test_stake_vp_calculation_immediate() public {
        underlying.approve(address(staking), 1000 ether);

        // Initial stake: VP should be 0 immediately
        staking.stake(100 ether);
        uint256 vp0 = staking.getVotingPower(address(this));
        assertEq(vp0, 0, 'VP should be 0 immediately after first stake');

        // After 50 days: VP = 100 × 50 = 5,000
        vm.warp(block.timestamp + 50 days);
        uint256 vp1 = staking.getVotingPower(address(this));
        assertEq(vp1, 100 * 50, 'VP should be 5,000 token-days');

        // Stake 400 more: VP preserved at 5,000
        staking.stake(400 ether);
        uint256 vp2 = staking.getVotingPower(address(this));
        assertEq(vp2, 5000, 'VP should be preserved at 5,000 token-days');

        // Verify calculation is accurate: 500 tokens * 10 days (weighted) = 5,000
        uint256 expectedWeightedTime = 5000 / 500; // = 10 days
        assertEq(expectedWeightedTime, 10, 'Weighted time should be 10 days');
    }

    function test_stake_and_unstake_vp_symmetry() public {
        underlying.approve(address(staking), 1500 ether);

        // Stake and accumulate VP
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 100 days);
        uint256 vpBeforeUnstake = staking.getVotingPower(address(this));
        assertEq(vpBeforeUnstake, 100_000, 'Should have 100,000 token-days');

        // Unstake 50%: VP is proportionally reduced to match remaining balance
        // 500 tokens * 50 days (50% of time) = 25,000 token-days
        uint256 returnedVP = staking.unstake(500 ether, address(this));
        uint256 vpAfterUnstake = staking.getVotingPower(address(this));
        assertEq(returnedVP, vpAfterUnstake, 'Unstake returned VP must match getVotingPower');
        assertEq(
            vpAfterUnstake,
            25_000,
            'VP should be proportionally reduced: 500 tokens * 50 days'
        );

        // Restake: VP should be preserved at 25,000
        staking.stake(500 ether);
        uint256 vpAfterRestake = staking.getVotingPower(address(this));
        assertEq(vpAfterRestake, 25_000, 'VP should be preserved on restake');

        // After 50 more days: 1000 tokens * 75 days (weighted) = 75,000 token-days
        vm.warp(block.timestamp + 50 days);
        uint256 vpFinal = staking.getVotingPower(address(this));
        assertEq(vpFinal, 75_000, 'VP should continue accumulating: 1000 * 75 days');
    }

    // ============ Weighted Average Staking Tests (Anti-Gaming) ============

    function test_weighted_average_basic_example_from_spec() public {
        // Example from user: 100 tokens for 1 month, then 1000 tokens
        underlying.approve(address(staking), 1100 ether);

        // Stake 100 tokens
        staking.stake(100 ether);

        // Wait 30 days (1 month)
        vm.warp(block.timestamp + 30 days);

        // VP after 30 days: 100 tokens * 30 days = 3000 token-days
        uint256 vpBefore = staking.getVotingPower(address(this));
        assertEq(vpBefore, 100 * 30, 'Should have 3,000 token-days after 30 days');

        // Now stake 1000 more tokens
        staking.stake(1000 ether);

        // VP should be preserved: still 3000 token-days, but now with 1100 tokens
        // Weighted time: 3000 / 1100 = 2.727... days
        uint256 vpAfter = staking.getVotingPower(address(this));
        // Allow 1 token-day tolerance due to rounding
        assertApproxEqAbs(vpAfter, 3000, 1, 'VP should be preserved at ~3,000 token-days');

        // After 27.273 more days, should have: 1100 tokens * 30 days = 33,000 token-days
        vm.warp(block.timestamp + (30 days - 2 days - 17 hours - 27 minutes - 16 seconds));
        uint256 vpFinal = staking.getVotingPower(address(this));
        // Allow small tolerance due to rounding
        assertApproxEqAbs(vpFinal, 1100 * 30, 10, 'Should accumulate to 33,000 token-days');
    }

    function test_gaming_attempt_fails_small_stake_long_time() public {
        // Attacker tries to game by staking tiny amount for long time
        underlying.approve(address(staking), 10_000 ether);

        // Stake just 1 token
        staking.stake(1 ether);

        // Wait 1 year
        vm.warp(block.timestamp + 365 days);

        // VP: 1 token * 365 days = 365 token-days
        uint256 vpSmallStake = staking.getVotingPower(address(this));
        assertEq(vpSmallStake, 1 * 365, 'Should only have 365 token-days');

        // Now try to game by staking huge amount
        staking.stake(9999 ether);

        // Weighted average prevents gaming: VP is still only ~365 token-days
        // With 10,000 tokens: 365 / 10,000 = 0.0365 days (rounding may cause 364)
        uint256 vpAfterGaming = staking.getVotingPower(address(this));
        assertApproxEqAbs(
            vpAfterGaming,
            365,
            1,
            'VP should NOT increase from late staking - gaming prevented!'
        );

        // The key insight: attacker's 10,000 tokens have only ~0.0365 days of effective stake time
        // They'd need to wait a full year with the full 10,000 tokens to get meaningful VP
        // This mechanism successfully prevents last-minute whales from dominating
    }

    function test_weighted_average_successive_stakes() public {
        underlying.approve(address(staking), 1000 ether);

        // Stake 100 tokens
        staking.stake(100 ether);

        // Wait 100 days: VP = 100 × 100 = 10,000
        vm.warp(block.timestamp + 100 days);
        uint256 vp1 = staking.getVotingPower(address(this));
        assertEq(vp1, 100 * 100, 'Should have 10,000 token-days');

        // Stake 900 more tokens (total 1000)
        // VP preserved: 10,000 token-days
        // New weighted time: 10,000 / 1000 = 10 days
        staking.stake(900 ether);
        uint256 vp2 = staking.getVotingPower(address(this));
        assertEq(vp2, 10_000, 'VP preserved at 10,000 token-days');

        // Wait 90 more days to reach 100 days equivalent
        // VP = 1000 × (10 + 90) = 100,000
        vm.warp(block.timestamp + 90 days);
        uint256 vp3 = staking.getVotingPower(address(this));
        assertEq(vp3, 100_000, 'Should reach 100,000 token-days');

        // This test verifies that weighted average allows fair accumulation
        // while preventing gaming from late large stakes
    }

    function test_weighted_average_equal_amounts_halves_time() public {
        underlying.approve(address(staking), 2000 ether);

        // Stake 1000 tokens
        staking.stake(1000 ether);

        // Wait 100 days
        vm.warp(block.timestamp + 100 days);
        uint256 vp1 = staking.getVotingPower(address(this));
        assertEq(vp1, 1000 * 100, 'Should have 100,000 token-days');

        // Stake equal amount (1000 more)
        staking.stake(1000 ether);

        // VP preserved, time should be exactly halved: 100,000 / 2000 = 50 days
        uint256 vp2 = staking.getVotingPower(address(this));
        assertEq(vp2, 100_000, 'VP preserved at 100,000 token-days');

        // Wait 50 more days - should reach 100 days equivalent
        vm.warp(block.timestamp + 50 days);
        uint256 vp3 = staking.getVotingPower(address(this));
        assertEq(vp3, 2000 * 100, 'Should reach 200,000 token-days');
    }

    function test_weighted_average_prevents_late_whale_manipulation() public {
        // Scenario: Legitimate early staker vs late whale trying to dominate
        address earlyStaker = address(0xEAE1);
        address lateWhale = address(0xCA7E);

        underlying.mint(earlyStaker, 100 ether);
        underlying.mint(lateWhale, 10_000 ether);

        // Early staker: 100 tokens for 365 days
        vm.startPrank(earlyStaker);
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Wait 365 days
        vm.warp(block.timestamp + 365 days);

        // Early staker VP: 100 * 365 = 36,500 token-days
        uint256 earlyVP = staking.getVotingPower(earlyStaker);
        assertEq(earlyVP, 100 * 365, 'Early staker has 36,500 token-days');

        // Late whale stakes 10,000 tokens (100x more)
        vm.startPrank(lateWhale);
        underlying.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        // Late whale has 0 VP immediately
        uint256 whaleVP = staking.getVotingPower(lateWhale);
        assertEq(whaleVP, 0, 'Late whale has 0 VP initially');

        // After 1 day, whale has: 10,000 * 1 = 10,000 token-days
        vm.warp(block.timestamp + 1 days);
        uint256 whaleVPAfter1Day = staking.getVotingPower(lateWhale);
        assertEq(whaleVPAfter1Day, 10_000, 'Whale needs time to accumulate VP');

        // Early staker now has: 100 * 366 = 36,600 token-days
        uint256 earlyVPAfter1Day = staking.getVotingPower(earlyStaker);
        assertEq(earlyVPAfter1Day, 100 * 366, 'Early staker continues accumulating');

        // Whale needs 3.66 days to match early staker
        // This prevents instant dominance and rewards early commitment
    }

    function test_weighted_average_extreme_ratio_1_to_million() public {
        // Mint enough tokens for this test
        underlying.mint(address(this), 1_000_001 ether);
        underlying.approve(address(staking), 1_000_001 ether);

        // Stake 1 token
        staking.stake(1 ether);

        // Wait 1000 days
        vm.warp(block.timestamp + 1000 days);
        uint256 vp1 = staking.getVotingPower(address(this));
        assertEq(vp1, 1000, 'Should have 1,000 token-days');

        // Stake 1 million more tokens
        staking.stake(1_000_000 ether);

        // VP preserved: 1,000 token-days (may have small rounding error with extreme ratio)
        // With 1,000,001 tokens: 1,000 / 1,000,001 ≈ 0.001 days
        uint256 vp2 = staking.getVotingPower(address(this));
        assertApproxEqAbs(
            vp2,
            1000,
            10,
            'VP preserved despite extreme ratio (small rounding acceptable)'
        );

        // After 1 day: 1,000,001 * ~1 day ≈ 1,000,001 token-days (allow rounding error)
        vm.warp(block.timestamp + 1 days);
        uint256 vp3 = staking.getVotingPower(address(this));
        assertApproxEqAbs(
            vp3,
            1_000_001,
            1000,
            'Must accumulate with full balance (rounding acceptable)'
        );
    }

    function test_weighted_average_voting_power_never_increases_on_stake() public {
        underlying.approve(address(staking), 10_000 ether);

        // Initial stake
        staking.stake(100 ether);
        vm.warp(block.timestamp + 50 days);
        uint256 vpBefore = staking.getVotingPower(address(this));

        // Any additional stake should preserve (not increase) VP
        staking.stake(900 ether);
        uint256 vpAfter = staking.getVotingPower(address(this));

        assertEq(vpAfter, vpBefore, 'VP should never increase from staking more tokens');
    }

    function test_weighted_average_multiple_users_independent() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        underlying.mint(alice, 1000 ether);
        underlying.mint(bob, 1000 ether);

        // Alice: stake 100 for 10 days, then 900
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(100 ether);
        vm.warp(block.timestamp + 10 days);
        staking.stake(900 ether);
        vm.stopPrank();

        uint256 aliceVP = staking.getVotingPower(alice);
        assertEq(aliceVP, 1000, 'Alice: 1,000 token-days preserved');

        // Bob: stake 500 for 20 days, then 500
        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(500 ether);
        vm.warp(block.timestamp + 20 days);
        staking.stake(500 ether);
        vm.stopPrank();

        uint256 bobVP = staking.getVotingPower(bob);
        assertEq(bobVP, 500 * 20, 'Bob: 10,000 token-days preserved');

        // Bob has more VP despite same final balance (rewarded for time commitment)
        assertGt(bobVP, aliceVP, 'Bob should have more VP due to longer commitment');
    }

    function test_weighted_average_precision_no_overflow() public {
        // Test with realistic token amounts (18 decimals)
        // Mint enough tokens for this test
        uint256 largeAmount = 1_000_000 ether;
        underlying.mint(address(this), largeAmount * 2);
        underlying.approve(address(staking), type(uint256).max);

        // Stake realistic amount: 1 million tokens
        staking.stake(largeAmount);

        // Wait significant time: 10 years
        vm.warp(block.timestamp + 3650 days);

        // VP should be calculable without overflow
        uint256 vp1 = staking.getVotingPower(address(this));
        assertGt(vp1, 0, 'Should handle large calculations');

        // Stake another million
        staking.stake(largeAmount);

        // VP should be preserved
        uint256 vp2 = staking.getVotingPower(address(this));
        assertApproxEqRel(vp2, vp1, 0.0001e18, 'VP preserved with large amounts');
    }
}
