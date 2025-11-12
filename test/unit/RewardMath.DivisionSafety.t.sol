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
