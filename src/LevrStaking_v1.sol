// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {IClankerFeeLocker} from './interfaces/external/IClankerFeeLocker.sol';
import {IClankerLpLocker} from './interfaces/external/IClankerLpLocker.sol';

contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {}

    address public underlying;
    address public stakedToken;
    address public treasury; // for future integrations
    address public factory; // Levr factory instance
    uint64 private _streamStart;
    uint64 private _streamEnd;
    // Per-token streaming state for UI/APR
    mapping(address => uint64) private _streamStartByToken;
    mapping(address => uint64) private _streamEndByToken;
    mapping(address => uint256) private _streamTotalByToken;
    // Track last settlement timestamp per reward token to vest linearly
    mapping(address => uint64) private _lastUpdateByToken;

    uint256 private _totalStaked;
    mapping(address => uint256) private _staked;

    // Governance: track when each user started staking for time-weighted voting power
    mapping(address => uint256) public stakeStartTime;

    // use ILevrStaking_v1.RewardInfo
    address[] private _rewardTokens;
    mapping(address => ILevrStaking_v1.RewardInfo) private _rewardInfo;
    mapping(address => mapping(address => int256)) private _rewardDebt;
    uint256 private constant ACC_SCALE = 1e18;

    // Track escrowed principal per token to separate it from reward liquidity
    mapping(address => uint256) private _escrowBalance;

    // Track rewards that have been accounted (credited) but not yet claimed
    // for each reward token. Prevents double-accrual and enables liquidity checks.
    mapping(address => uint256) private _rewardReserve;

    function initialize(
        address underlying_,
        address stakedToken_,
        address treasury_,
        address factory_
    ) external {
        // Ensure initialization only happens once
        if (underlying != address(0)) revert AlreadyInitialized();
        if (
            underlying_ == address(0) ||
            stakedToken_ == address(0) ||
            treasury_ == address(0) ||
            factory_ == address(0)
        ) revert ZeroAddress();

        // Only factory can initialize
        if (_msgSender() != factory_) revert OnlyFactory();

        underlying = underlying_;
        stakedToken = stakedToken_;
        treasury = treasury_;
        factory = factory_;
        _rewardInfo[underlying_] = ILevrStaking_v1.RewardInfo({accPerShare: 0, exists: true});
        _rewardTokens.push(underlying_);
    }

    /// @inheritdoc ILevrStaking_v1
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        address staker = _msgSender();
        // Settle streaming for all reward tokens before balance changes
        _settleStreamingAll();

        // Governance: Calculate weighted average timestamp for voting power preservation
        stakeStartTime[staker] = _onStakeNewTimestamp(amount);

        IERC20(underlying).safeTransferFrom(staker, address(this), amount);
        _escrowBalance[underlying] += amount;
        _increaseDebtForAll(staker, amount);
        _staked[staker] += amount;
        _totalStaked += amount;
        ILevrStakedToken_v1(stakedToken).mint(staker, amount);
        emit Staked(staker, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function unstake(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 newVotingPower) {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert ZeroAddress();
        address staker = _msgSender();
        uint256 bal = _staked[staker];
        if (bal < amount) revert InsufficientStake();
        // Settle streaming before changing balances
        _settleStreamingAll();
        _settleAll(staker, to, bal);
        _staked[staker] = bal - amount;
        _updateDebtAll(staker, _staked[staker]);
        _totalStaked -= amount;
        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        uint256 esc = _escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow();
        _escrowBalance[underlying] = esc - amount;
        IERC20(underlying).safeTransfer(to, amount);

        // Governance: Proportionally reduce time on partial unstake, reset to 0 on full unstake
        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new voting power after unstake (for UI simulation)
        // Normalized to token-days for UI-friendly numbers
        uint256 remainingBalance = _staked[staker];
        uint256 newStartTime = stakeStartTime[staker];
        if (remainingBalance > 0 && newStartTime > 0) {
            uint256 timeStaked = block.timestamp - newStartTime;
            newVotingPower = (remainingBalance * timeStaked) / (1e18 * 86400);
        } else {
            newVotingPower = 0;
        }

        emit Unstaked(staker, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function claimRewards(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address claimer = _msgSender();
        uint256 bal = _staked[claimer];
        for (uint256 i = 0; i < tokens.length; i++) {
            _settleStreamingForToken(tokens[i]);
            _settle(tokens[i], claimer, to, bal);
            uint256 acc = _rewardInfo[tokens[i]].accPerShare;
            _rewardDebt[claimer][tokens[i]] = int256((bal * acc) / ACC_SCALE);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function accrueRewards(address token) external nonReentrant {
        // Automatically collect from LP locker and claim any pending rewards from ClankerFeeLocker
        _claimFromClankerFeeLocker(token);

        // Credit all available rewards after claiming
        uint256 available = _availableUnaccountedRewards(token);
        if (available > 0) {
            _creditRewards(token, available);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function outstandingRewards(
        address token
    ) external view returns (uint256 available, uint256 pending) {
        available = _availableUnaccountedRewards(token);
        pending = _getPendingFromClankerFeeLocker(token);
    }

    /// @notice Get claimable rewards for a specific user and token
    /// @param account The user to check rewards for
    /// @param token The reward token to check
    /// @return claimable The amount of rewards the user can claim right now
    function claimableRewards(
        address account,
        address token
    ) external view returns (uint256 claimable) {
        uint256 bal = _staked[account];
        if (bal == 0) return 0;

        ILevrStaking_v1.RewardInfo storage info = _rewardInfo[token];
        if (!info.exists) return 0;

        // Calculate what would be accumulated after settling streaming
        uint256 accPerShare = info.accPerShare;

        // Add any pending streaming rewards
        uint64 start = _streamStartByToken[token];
        uint64 end = _streamEndByToken[token];
        if (end > 0 && start > 0 && block.timestamp > start) {
            uint64 last = _lastUpdateByToken[token];
            uint64 from = last < start ? start : last;
            uint64 to = uint64(block.timestamp);
            if (to > end) to = end;
            if (to > from) {
                uint256 duration = end - start;
                uint256 total = _streamTotalByToken[token];
                if (duration > 0 && total > 0 && _totalStaked > 0) {
                    uint256 vestAmount = (total * (to - from)) / duration;
                    accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;
                }
            }
        }

        uint256 accumulated = (bal * accPerShare) / ACC_SCALE;
        int256 debt = _rewardDebt[account][token];

        if (accumulated > uint256(debt)) {
            claimable = accumulated - uint256(debt);
        }
    }

    /// @notice Get the ClankerFeeLocker address for the underlying token
    function getClankerFeeLocker() external view returns (address) {
        if (factory == address(0)) return address(0);

        // Get clanker metadata from our factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(underlying);
        return metadata.feeLocker;
    }

    /// @inheritdoc ILevrStaking_v1
    function accrueFromTreasury(
        address token,
        uint256 amount,
        bool pullFromTreasury
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (pullFromTreasury) {
            // Only treasury can initiate a pull
            require(_msgSender() == treasury, 'ONLY_TREASURY');
            uint256 beforeAvail = _availableUnaccountedRewards(token);
            IERC20(token).safeTransferFrom(treasury, address(this), amount);
            uint256 afterAvail = _availableUnaccountedRewards(token);
            uint256 delta = afterAvail > beforeAvail ? afterAvail - beforeAvail : 0;
            if (delta > 0) {
                _creditRewards(token, delta);
            }
        } else {
            uint256 available = _availableUnaccountedRewards(token);
            require(available >= amount, 'INSUFFICIENT_AVAILABLE');
            _creditRewards(token, amount);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function stakedBalanceOf(address account) external view returns (uint256) {
        return _staked[account];
    }

    /// @inheritdoc ILevrStaking_v1
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    /// @inheritdoc ILevrStaking_v1
    function escrowBalance(address token) external view returns (uint256) {
        return _escrowBalance[token];
    }

    /// @inheritdoc ILevrStaking_v1
    function streamWindowSeconds() external view returns (uint32) {
        return ILevrFactory_v1(factory).streamWindowSeconds();
    }

    /// @inheritdoc ILevrStaking_v1
    function streamStart() external view returns (uint64) {
        return _streamStart;
    }

    /// @inheritdoc ILevrStaking_v1
    function streamEnd() external view returns (uint64) {
        return _streamEnd;
    }

    /// @inheritdoc ILevrStaking_v1
    function rewardRatePerSecond(address token) external view returns (uint256) {
        uint64 start = _streamStartByToken[token];
        uint64 end = _streamEndByToken[token];
        if (end == 0 || end <= start) return 0;
        if (block.timestamp >= end) return 0;
        uint256 window = end - start;
        uint256 total = _streamTotalByToken[token];
        return total / window;
    }

    /// @inheritdoc ILevrStaking_v1
    function aprBps() external view returns (uint256) {
        if (_totalStaked == 0) return 0;
        uint64 start = _streamStartByToken[underlying];
        uint64 end = _streamEndByToken[underlying];
        if (end == 0 || end <= start) return 0;
        if (block.timestamp >= end) return 0;
        uint256 window = end - start;
        uint256 total = _streamTotalByToken[underlying];
        if (total == 0) return 0;
        uint256 rate = total / window;
        uint256 annual = rate * 365 days;
        return (annual * 10_000) / _totalStaked;
    }

    function _resetStreamForToken(address token, uint256 amount) internal {
        // Query stream window from factory config
        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds();

        _streamStart = uint64(block.timestamp);
        _streamEnd = uint64(block.timestamp + window);
        emit StreamReset(window, _streamStart, _streamEnd);
        _streamStartByToken[token] = uint64(block.timestamp);
        _streamEndByToken[token] = uint64(block.timestamp + window);
        _streamTotalByToken[token] = amount;
        _lastUpdateByToken[token] = uint64(block.timestamp);
    }

    /// @notice Internal function to get pending rewards from ClankerFeeLocker
    function _getPendingFromClankerFeeLocker(address token) internal view returns (uint256) {
        if (factory == address(0)) return 0;

        // Get clanker metadata from our factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(underlying);
        if (!metadata.exists || metadata.feeLocker == address(0)) return 0;

        try IClankerFeeLocker(metadata.feeLocker).availableFees(address(this), token) returns (
            uint256 fees
        ) {
            return fees;
        } catch {
            return 0;
        }
    }

    /// @notice Internal function to claim pending rewards from ClankerFeeLocker
    function _claimFromClankerFeeLocker(address token) internal {
        if (factory == address(0)) return;

        // Get clanker metadata from our factory
        ILevrFactory_v1.ClankerMetadata memory metadata = ILevrFactory_v1(factory)
            .getClankerMetadata(underlying);
        if (!metadata.exists) return;

        // First, collect rewards from LP locker to ensure ClankerFeeLocker has latest fees
        if (metadata.lpLocker != address(0)) {
            try IClankerLpLocker(metadata.lpLocker).collectRewards(underlying) {
                // Successfully collected from LP locker
            } catch {
                // Ignore errors from LP locker - it might not have fees to collect
            }
        }

        // Claim from ClankerFeeLocker if available
        if (metadata.feeLocker != address(0)) {
            try IClankerFeeLocker(metadata.feeLocker).availableFees(address(this), token) returns (
                uint256 availableFees
            ) {
                if (availableFees > 0) {
                    IClankerFeeLocker(metadata.feeLocker).claim(address(this), token);
                }
            } catch {
                // Fee locker might not have this token or staking not set as fee owner
            }
        }
    }

    function _creditRewards(address token, uint256 amount) internal {
        ILevrStaking_v1.RewardInfo storage info = _ensureRewardToken(token);
        // Settle current stream up to now before resetting
        _settleStreamingForToken(token);
        
        // FIX: Calculate unvested rewards from current stream
        uint256 unvested = _calculateUnvested(token);
        
        // Reset stream with NEW amount + UNVESTED from previous stream
        _resetStreamForToken(token, amount + unvested);
        
        // Increase reserve by newly provided amount only
        // (unvested is already in reserve from previous accrual)
        _rewardReserve[token] += amount;
        emit RewardsAccrued(token, amount, info.accPerShare);
    }

    function _ensureRewardToken(
        address token
    ) internal returns (ILevrStaking_v1.RewardInfo storage info) {
        info = _rewardInfo[token];
        if (!info.exists) {
            _rewardInfo[token] = ILevrStaking_v1.RewardInfo({accPerShare: 0, exists: true});
            _rewardTokens.push(token);
            info = _rewardInfo[token];
        }
    }

    function _availableUnaccountedRewards(address token) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == underlying) {
            // exclude escrowed principal when token is the underlying
            if (bal > _escrowBalance[underlying]) {
                bal -= _escrowBalance[underlying];
            } else {
                bal = 0;
            }
        }
        uint256 accounted = _rewardReserve[token];
        return bal > accounted ? bal - accounted : 0;
    }

    function _increaseDebtForAll(address account, uint256 amount) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            uint256 acc = _rewardInfo[rt].accPerShare;
            if (acc > 0) {
                _rewardDebt[account][rt] += int256((amount * acc) / ACC_SCALE);
            }
        }
    }

    function _updateDebtAll(address account, uint256 newBal) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            uint256 acc = _rewardInfo[rt].accPerShare;
            _rewardDebt[account][rt] = int256((newBal * acc) / ACC_SCALE);
        }
    }

    function _settle(address token, address account, address to, uint256 bal) internal {
        _settleStreamingForToken(token);
        ILevrStaking_v1.RewardInfo storage info = _rewardInfo[token];
        if (!info.exists) return;
        uint256 accumulated = (bal * info.accPerShare) / ACC_SCALE;
        int256 debt = _rewardDebt[account][token];
        if (accumulated > uint256(debt)) {
            uint256 pending = accumulated - uint256(debt);
            if (pending > 0) {
                uint256 reserve = _rewardReserve[token];
                if (reserve < pending) revert InsufficientRewardLiquidity();
                _rewardReserve[token] = reserve - pending;
                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(account, to, token, pending);
            }
        }
    }

    function _settleAll(address account, address to, uint256 bal) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _settle(_rewardTokens[i], account, to, bal);
        }
    }

    function _settleStreamingAll() internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _settleStreamingForToken(_rewardTokens[i]);
        }
    }

    function _settleStreamingForToken(address token) internal {
        uint64 start = _streamStartByToken[token];
        uint64 end = _streamEndByToken[token];
        if (end == 0 || start == 0) return;

        // Don't consume stream time if no stakers to preserve rewards
        if (_totalStaked == 0) return;

        uint64 last = _lastUpdateByToken[token];
        uint64 from = last < start ? start : last;
        uint64 to = uint64(block.timestamp);
        if (to > end) to = end;
        if (to <= from) return;
        uint256 duration = end - start;
        uint256 total = _streamTotalByToken[token];
        if (duration == 0 || total == 0) {
            _lastUpdateByToken[token] = to;
            return;
        }
        uint256 vestAmount = (total * (to - from)) / duration;
        if (vestAmount > 0) {
            ILevrStaking_v1.RewardInfo storage info = _rewardInfo[token];
            info.accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;
        }
        // Advance last update only when there are stakers
        _lastUpdateByToken[token] = to;
    }

    /// @notice Calculate unvested rewards from current stream
    /// @dev Returns the amount of rewards that haven't been distributed yet
    /// @param token The reward token to check
    /// @return unvested Amount of unvested rewards (0 if stream is complete or doesn't exist)
    function _calculateUnvested(address token) internal view returns (uint256 unvested) {
        uint64 start = _streamStartByToken[token];
        uint64 end = _streamEndByToken[token];
        
        // No active stream
        if (end == 0 || start == 0) return 0;
        
        uint64 now_ = uint64(block.timestamp);
        
        // Stream hasn't started yet (shouldn't happen, but be safe)
        if (now_ < start) return _streamTotalByToken[token];
        
        // Stream is complete
        if (now_ >= end) return 0;
        
        // Calculate how much is unvested
        uint256 total = _streamTotalByToken[token];
        uint256 duration = end - start;
        
        if (duration == 0) return 0;
        
        // Calculate vested amount
        uint256 elapsed = now_ - start;
        uint256 vested = (total * elapsed) / duration;
        
        // Return unvested portion
        return total > vested ? total - vested : 0;
    }

    // ============ Governance Functions ============

    /// @inheritdoc ILevrStaking_v1
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        uint256 startTime = stakeStartTime[user];
        if (startTime == 0) return 0; // User never staked or has unstaked

        uint256 balance = _staked[user];
        if (balance == 0) return 0; // No staked balance

        uint256 timeStaked = block.timestamp - startTime;

        // Normalize to token-days: divide by 1e18 (token decimals) and 86400 (seconds per day)
        // This makes VP human-readable: 1000 tokens × 100 days = 100,000 token-days
        return (balance * timeStaked) / (1e18 * 86400);
    }

    /// @notice Calculate new stakeStartTime when staking additional tokens
    /// @dev Uses weighted average to preserve voting power while reflecting dilution
    ///      Formula: newStartTime = currentTime - (oldBalance × timeAccumulated) / newTotalBalance
    ///      Example: 100 tokens staked for 30 days, then stake 1000 more
    ///               Old VP: 100 × 30 days = 3000 token-days
    ///               New balance: 1100 tokens
    ///               New time: 3000 / 1100 = 2.727 days
    ///               Result: 1100 tokens with 2.727 days of accumulation (preserves 3000 token-days VP)
    /// @param stakeAmount Amount being staked
    /// @return newStartTime New timestamp to set
    function _onStakeNewTimestamp(
        uint256 stakeAmount
    ) internal view returns (uint256 newStartTime) {
        address staker = _msgSender();
        uint256 oldBalance = _staked[staker];
        uint256 currentStartTime = stakeStartTime[staker];

        // First stake: set timestamp to now
        if (oldBalance == 0 || currentStartTime == 0) {
            return block.timestamp;
        }

        // Calculate accumulated time so far
        uint256 timeAccumulated = block.timestamp - currentStartTime;

        // Calculate new total balance
        uint256 newTotalBalance = oldBalance + stakeAmount;

        // Calculate weighted average time: (oldBalance × timeAccumulated) / newTotalBalance
        // This preserves voting power: oldVP = oldBalance × timeAccumulated
        // After stake: newVP = newTotalBalance × newTimeAccumulated = oldVP (preserved)
        uint256 newTimeAccumulated = (oldBalance * timeAccumulated) / newTotalBalance;

        // Calculate new start time
        newStartTime = block.timestamp - newTimeAccumulated;
    }

    /// @notice Calculate new stakeStartTime after partial unstake
    /// @dev Reduces time accumulation proportionally to amount unstaked
    ///      Formula: newTime = oldTime * (remainingBalance / originalBalance)
    ///      Example: 1000 tokens staked for 100 days, unstake 300 (30%)
    ///               Result: 700 tokens with 70 days of time accumulation
    /// @param unstakeAmount Amount being unstaked
    /// @return newStartTime New timestamp to set (0 if full unstake)
    function _onUnstakeNewTimestamp(
        uint256 unstakeAmount
    ) internal view returns (uint256 newStartTime) {
        address staker = _msgSender();
        uint256 currentStartTime = stakeStartTime[staker];

        // If never staked, return 0
        if (currentStartTime == 0) return 0;

        uint256 remainingBalance = _staked[staker];

        // If no balance remaining, reset to 0
        if (remainingBalance == 0) return 0;

        // Calculate original balance before unstake
        uint256 originalBalance = remainingBalance + unstakeAmount;

        // Calculate time accumulated so far
        uint256 timeAccumulated = block.timestamp - currentStartTime;

        // Proportionally reduce time accumulation
        // newTime = oldTime * (remainingBalance / originalBalance)
        uint256 newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;

        // Calculate new start time
        newStartTime = block.timestamp - newTimeAccumulated;
    }
}
