// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrFeeSplitter_v1} from './interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {IClankerToken} from './interfaces/external/IClankerToken.sol';
import {IClankerLpLocker} from './interfaces/external/IClankerLPLocker.sol';

/**
 * @title LevrFeeSplitter_v1
 * @notice Singleton that enables flexible fee distribution for all Clanker tokens
 * @dev Acts as fee receiver from ClankerLpLocker and distributes fees according to per-project configuration
 *      Each project (identified by clankerToken) can configure its own split percentages
 *      Only the token admin can configure splits for their project
 */
contract LevrFeeSplitter_v1 is ILevrFeeSplitter_v1, ERC2771ContextBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 private constant BPS_DENOMINATOR = 10_000; // 100% = 10,000 bps

    // ============ State Variables ============

    /// @notice The Levr factory address (for getClankerMetadata and getProjectContracts)
    address public immutable factory;

    /// @notice Per-project configuration (clankerToken => splits)
    mapping(address => SplitConfig[]) private _projectSplits;

    /// @notice Per-project distribution state (clankerToken => rewardToken => state)
    mapping(address => mapping(address => DistributionState)) private _distributionState;

    // ============ Constructor ============

    /**
     * @notice Deploy the singleton fee splitter
     * @param factory_ The Levr factory address
     * @param trustedForwarder_ The ERC2771 forwarder for meta-transactions
     */
    constructor(address factory_, address trustedForwarder_) ERC2771ContextBase(trustedForwarder_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    // ============ Admin Functions ============

    /// @inheritdoc ILevrFeeSplitter_v1
    function configureSplits(
        address clankerToken,
        SplitConfig[] calldata splits
    ) external override {
        // Only token admin can configure splits for their project
        _onlyTokenAdmin(clankerToken);

        // Validate splits
        _validateSplits(clankerToken, splits);

        // Clear existing splits
        delete _projectSplits[clankerToken];

        // Store new splits
        for (uint256 i = 0; i < splits.length; i++) {
            _projectSplits[clankerToken].push(splits[i]);
        }

        emit SplitsConfigured(clankerToken, splits);
    }

    // ============ Distribution Functions ============

    /// @inheritdoc ILevrFeeSplitter_v1
    function distribute(address clankerToken, address rewardToken) external override nonReentrant {
        // Get LP locker from factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(clankerToken);
        if (!metadata.exists) revert ClankerMetadataNotFound();
        if (metadata.lpLocker == address(0)) revert LpLockerNotConfigured();

        // Collect rewards from LP locker
        // This sends fees directly to address(this) because we're the reward recipient
        // NOTE: We do NOT claim from ClankerFeeLocker - the LP locker handles that
        try IClankerLpLocker(metadata.lpLocker).collectRewards(clankerToken) {
            // Successfully collected - fees now in this contract
        } catch {
            // Ignore errors - might not have fees to collect
        }

        // Check balance available for distribution
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance == 0) return; // No fees to distribute

        // Distribute according to configured splits
        if (!_isSplitsConfigured(clankerToken)) revert SplitsNotConfigured();

        SplitConfig[] storage splits = _projectSplits[clankerToken];
        address staking = getStakingAddress(clankerToken);

        for (uint256 i = 0; i < splits.length; i++) {
            SplitConfig memory split = splits[i];
            uint256 amount = (balance * split.bps) / BPS_DENOMINATOR;

            if (amount > 0) {
                IERC20(rewardToken).safeTransfer(split.receiver, amount);

                // If this is the staking contract, emit event for manual accrual
                if (split.receiver == staking) {
                    emit StakingDistribution(clankerToken, rewardToken, amount);
                }

                emit FeeDistributed(clankerToken, rewardToken, split.receiver, amount);
            }
        }

        // Update distribution state
        _distributionState[clankerToken][rewardToken].totalDistributed += balance;
        _distributionState[clankerToken][rewardToken].lastDistribution = block.timestamp;

        emit Distributed(clankerToken, rewardToken, balance);
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function distributeBatch(
        address clankerToken,
        address[] calldata rewardTokens
    ) external override nonReentrant {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            // Use internal logic without reentrancy guard (already protected)
            _distributeSingle(clankerToken, rewardTokens[i]);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc ILevrFeeSplitter_v1
    function getSplits(
        address clankerToken
    ) external view override returns (SplitConfig[] memory splits) {
        return _projectSplits[clankerToken];
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function getTotalBps(address clankerToken) external view override returns (uint256 totalBps) {
        SplitConfig[] storage splits = _projectSplits[clankerToken];
        for (uint256 i = 0; i < splits.length; i++) {
            totalBps += splits[i].bps;
        }
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function pendingFees(
        address /* clankerToken */,
        address rewardToken
    ) external view override returns (uint256 pending) {
        // For this singleton design, pending fees are just the balance in this contract
        // that belongs to this project's reward token
        // Note: This is a simplified view - in practice all projects share the contract balance
        // but each project's fees are isolated by the distribution flow
        return IERC20(rewardToken).balanceOf(address(this));
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function getDistributionState(
        address clankerToken,
        address rewardToken
    ) external view override returns (DistributionState memory state) {
        return _distributionState[clankerToken][rewardToken];
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function isSplitsConfigured(
        address clankerToken
    ) external view override returns (bool configured) {
        return _isSplitsConfigured(clankerToken);
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function getStakingAddress(
        address clankerToken
    ) public view override returns (address staking) {
        ILevrFactory_v1.Project memory project = ILevrFactory_v1(factory).getProjectContracts(
            clankerToken
        );
        return project.staking;
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if splits are configured and valid (sum to 100%)
     * @param clankerToken The Clanker token address
     * @return configured True if splits are properly configured
     */
    function _isSplitsConfigured(address clankerToken) internal view returns (bool configured) {
        SplitConfig[] storage splits = _projectSplits[clankerToken];
        if (splits.length == 0) return false;

        uint256 totalBps = 0;
        for (uint256 i = 0; i < splits.length; i++) {
            totalBps += splits[i].bps;
        }

        return totalBps == BPS_DENOMINATOR;
    }

    /**
     * @notice Validate split configuration
     * @param clankerToken The Clanker token address
     * @param splits The splits to validate
     */
    function _validateSplits(address clankerToken, SplitConfig[] calldata splits) internal view {
        if (splits.length == 0) revert NoReceivers();

        // Get staking address for this project from factory
        address staking = getStakingAddress(clankerToken);
        if (staking == address(0)) revert ProjectNotRegistered();

        uint256 totalBps = 0;
        bool hasStaking = false;

        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].receiver == address(0)) revert ZeroAddress();
            if (splits[i].bps == 0) revert ZeroBps();

            totalBps += splits[i].bps;

            // Check if staking contract appears more than once
            if (splits[i].receiver == staking) {
                if (hasStaking) revert DuplicateStakingReceiver();
                hasStaking = true;
            }
        }

        if (totalBps != BPS_DENOMINATOR) revert InvalidTotalBps();
    }

    /**
     * @notice Ensure caller is the token admin
     * @param clankerToken The Clanker token address
     */
    function _onlyTokenAdmin(address clankerToken) internal view {
        address tokenAdmin = IClankerToken(clankerToken).admin();
        if (_msgSender() != tokenAdmin) revert OnlyTokenAdmin();
    }

    /**
     * @notice Internal distribution logic (without reentrancy guard)
     * @param clankerToken The Clanker token address
     * @param rewardToken The reward token to distribute
     */
    function _distributeSingle(address clankerToken, address rewardToken) internal {
        // Get LP locker from factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(clankerToken);
        if (!metadata.exists) revert ClankerMetadataNotFound();
        if (metadata.lpLocker == address(0)) revert LpLockerNotConfigured();

        // Collect rewards from LP locker
        try IClankerLpLocker(metadata.lpLocker).collectRewards(clankerToken) {
            // Successfully collected
        } catch {
            // Ignore errors
        }

        // Check balance available for distribution
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance == 0) return;

        // Distribute according to configured splits
        if (!_isSplitsConfigured(clankerToken)) revert SplitsNotConfigured();

        SplitConfig[] storage splits = _projectSplits[clankerToken];
        address staking = getStakingAddress(clankerToken);

        for (uint256 i = 0; i < splits.length; i++) {
            SplitConfig memory split = splits[i];
            uint256 amount = (balance * split.bps) / BPS_DENOMINATOR;

            if (amount > 0) {
                IERC20(rewardToken).safeTransfer(split.receiver, amount);

                if (split.receiver == staking) {
                    emit StakingDistribution(clankerToken, rewardToken, amount);
                }

                emit FeeDistributed(clankerToken, rewardToken, split.receiver, amount);
            }
        }

        // Update distribution state
        _distributionState[clankerToken][rewardToken].totalDistributed += balance;
        _distributionState[clankerToken][rewardToken].lastDistribution = block.timestamp;

        emit Distributed(clankerToken, rewardToken, balance);
    }
}
