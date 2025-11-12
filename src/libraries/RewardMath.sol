// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RewardMath Library
/// @notice Pure calculation functions for time-based reward distribution
/// @dev All reward math in one place - keeps staking contract clean
library RewardMath {
    /// @notice Calculate newly vested amount using time-based linear vesting
    /// @dev Calculates vesting based on time elapsed from stream start, not remaining amount
    /// @param originalTotal Original stream amount at stream start
    /// @param alreadyVested Amount already vested from this stream
    /// @param start Stream start timestamp
    /// @param end Stream end timestamp
    /// @param current Current timestamp
    /// @return newlyVested Amount that has vested since last settlement
    function calculateTimeBasedVesting(
        uint256 originalTotal,
        uint256 alreadyVested,
        uint64 start,
        uint64 end,
        uint64 current
    ) internal pure returns (uint256 newlyVested) {
        if (end == 0 || start == 0 || originalTotal == 0) return 0;

        uint64 settleTo = current > end ? end : current;
        if (settleTo <= start) return 0;

        uint256 duration = end - start;
        require(duration != 0, 'ZERO_DURATION');

        uint256 timeElapsed = settleTo - start;

        // Linear vesting: total vested = (original × timeElapsed) / duration
        uint256 totalVestedNow = (originalTotal * timeElapsed) / duration;

        // Return only newly vested amount since last settlement
        if (totalVestedNow > alreadyVested) {
            newlyVested = totalVestedNow - alreadyVested;
        }
    }

    /// @notice Calculate pending rewards using debt accounting (MasterChef pattern)
    /// @dev Prevents dilution attack by tracking what user has already accounted for
    /// @param userBalance User's staked balance
    /// @param accRewardPerShare Accumulated rewards per share (scaled by precision)
    /// @param debtPerShare User's reward debt per share (what they've accounted for)
    /// @param precision Scaling precision (e.g., 1e18)
    /// @return pending Amount of pending claimable rewards
    function calculatePendingRewards(
        uint256 userBalance,
        uint256 accRewardPerShare,
        uint256 debtPerShare,
        uint256 precision
    ) internal pure returns (uint256 pending) {
        if (userBalance == 0) return 0;

        uint256 accumulatedRewards = (userBalance * accRewardPerShare) / precision;
        uint256 debtAmount = (userBalance * debtPerShare) / precision;

        pending = accumulatedRewards > debtAmount ? accumulatedRewards - debtAmount : 0;
    }

    /// @notice Calculate voting power based on time-weighted staking
    /// @dev VP = balance × time / (precision × secondsPerDay) → token-days
    /// @param balance User's staked balance
    /// @param timeStaked Time in seconds since stake start
    /// @param precision Scaling precision (e.g., 1e18)
    /// @param secondsPerDay Seconds per day (86400)
    /// @return votingPower Calculated voting power in token-days
    function calculateVotingPower(
        uint256 balance,
        uint256 timeStaked,
        uint256 precision,
        uint256 secondsPerDay
    ) internal pure returns (uint256 votingPower) {
        if (balance == 0 || timeStaked == 0) return 0;

        votingPower = (balance * timeStaked) / (precision * secondsPerDay);
    }

    /// @notice Calculate weighted time accumulation when adding to stake
    /// @dev Preserves existing voting power using weighted average
    /// @param oldBalance Balance before new stake
    /// @param stakeAmount Amount being added
    /// @param timeAccumulated Time accumulated on old balance
    /// @return newTimeAccumulated Weighted time for combined balance
    function calculateStakeWeightedTime(
        uint256 oldBalance,
        uint256 stakeAmount,
        uint256 timeAccumulated
    ) internal pure returns (uint256 newTimeAccumulated) {
        if (oldBalance == 0) return 0;

        uint256 newTotalBalance = oldBalance + stakeAmount;
        if (newTotalBalance == 0) return 0;

        // Weighted average: (oldBalance × timeAccumulated) / newTotalBalance
        newTimeAccumulated = (oldBalance * timeAccumulated) / newTotalBalance;
    }

    /// @notice Calculate proportional time reduction when removing from stake
    /// @dev Reduces time accumulation proportionally to amount removed
    /// @param remainingBalance Balance after unstake
    /// @param unstakeAmount Amount being removed
    /// @param timeAccumulated Time accumulated before unstake
    /// @return newTimeAccumulated Proportionally reduced time
    function calculateUnstakeWeightedTime(
        uint256 remainingBalance,
        uint256 unstakeAmount,
        uint256 timeAccumulated
    ) internal pure returns (uint256 newTimeAccumulated) {
        if (remainingBalance == 0) return 0;

        uint256 originalBalance = remainingBalance + unstakeAmount;
        if (originalBalance == 0) return 0;

        // Proportional reduction: (timeAccumulated × remainingBalance) / originalBalance
        newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;
    }
}
