// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Voting Power Math Library
/// @notice Pure math functions for time-weighted voting power calculations
library VotingPowerMath {
    uint256 internal constant SECONDS_PER_DAY = 86400;
    uint8 internal constant TARGET_DECIMALS = 18;

    /// @notice Normalize balance to 18 decimals for fair cross-token voting
    /// @dev Scales up low-decimal tokens (e.g., USDC 6→18). Decimals > 18 prevented by caller validation.
    /// @param balance Raw token balance
    /// @param decimals Token decimals (1-18)
    /// @return normalizedBalance Balance scaled to 18 decimals
    function normalizeBalance(
        uint256 balance,
        uint8 decimals
    ) internal pure returns (uint256 normalizedBalance) {
        if (decimals == TARGET_DECIMALS) return balance;
        if (decimals < TARGET_DECIMALS) {
            uint256 scaleFactor = 10 ** (TARGET_DECIMALS - decimals);
            return balance * scaleFactor;
        }
        return balance;
    }

    /// @notice Calculate weighted average timestamp when staking additional tokens
    /// @dev Preserves voting power: (oldBalance × time) / newTotal
    function calculateStakeTimestamp(
        uint256 oldBalance,
        uint256 stakeAmount,
        uint256 currentStartTime
    ) internal view returns (uint256 newStartTime) {
        if (oldBalance == 0 || currentStartTime == 0) return block.timestamp;

        uint256 timeAccumulated = block.timestamp - currentStartTime;
        uint256 newTotalBalance = oldBalance + stakeAmount;
        uint256 newTimeAccumulated = (oldBalance * timeAccumulated) / newTotalBalance;

        newStartTime = block.timestamp - newTimeAccumulated;
    }

    /// @notice Calculate proportional timestamp reduction when unstaking
    /// @dev (time × remaining) / original
    function calculateUnstakeTimestamp(
        uint256 remainingBalance,
        uint256 unstakeAmount,
        uint256 currentStartTime
    ) internal view returns (uint256 newStartTime) {
        if (currentStartTime == 0 || remainingBalance == 0) return 0;

        uint256 originalBalance = remainingBalance + unstakeAmount;
        uint256 timeAccumulated = block.timestamp - currentStartTime;
        uint256 newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;

        newStartTime = block.timestamp - newTimeAccumulated;
    }

    /// @notice Calculate voting power: (normalizedBalance × time) / (1e18 × 86400)
    /// @dev Returns token-days (e.g., 1000 tokens × 100 days = 100,000 VP)
    function calculateVotingPower(
        uint256 normalizedBalance,
        uint256 startTime
    ) internal view returns (uint256 votingPower) {
        if (startTime == 0 || normalizedBalance == 0) return 0;

        uint256 timeStaked = block.timestamp - startTime;
        return (normalizedBalance * timeStaked) / (1e18 * SECONDS_PER_DAY);
    }
}
