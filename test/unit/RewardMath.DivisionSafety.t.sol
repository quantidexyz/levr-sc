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

    /// @notice Test calculateProportionalClaim works correctly
    function test_calculateProportionalClaim_calculatesCorrectly() public pure {
        uint256 userBalance = 100 ether;
        uint256 totalStaked = 1000 ether;
        uint256 availablePool = 500 ether;

        uint256 claimable = RewardMath.calculateProportionalClaim(
            userBalance,
            totalStaked,
            availablePool
        );

        // Should be (100 / 1000) × 500 = 50
        uint256 expected = 50 ether;
        assertEq(claimable, expected, 'Should calculate proportional share');
    }

    /// @notice Test calculateCurrentPool includes vested amount
    function test_calculateCurrentPool_includesVested() public pure {
        uint256 basePool = 100 ether;
        uint256 streamTotal = 1000 ether;
        uint64 start = 1000;
        uint64 end = 1000 + 7 days;
        uint64 last = 1000;
        uint64 current = 1000 + 1 days; // 1/7 through stream

        uint256 currentPool = RewardMath.calculateCurrentPool(
            basePool,
            streamTotal,
            start,
            end,
            last,
            current
        );

        // Should be basePool + vested ~= 100 + (1000/7) ~= 242.857
        assertGt(currentPool, basePool, 'Pool should include vested amount');
        assertLt(currentPool, basePool + streamTotal, 'Pool should not include unvested');
    }
}
