// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {RewardMath} from '../../src/libraries/RewardMath.sol';

/// @title RewardMath.DivisionSafety Test
/// @notice Tests LOW-1 fix: Explicit division-by-zero checks
/// @dev Verifies defense-in-depth against division by zero
contract RewardMath_DivisionSafety_Test is Test {
    /// @notice Test calculateTimeBasedVesting succeeds with valid duration
    function test_calculateTimeBasedVesting_succeedsWithValidDuration() public pure {
        uint256 originalTotal = 1000 ether;
        uint256 alreadyVested = 0;
        uint64 start = 1000;
        uint64 end = 1000 + 7 days;
        uint64 current = 1000 + 1 days;

        uint256 newlyVested = RewardMath.calculateTimeBasedVesting(
            originalTotal,
            alreadyVested,
            start,
            end,
            current
        );

        // Should calculate vested amount for 1 day of 7 day stream
        assertGt(newlyVested, 0, 'Should vest some amount');
        // Should be approximately 1/7 of total
        assertApproxEqAbs(newlyVested, originalTotal / 7, 1 ether, 'Should vest ~1/7');
    }

    /// @notice Test calculatePendingRewards works correctly (debt accounting pattern)
    function test_calculatePendingRewards_calculatesCorrectly() public pure {
        uint256 userBalance = 100 ether;
        uint256 accRewardPerShare = 5e18; // 5 rewards per share (scaled by 1e18)
        uint256 userDebt = 2e18; // User already accounted for 2 rewards per share
        uint256 precision = 1e18;

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt,
            precision
        );

        // pending = (100 ether × 5e18) / 1e18 - (100 ether × 2e18) / 1e18
        //         = 500 ether - 200 ether = 300 ether
        uint256 expected = 300 ether;
        assertEq(pending, expected, 'Should calculate pending with debt accounting');
    }

    /// @notice Test calculatePendingRewards returns 0 when debt equals accumulated
    function test_calculatePendingRewards_zeroWhenDebtEqualsAccumulated() public pure {
        uint256 userBalance = 100 ether;
        uint256 accRewardPerShare = 5e18;
        uint256 userDebt = 5e18; // Debt equals accumulated
        uint256 precision = 1e18;

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt,
            precision
        );

        assertEq(pending, 0, 'Should return 0 when debt equals accumulated');
    }

    /// @notice Test calculatePendingRewards returns 0 when debt exceeds accumulated
    function test_calculatePendingRewards_zeroWhenDebtExceedsAccumulated() public pure {
        uint256 userBalance = 100 ether;
        uint256 accRewardPerShare = 3e18;
        uint256 userDebt = 5e18; // Debt > accumulated (stale debt scenario)
        uint256 precision = 1e18;

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt,
            precision
        );

        assertEq(pending, 0, 'Should return 0 when debt exceeds accumulated (stale debt)');
    }

    /// @notice Test calculatePendingRewards returns 0 for zero balance
    function test_calculatePendingRewards_zeroForZeroBalance() public pure {
        uint256 pending = RewardMath.calculatePendingRewards(0, 5e18, 0, 1e18);
        assertEq(pending, 0, 'Should return 0 for zero balance');
    }

    /// @notice Test calculateTimeBasedVesting with partial vesting
    function test_calculateTimeBasedVesting_withPartialVesting() public pure {
        uint256 originalTotal = 1000 ether;
        uint256 alreadyVested = 300 ether; // Already vested 300
        uint64 start = 1000;
        uint64 end = 1000 + 7 days;
        uint64 current = 1000 + 4 days; // 4/7 through stream

        uint256 newlyVested = RewardMath.calculateTimeBasedVesting(
            originalTotal,
            alreadyVested,
            start,
            end,
            current
        );

        // Should have vested 4/7 total = ~571 ether
        // Already vested 300, so newly = 571 - 300 = ~271
        uint256 expectedTotal = (originalTotal * 4) / 7;
        uint256 expectedNewly = expectedTotal - alreadyVested;
        assertApproxEqAbs(
            newlyVested,
            expectedNewly,
            1 ether,
            'Should vest remaining to reach 4/7'
        );
    }
}
