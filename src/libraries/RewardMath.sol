// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RewardMath Library
/// @notice Pool-based reward distribution calculations
library RewardMath {
    /// @notice Calculate linearly vested amount from reward stream
    /// @dev vested = total × (to - from) / duration
    function calculateVestedAmount(
        uint256 total,
        uint64 start,
        uint64 end,
        uint64 last,
        uint64 current
    ) internal pure returns (uint256 vested, uint64 newLast) {
        if (end == 0 || start == 0) return (0, last);

        uint64 from = last < start ? start : last;
        uint64 to = current > end ? end : current;
        if (to <= from) return (0, last);

        uint256 duration = end - start;
        require(duration != 0, 'ZERO_DURATION');
        if (total == 0) return (0, to);

        vested = (total * (to - from)) / duration;
        newLast = to;
    }

    /// @notice Calculate pending rewards using MasterChef debt accounting
    /// @dev Prevents dilution: pending = (balance × accPerShare / 1e18) - (balance × debt / 1e18)
    function calculatePendingRewards(
        uint256 userBalance,
        uint256 accRewardPerShare,
        uint256 userDebt
    ) internal pure returns (uint256 pending) {
        if (userBalance == 0) return 0;

        uint256 accumulatedRewards = (userBalance * accRewardPerShare) / 1e18;
        uint256 debtAmount = (userBalance * userDebt) / 1e18;

        return accumulatedRewards > debtAmount ? accumulatedRewards - debtAmount : 0;
    }
}
