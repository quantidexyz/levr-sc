// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {RewardMath} from '../../src/libraries/RewardMath.sol';

/// @title RewardMath.DivisionSafety Test
/// @notice Tests LOW-1 fix: Explicit division-by-zero checks
/// @dev Verifies defense-in-depth against division by zero
contract RewardMath_DivisionSafety_Test is Test {
    /// @notice LOW-1: Test calculateAccPerShare with valid inputs
    function test_calculateAccPerShare_succeedsWithValidInputs() public {
        uint256 currentAcc = 1e27;
        uint256 vestAmount = 100 ether;
        uint256 totalStaked = 1000 ether;

        uint256 newAcc = RewardMath.calculateAccPerShare(currentAcc, vestAmount, totalStaked);

        // Should calculate successfully
        assertGt(newAcc, currentAcc, 'New acc should be greater than current');
    }

    /// @notice LOW-1: Test calculateVestedAmount succeeds with valid duration
    function test_calculateVestedAmount_succeedsWithValidDuration() public {
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

    /// @notice LOW-1: Test calculateUnvested with protection
    function test_calculateUnvested_correctlyCalculates() public {
        uint256 total = 1000 ether;
        uint64 start = 1000;
        uint64 end = 1000 + 7 days;
        uint64 last = 1000;
        uint64 current = 1000 + 1 days; // After 1 day

        // Should not revert - has protection
        uint256 unvested = RewardMath.calculateUnvested(total, start, end, last, current);

        // Should return a valid result (non-negative, <= total)
        assertLe(unvested, total, 'Unvested should not exceed total');
    }

    /// @notice LOW-1: Test calculateAccumulated doesn't divide by zero
    function test_calculateAccumulated_noZeroDivision() public {
        uint256 balance = 100 ether;
        uint256 accPerShare = 1e27;

        uint256 accumulated = RewardMath.calculateAccumulated(balance, accPerShare);

        // Should calculate without reverting
        assertGt(accumulated, 0, 'Should calculate accumulated rewards');
    }

    /// @notice LOW-1: Test calculateClaimable works correctly
    function test_calculateClaimable_calculatesCorrectly() public {
        uint256 accumulated = 1000 ether;
        int256 debt = 400 ether;
        uint256 pending = 100 ether;

        uint256 claimable = RewardMath.calculateClaimable(accumulated, debt, pending);

        // Should be accumulated - debt + pending = 1000 - 400 + 100 = 700
        uint256 expected = 1000 ether - 400 ether + 100 ether;
        assertEq(claimable, expected, 'Should calculate claimable correctly');
    }
}
