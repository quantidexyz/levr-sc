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
}
