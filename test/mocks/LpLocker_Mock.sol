// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title LP Locker Mock
 * @notice Minimal mock for LP locker contract calls
 * @dev Simple stub that implements collectRewards without reverting
 */
contract LpLocker_Mock {
    /// @notice Mock collectRewards - does nothing, just needs to not revert
    function collectRewards(address) external {
        // Do nothing - just needs to not revert
    }
}
