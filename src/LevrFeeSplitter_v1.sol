// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrFeeSplitter_v1} from './interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {IClankerToken} from './interfaces/external/IClankerToken.sol';
import {IClankerLpLocker} from './interfaces/external/IClankerLPLocker.sol';
import {IClankerFeeLocker} from './interfaces/external/IClankerFeeLocker.sol';

/**
 * @title LevrFeeSplitter_v1
 * @notice Per-project fee splitter for flexible fee distribution
 * @dev Each Clanker token gets its own dedicated fee splitter instance
 *      This prevents token mixing issues with shared reward tokens (WETH, USDC, etc.)
 *      Deploy via LevrFeeSplitterDeployer_v1
 */
contract LevrFeeSplitter_v1 is ILevrFeeSplitter_v1, ERC2771ContextBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 private constant BPS_DENOMINATOR = 10_000; // 100% = 10,000 bps

    // ============ Immutables ============

    /// @notice The Clanker token this splitter handles
    address public immutable clankerToken;

    /// @notice The Levr factory address (for metadata and project lookups)
    address public immutable factory;

    // ============ State Variables ============

    /// @notice Split configuration for this project
    SplitConfig[] private _splits;

    /// @notice Per-reward-token distribution state
    mapping(address => DistributionState) private _distributionState;

    // ============ Constructor ============

    /**
     * @notice Deploy a fee splitter for a specific Clanker token
     * @param clankerToken_ The Clanker token address this splitter handles
     * @param factory_ The Levr factory address
     * @param trustedForwarder_ The ERC2771 forwarder for meta-transactions
     */
    constructor(
        address clankerToken_,
        address factory_,
        address trustedForwarder_
    ) ERC2771ContextBase(trustedForwarder_) {
        if (clankerToken_ == address(0)) revert ZeroAddress();
        if (factory_ == address(0)) revert ZeroAddress();
        clankerToken = clankerToken_;
        factory = factory_;
    }

    // ============ Admin Functions ============

    /// @inheritdoc ILevrFeeSplitter_v1
    function configureSplits(SplitConfig[] calldata splits) external {
        // Only token admin can configure splits
        _onlyTokenAdmin();

        // Validate splits
        _validateSplits(splits);

        // Clear existing splits
        delete _splits;

        // Store new splits
        for (uint256 i = 0; i < splits.length; i++) {
            _splits.push(splits[i]);
        }

        emit SplitsConfigured(clankerToken, splits);
    }

    // ============ Distribution Functions ============

    /// @inheritdoc ILevrFeeSplitter_v1
    function distribute(address rewardToken) external nonReentrant {
        // Get LP locker from factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(clankerToken);
        if (!metadata.exists) revert ClankerMetadataNotFound();
        if (metadata.lpLocker == address(0)) revert LpLockerNotConfigured();

        // Step 1: Collect rewards from LP locker (moves fees from V4 pool to ClankerFeeLocker)
        try IClankerLpLocker(metadata.lpLocker).collectRewards(clankerToken) {
            // Successfully collected from pool to locker
        } catch {
            // Ignore errors - might not have fees to collect
        }

        // Step 2: Claim fees from ClankerFeeLocker to this contract (fee splitter)
        if (metadata.feeLocker != address(0)) {
            try IClankerFeeLocker(metadata.feeLocker).claim(address(this), rewardToken) {
                // Successfully claimed from fee locker to splitter
            } catch {
                // Fee locker might not have this token or fees
            }
        }

        // Check balance available for distribution
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance == 0) return; // No fees to distribute

        // Distribute according to configured splits
        if (!_isSplitsConfigured()) revert SplitsNotConfigured();

        address staking = getStakingAddress();
        bool sentToStaking = false;

        for (uint256 i = 0; i < _splits.length; i++) {
            SplitConfig memory split = _splits[i];
            uint256 amount = (balance * split.bps) / BPS_DENOMINATOR;

            if (amount > 0) {
                IERC20(rewardToken).safeTransfer(split.receiver, amount);

                // Track if we sent to staking for automatic accrual
                if (split.receiver == staking) {
                    sentToStaking = true;
                    emit StakingDistribution(clankerToken, rewardToken, amount);
                }

                emit FeeDistributed(clankerToken, rewardToken, split.receiver, amount);
            }
        }

        // Update distribution state
        _distributionState[rewardToken].totalDistributed += balance;
        _distributionState[rewardToken].lastDistribution = block.timestamp;

        emit Distributed(clankerToken, rewardToken, balance);

        // If we sent fees to staking, automatically call accrueRewards
        // This makes the fees immediately available without needing a separate transaction
        if (sentToStaking) {
            ILevrStaking_v1(staking).accrueRewards(rewardToken);
            emit AutoAccrualSuccess(clankerToken, rewardToken);
        }
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function distributeBatch(address[] calldata rewardTokens) external nonReentrant {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            // Use internal logic without reentrancy guard (already protected)
            _distributeSingle(rewardTokens[i]);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc ILevrFeeSplitter_v1
    function getSplits() external view returns (SplitConfig[] memory splits) {
        return _splits;
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function getTotalBps() external view returns (uint256 totalBps) {
        for (uint256 i = 0; i < _splits.length; i++) {
            totalBps += _splits[i].bps;
        }
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function pendingFees(address rewardToken) external view returns (uint256 pending) {
        // Query pending fees from ClankerFeeLocker
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(clankerToken);

        if (!metadata.exists || metadata.feeLocker == address(0)) return 0;

        try
            IClankerFeeLocker(metadata.feeLocker).availableFees(address(this), rewardToken)
        returns (uint256 fees) {
            return fees;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function pendingFeesInclBalance(address rewardToken) external view returns (uint256 pending) {
        // Get pending in fee locker
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(clankerToken);

        uint256 locker_pending = 0;
        if (metadata.exists && metadata.feeLocker != address(0)) {
            try
                IClankerFeeLocker(metadata.feeLocker).availableFees(address(this), rewardToken)
            returns (uint256 fees) {
                locker_pending = fees;
            } catch {}
        }

        // Add any tokens already in this contract's balance
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));

        return locker_pending + balance;
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function getDistributionState(
        address rewardToken
    ) external view returns (DistributionState memory state) {
        return _distributionState[rewardToken];
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function isSplitsConfigured() external view returns (bool configured) {
        return _isSplitsConfigured();
    }

    /// @inheritdoc ILevrFeeSplitter_v1
    function getStakingAddress() public view returns (address staking) {
        ILevrFactory_v1.Project memory project = ILevrFactory_v1(factory).getProjectContracts(
            clankerToken
        );
        return project.staking;
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if splits are configured and valid (sum to 100%)
     * @return configured True if splits are properly configured
     */
    function _isSplitsConfigured() internal view returns (bool configured) {
        if (_splits.length == 0) return false;

        uint256 totalBps = 0;
        for (uint256 i = 0; i < _splits.length; i++) {
            totalBps += _splits[i].bps;
        }

        return totalBps == BPS_DENOMINATOR;
    }

    /**
     * @notice Validate split configuration
     * @param splits The splits to validate
     */
    function _validateSplits(SplitConfig[] calldata splits) internal view {
        if (splits.length == 0) revert NoReceivers();

        // Get staking address for this project from factory
        address staking = getStakingAddress();
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
     */
    function _onlyTokenAdmin() internal view {
        address tokenAdmin = IClankerToken(clankerToken).admin();
        if (_msgSender() != tokenAdmin) revert OnlyTokenAdmin();
    }

    /**
     * @notice Internal distribution logic (without reentrancy guard)
     * @param rewardToken The reward token to distribute
     */
    function _distributeSingle(address rewardToken) internal {
        // Get LP locker from factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(clankerToken);
        if (!metadata.exists) revert ClankerMetadataNotFound();
        if (metadata.lpLocker == address(0)) revert LpLockerNotConfigured();

        // Step 1: Collect rewards from LP locker (moves fees from V4 pool to ClankerFeeLocker)
        try IClankerLpLocker(metadata.lpLocker).collectRewards(clankerToken) {
            // Successfully collected from pool to locker
        } catch {
            // Ignore errors
        }

        // Step 2: Claim fees from ClankerFeeLocker to this contract (fee splitter)
        if (metadata.feeLocker != address(0)) {
            try IClankerFeeLocker(metadata.feeLocker).claim(address(this), rewardToken) {
                // Successfully claimed from fee locker to splitter
            } catch {
                // Fee locker might not have this token or fees
            }
        }

        // Check balance available for distribution
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance == 0) return;

        // Distribute according to configured splits
        if (!_isSplitsConfigured()) revert SplitsNotConfigured();

        address staking = getStakingAddress();
        bool sentToStaking = false;

        for (uint256 i = 0; i < _splits.length; i++) {
            SplitConfig memory split = _splits[i];
            uint256 amount = (balance * split.bps) / BPS_DENOMINATOR;

            if (amount > 0) {
                IERC20(rewardToken).safeTransfer(split.receiver, amount);

                if (split.receiver == staking) {
                    sentToStaking = true;
                    emit StakingDistribution(clankerToken, rewardToken, amount);
                }

                emit FeeDistributed(clankerToken, rewardToken, split.receiver, amount);
            }
        }

        // Update distribution state
        _distributionState[rewardToken].totalDistributed += balance;
        _distributionState[rewardToken].lastDistribution = block.timestamp;

        emit Distributed(clankerToken, rewardToken, balance);

        // If we sent fees to staking, automatically call accrueRewards
        if (sentToStaking) {
            ILevrStaking_v1(staking).accrueRewards(rewardToken);
            emit AutoAccrualSuccess(clankerToken, rewardToken);
        }
    }
}
