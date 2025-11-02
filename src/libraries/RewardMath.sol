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

    /// @notice Calculate user's proportional share of pool
    /// @param userBalance User's staked token balance
    /// @param totalStaked Total staked token supply
    /// @param availablePool Total claimable pool for this token
    /// @return claimable User's claimable amount
    function calculateProportionalClaim(
        uint256 userBalance,
        uint256 totalStaked,
        uint256 availablePool
    ) internal pure returns (uint256 claimable) {
        if (userBalance == 0 || totalStaked == 0 || availablePool == 0) return 0;

        // User's share = (userBalance / totalStaked) × availablePool
        // This is mathematically perfect: sum of all claims = pool
        return (availablePool * userBalance) / totalStaked;
    }

    /// @notice Calculate current available pool including vested rewards
    /// @param basePool Current pool amount
    /// @param streamTotal Total amount streaming
    /// @param start Stream start timestamp
    /// @param end Stream end timestamp
    /// @param last Last update timestamp
    /// @param current Current timestamp
    /// @return totalPool Base pool + newly vested amount
    function calculateCurrentPool(
        uint256 basePool,
        uint256 streamTotal,
        uint64 start,
        uint64 end,
        uint64 last,
        uint64 current
    ) internal pure returns (uint256 totalPool) {
        (uint256 vested, ) = calculateVestedAmount(streamTotal, start, end, last, current);
        return basePool + vested;
    }
}
