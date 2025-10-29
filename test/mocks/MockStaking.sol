// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';

/**
 * @title Mock Staking Contract
 * @notice Mock staking contract for testing that can simulate failures
 * @dev Full ILevrStaking_v1 interface implementation with configurable revert behavior
 */
contract MockStaking is ILevrStaking_v1 {
    bool public shouldRevertOnAccrue;

    /// @notice Configure whether accrueRewards should revert
    function setShouldRevertOnAccrue(bool _shouldRevert) external {
        shouldRevertOnAccrue = _shouldRevert;
    }

    /// @notice Mock accrueRewards - can be configured to revert for testing
    function accrueRewards(address) external {
        if (shouldRevertOnAccrue) {
            revert('Mock: Accrual failed');
        }
    }

    // Minimal implementations for interface compliance

    function stake(uint256) external override {}

    function unstake(uint256, address) external override returns (uint256) {
        return 0;
    }

    function claimRewards(address[] calldata, address) external override {}

    function accrueFromTreasury(address, uint256, bool) external override {}

    function outstandingRewards(address) external view override returns (uint256, uint256) {
        return (0, 0);
    }

    function claimableRewards(address, address) external view override returns (uint256) {
        return 0;
    }

    function stakeStartTime(address) external view override returns (uint256) {
        return 0;
    }

    function getVotingPower(address) external view override returns (uint256) {
        return 0;
    }

    function initialize(address, address, address, address) external override {}

    function streamWindowSeconds() external view override returns (uint32) {
        return 0;
    }

    function streamStart() external view override returns (uint64) {
        return 0;
    }

    function streamEnd() external view override returns (uint64) {
        return 0;
    }

    function rewardRatePerSecond(address) external view override returns (uint256) {
        return 0;
    }

    function aprBps() external view override returns (uint256) {
        return 0;
    }

    function stakedBalanceOf(address) external view override returns (uint256) {
        return 0;
    }

    function totalStaked() external view override returns (uint256) {
        return 0;
    }

    function escrowBalance(address) external view override returns (uint256) {
        return 0;
    }
}
