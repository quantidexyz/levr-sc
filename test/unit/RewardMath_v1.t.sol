// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {RewardMath} from '../../src/libraries/RewardMath.sol';

contract RewardMath_v1_Test is Test {
    ///////////////////////////////////////////////////////////////////////////
    // Test Pure Functions

    // ========================================================================
    // Time-Based Vesting

    /* Test: calculateTimeBasedVesting */
    function test_CalculateTimeBasedVesting_ReturnsPortionOfStream() public pure {
        uint256 originalTotal = 1_000 ether;
        uint256 alreadyVested = 0;
        uint64 start = 1_000;
        uint64 end = start + 7 days;
        uint64 current = start + 1 days;

        uint256 newlyVested = RewardMath.calculateTimeBasedVesting(
            originalTotal,
            alreadyVested,
            start,
            end,
            current
        );

        assertApproxEqAbs(newlyVested, originalTotal / 7, 1 ether);
    }

    function test_CalculateTimeBasedVesting_WithExistingVestedAmount() public pure {
        uint256 originalTotal = 1_000 ether;
        uint256 alreadyVested = 300 ether;
        uint64 start = 1_000;
        uint64 end = start + 7 days;
        uint64 current = start + 4 days;

        uint256 newlyVested = RewardMath.calculateTimeBasedVesting(
            originalTotal,
            alreadyVested,
            start,
            end,
            current
        );

        uint256 expectedTotal = (originalTotal * 4) / 7;
        uint256 expectedNew = expectedTotal - alreadyVested;
        assertApproxEqAbs(newlyVested, expectedNew, 1 ether);
    }

    // ========================================================================
    // Pending Rewards (Debt Accounting)

    /* Test: calculatePendingRewards */
    function test_CalculatePendingRewards_ComputesDebtDifference() public pure {
        uint256 pending = RewardMath.calculatePendingRewards(100 ether, 5e18, 2e18, 1e18);
        assertEq(pending, 300 ether);
    }

    function test_CalculatePendingRewards_ZeroWhenDebtEqualsAccumulated() public pure {
        uint256 pending = RewardMath.calculatePendingRewards(100 ether, 5e18, 5e18, 1e18);
        assertEq(pending, 0);
    }

    function test_CalculatePendingRewards_ZeroWhenDebtExceedsAccumulated() public pure {
        uint256 pending = RewardMath.calculatePendingRewards(100 ether, 3e18, 5e18, 1e18);
        assertEq(pending, 0);
    }

    function test_CalculatePendingRewards_ZeroBalance() public pure {
        uint256 pending = RewardMath.calculatePendingRewards(0, 5e18, 0, 1e18);
        assertEq(pending, 0);
    }

    function test_CalculatePendingRewards_FuzzMonotonic(
        uint128 userBalance,
        uint128 accRewardPerShare,
        uint128 userDebt,
        uint64 precision
    ) public pure {
        vm.assume(precision > 0);
        vm.assume(accRewardPerShare >= userDebt);

        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare,
            userDebt,
            precision
        );

        uint256 accumulated = (uint256(userBalance) * accRewardPerShare) / precision;
        uint256 debtAmount = (uint256(userBalance) * userDebt) / precision;
        uint256 expected = accumulated > debtAmount ? accumulated - debtAmount : 0;
        assertEq(pending, expected);
    }
}

