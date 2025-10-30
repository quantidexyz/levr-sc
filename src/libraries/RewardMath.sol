// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RewardMath Library
/// @notice Pure calculation functions for reward streaming and accounting
/// @dev Single source of truth for reward calculations, reduces duplication
library RewardMath {
    // CRITICAL-4: Increased to 1e27 for higher precision (1000x improvement over 1e18)
    // Reduces rounding errors in reward calculations, especially for small stakes
    uint256 internal constant ACC_SCALE = 1e27;

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
        // LOW-1: Add explicit division-by-zero check for defense-in-depth
        require(duration != 0, 'ZERO_DURATION');
        if (total == 0) return (0, to);

        // Calculate vested amount linearly
        vested = (total * (to - from)) / duration;
        newLast = to;
    }

    /// @notice Calculate unvested rewards from current stream
    /// @param total Total amount to vest over the duration
    /// @param start Stream start timestamp
    /// @param end Stream end timestamp
    /// @param last Last update timestamp (marks when stream paused if last < current when totalStaked=0)
    /// @param current Current timestamp
    /// @return unvested Amount that hasn't vested yet
    function calculateUnvested(
        uint256 total,
        uint64 start,
        uint64 end,
        uint64 last,
        uint64 current
    ) internal pure returns (uint256 unvested) {
        // No active stream
        if (end == 0 || start == 0) return 0;

        // Stream hasn't started yet
        if (current < start) return total;

        uint256 duration = end - start;
        // LOW-1: Add explicit division-by-zero check
        require(duration != 0, 'ZERO_DURATION');
        if (duration == 0) return 0;

        // If stream ended, check if it fully vested
        if (current >= end) {
            // If last update didn't reach end, stream paused (no stakers) - return unvested
            if (last < end) {
                // FIX: If stream never started vesting (last == start or last < start),
                // don't include unvested in next stream - keeps rewards in reserve for manual re-accrual
                // This prevents unvested rewards from getting stuck in infinite loop of paused streams
                if (last <= start) {
                    return 0; // Stream completely paused - rewards stay in reserve
                }
                // Stream partially vested then paused - calculate unvested portion
                uint256 unvestedDuration = end - last;
                return (total * unvestedDuration) / duration;
            }
            // Stream fully vested
            return 0;
        }

        // CRITICAL-1 FIX: Stream still active - use last update if stream paused
        // If last < current when totalStaked = 0, stream is paused at 'last'
        // Only vest up to pause point, not current time
        uint64 effectiveTime = last < current ? last : current;
        uint256 elapsed = effectiveTime > start ? effectiveTime - start : 0;
        uint256 vested = (total * elapsed) / duration;

        // Return unvested portion
        return total > vested ? total - vested : 0;
    }

    /// @notice Calculate new accPerShare after vesting
    /// @param currentAcc Current accumulated rewards per share
    /// @param vestAmount Amount of rewards that have vested
    /// @param totalStaked Total amount currently staked
    /// @return newAcc New accumulated rewards per share
    function calculateAccPerShare(
        uint256 currentAcc,
        uint256 vestAmount,
        uint256 totalStaked
    ) internal pure returns (uint256 newAcc) {
        if (vestAmount == 0 || totalStaked == 0) return currentAcc;
        // LOW-1: Add explicit division-by-zero check
        require(totalStaked != 0, 'DIVISION_BY_ZERO');
        return currentAcc + (vestAmount * ACC_SCALE) / totalStaked;
    }

    /// @notice Calculate user's accumulated rewards
    /// @param balance User's staked balance
    /// @param accPerShare Accumulated rewards per share
    /// @return accumulated Total rewards accumulated for user
    function calculateAccumulated(
        uint256 balance,
        uint256 accPerShare
    ) internal pure returns (uint256 accumulated) {
        return (balance * accPerShare) / ACC_SCALE;
    }

    /// @notice Calculate claimable rewards (balance-based + pending)
    /// @param accumulated Total accumulated rewards for user
    /// @param debt User's reward debt
    /// @param pending Pending rewards from unstaking
    /// @return claimable Total claimable rewards
    function calculateClaimable(
        uint256 accumulated,
        int256 debt,
        uint256 pending
    ) internal pure returns (uint256 claimable) {
        claimable = pending;
        if (accumulated > uint256(debt)) {
            claimable += accumulated - uint256(debt);
        }
    }
}
