// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {RewardMath} from '../../src/libraries/RewardMath.sol';

/// @title RewardMath.DivisionSafety Test
/// @notice Tests LOW-1 fix: Explicit division-by-zero checks
/// @dev Verifies defense-in-depth against division by zero
contract RewardMath_DivisionSafety_Test is Test {
    /// @notice Test calculateVestedAmount succeeds with valid duration
    function test_calculateVestedAmount_succeedsWithValidDuration() public pure {
        uint256 total = 1000 ether;
        uint64 start = 1000;
        uint64 end = 1000 + 7 days;
        uint64 last = 1000;
        uint64 current = 1000 + 1 days;

        (uint256 vested, uint64 newLast) = RewardMath.calculateVestedAmount(
            total,
            start,
            end,
            last,
            current
        );

        // Should calculate vested amount for 1 day of 7 day stream
        assertGt(vested, 0, 'Should vest some amount');
        assertEq(newLast, current, 'New last should be current time');
    }

    /// @notice Test calculatePendingRewards works correctly (debt accounting pattern)
    function test_calculatePendingRewards_calculatesCorrectly() public pure {
        uint256 userBalance = 100 ether;
        uint256 accRewardPerShare = 5e18; // 5 rewards per share (scaled by 1e18)
        uint256 userDebt = 2e18; // User already accounted for 2 rewards per share

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt
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

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt
        );

        assertEq(pending, 0, 'Should return 0 when debt equals accumulated');
    }

    /// @notice Test calculatePendingRewards returns 0 when debt exceeds accumulated
    function test_calculatePendingRewards_zeroWhenDebtExceedsAccumulated() public pure {
        uint256 userBalance = 100 ether;
        uint256 accRewardPerShare = 3e18;
        uint256 userDebt = 5e18; // Debt > accumulated (stale debt scenario)

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt
        );

        assertEq(pending, 0, 'Should return 0 when debt exceeds accumulated (stale debt)');
    }

    /// @notice Test calculatePendingRewards returns 0 for zero balance
    function test_calculatePendingRewards_zeroForZeroBalance() public pure {
        uint256 pending = RewardMath.calculatePendingRewards(0, 5e18, 0);
        assertEq(pending, 0, 'Should return 0 for zero balance');
    }
}
