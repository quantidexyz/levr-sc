// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RewardMath Library
/// @notice Pure calculation functions for pool-based reward distribution
/// @dev All reward math in one place - keeps staking contract clean
library RewardMath {
    /// @notice Calculate vested amount from streaming rewards
    /// @param total Total amount to vest over the duration
    /// @param start Stream start timestamp
    /// @param end Stream end timestamp
    /// @param last Last update timestamp
    /// @param current Current timestamp
    /// @return vested Amount that has vested since last update
    /// @return newLast New last update timestamp (clamped to end)
    function calculateVestedAmount(
        uint256 total,
        uint64 start,
        uint64 end,
        uint64 last,
        uint64 current
    ) internal pure returns (uint256 vested, uint64 newLast) {
        // No active stream
        if (end == 0 || start == 0) return (0, last);

        // Determine the time range to calculate vesting for
        uint64 from = last < start ? start : last;
        uint64 to = current;
        if (to > end) to = end;
        if (to <= from) return (0, last);

        uint256 duration = end - start;
        require(duration != 0, 'ZERO_DURATION');
        if (total == 0) return (0, to);

        // Calculate vested amount linearly
        vested = (total * (to - from)) / duration;
        newLast = to;
    }

    /// @notice Calculate pending rewards using debt accounting (MasterChef pattern)
    /// @dev Prevents dilution attacks by tracking what user has already accounted for
    /// @param userBalance User's staked token balance
    /// @param accRewardPerShare Accumulated rewards per share (scaled by 1e18)
    /// @param userDebt User's reward debt (what they've already accounted for)
    /// @return pending User's pending claimable amount
    function calculatePendingRewards(
        uint256 userBalance,
        uint256 accRewardPerShare,
        uint256 userDebt
    ) internal pure returns (uint256 pending) {
        if (userBalance == 0) return 0;

        // Calculate accumulated rewards based on current accRewardPerShare
        uint256 accumulatedRewards = (userBalance * accRewardPerShare) / 1e18;

        // Subtract what user has already accounted for (debt)
        uint256 debtAmount = (userBalance * userDebt) / 1e18;

        // Pending = accumulated - debt (prevents dilution on stake/claim operations)
        return accumulatedRewards > debtAmount ? accumulatedRewards - debtAmount : 0;
    }
}
