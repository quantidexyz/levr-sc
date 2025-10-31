// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {IClankerToken} from './interfaces/external/IClankerToken.sol';
import {RewardMath} from './libraries/RewardMath.sol';

contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Precision for voting power calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Seconds per day
    uint256 public constant SECONDS_PER_DAY = 86400;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Minimum reward amount (prevents reward token slot DoS)
    uint256 public constant MIN_REWARD_AMOUNT = 1e15;

    constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {}

    address public underlying;
    address public stakedToken;
    address public treasury;
    address public factory;

    uint256 private _totalStaked;

    // Voting power: tracks when each user started staking (time-weighted)
    mapping(address => uint256) public stakeStartTime;

    address[] private _rewardTokens;
    mapping(address => ILevrStaking_v1.RewardTokenState) private _tokenState;

    // Escrow: tracks user principal separately from rewards
    mapping(address => uint256) private _escrowBalance;

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

        // Initialize underlying token with pool-based state
        _tokenState[underlying_] = ILevrStaking_v1.RewardTokenState({
            availablePool: 0,
            streamTotal: 0,
            lastUpdate: 0,
            exists: true,
            whitelisted: true,
            streamStart: 0,
            streamEnd: 0
        });
        _rewardTokens.push(underlying_);
    }

    /// @inheritdoc ILevrStaking_v1
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        address staker = _msgSender();

        bool isFirstStaker = _totalStaked == 0;

        _settleAllPools();

        // First staker: restart paused streams
        if (isFirstStaker) {
            uint256 len = _rewardTokens.length;
            for (uint256 i = 0; i < len; i++) {
                address rt = _rewardTokens[i];
                ILevrStaking_v1.RewardTokenState storage rtState = _tokenState[rt];

                if (rtState.streamTotal > 0) {
                    _resetStreamForToken(rt, rtState.streamTotal);
                }

                uint256 available = _availableUnaccountedRewards(rt);
                if (available > 0) {
                    _creditRewards(rt, available);
                }
            }
        }

        // Measure actual received (handles fee-on-transfer tokens)
        uint256 balanceBefore = IERC20(underlying).balanceOf(address(this));
        IERC20(underlying).safeTransferFrom(staker, address(this), amount);
        uint256 actualReceived = IERC20(underlying).balanceOf(address(this)) - balanceBefore;

        // Update voting power (weighted average preserves existing VP)
        stakeStartTime[staker] = _onStakeNewTimestamp(actualReceived);

        // Update accounting
        _escrowBalance[underlying] += actualReceived;
        _totalStaked += actualReceived;
        ILevrStakedToken_v1(stakedToken).mint(staker, actualReceived);

        emit Staked(staker, actualReceived);
    }

    /// @inheritdoc ILevrStaking_v1
    function unstake(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 newVotingPower) {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert ZeroAddress();
        address staker = _msgSender();
        uint256 bal = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (bal < amount) revert InsufficientStake();

        // Auto-claim all rewards (prevents accidental loss)
        _claimAllRewards(staker, to);

        // Burn and transfer
        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        _totalStaked -= amount;
        uint256 esc = _escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow();
        _escrowBalance[underlying] = esc - amount;
        IERC20(underlying).safeTransfer(to, amount);

        // Update voting power (proportional reduction on partial unstake)
        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new VP for return value (UI convenience)
        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 newStartTime = stakeStartTime[staker];
        if (remainingBalance > 0 && newStartTime > 0) {
            uint256 timeStaked = block.timestamp - newStartTime;
            newVotingPower = (remainingBalance * timeStaked) / (PRECISION * SECONDS_PER_DAY);
        }

        emit Unstaked(staker, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function claimRewards(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address claimer = _msgSender();
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        uint256 cachedTotalStaked = _totalStaked;
        if (cachedTotalStaked == 0) return;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue;

            _settlePoolForToken(token);

            // Pool-based: proportional claim = (userBalance / totalStaked) × pool
            uint256 claimable = RewardMath.calculateProportionalClaim(
                userBalance,
                cachedTotalStaked,
                tokenState.availablePool
            );

            if (claimable > 0) {
                tokenState.availablePool -= claimable;
                IERC20(token).safeTransfer(to, claimable);
                emit RewardsClaimed(claimer, to, token, claimable);
            }
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function accrueRewards(address token) external nonReentrant {
        // Accrue unaccounted rewards (fee collection handled externally via SDK)
        uint256 available = _availableUnaccountedRewards(token);
        if (available > 0) {
            _creditRewards(token, available);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function whitelistToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();

        // Only token admin can whitelist
        address tokenAdmin = IClankerToken(underlying).admin();
        require(_msgSender() == tokenAdmin, 'ONLY_TOKEN_ADMIN');

        // Cannot whitelist already whitelisted token
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        require(!tokenState.whitelisted, 'ALREADY_WHITELISTED');

        tokenState.whitelisted = true;

        // If token doesn't exist yet, initialize it with whitelisted status
        if (!tokenState.exists) {
            tokenState.exists = true;
            tokenState.availablePool = 0;
            tokenState.streamTotal = 0;
            tokenState.lastUpdate = 0;
            tokenState.streamStart = 0;
            tokenState.streamEnd = 0;
        }

        emit ILevrStaking_v1.TokenWhitelisted(token);
    }

    /// @inheritdoc ILevrStaking_v1
    function cleanupFinishedRewardToken(address token) external nonReentrant {
        require(token != underlying, 'CANNOT_REMOVE_UNDERLYING');

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        require(tokenState.exists, 'TOKEN_NOT_REGISTERED');
        require(!tokenState.whitelisted, 'CANNOT_REMOVE_WHITELISTED');
        require(
            tokenState.availablePool == 0 && tokenState.streamTotal == 0,
            'REWARDS_STILL_PENDING'
        );

        _removeTokenFromArray(token);
        delete _tokenState[token];

        emit ILevrStaking_v1.RewardTokenRemoved(token);
    }

    /// @inheritdoc ILevrStaking_v1
    function outstandingRewards(address token) external view returns (uint256 available) {
        available = _availableUnaccountedRewards(token);
    }

    /// @inheritdoc ILevrStaking_v1
    function claimableRewards(
        address account,
        address token
    ) external view returns (uint256 claimable) {
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(account);
        if (userBalance == 0) return 0;

        uint256 cachedTotalStaked = _totalStaked;
        if (cachedTotalStaked == 0) return 0;

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) return 0;

        // Calculate current pool including vested rewards using library (CRITICAL-3 fix: use per-token window)
        uint256 currentPool = RewardMath.calculateCurrentPool(
            tokenState.availablePool,
            tokenState.streamTotal,
            tokenState.streamStart,
            tokenState.streamEnd,
            tokenState.lastUpdate,
            uint64(block.timestamp)
        );

        // Calculate proportional claim (simple pool-based)
        claimable = RewardMath.calculateProportionalClaim(
            userBalance,
            cachedTotalStaked,
            currentPool
        );
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
        return ILevrStakedToken_v1(stakedToken).balanceOf(account);
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
        return ILevrFactory_v1(factory).streamWindowSeconds(underlying);
    }

    /// @inheritdoc ILevrStaking_v1
    function getTokenStreamInfo(
        address token
    ) external view returns (uint64 streamStart, uint64 streamEnd, uint256 streamTotal) {
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        return (tokenState.streamStart, tokenState.streamEnd, tokenState.streamTotal);
    }

    /// @inheritdoc ILevrStaking_v1
    function getWhitelistedTokens() external view returns (address[] memory) {
        uint256 count = 0;
        uint256 len = _rewardTokens.length;

        // Count whitelisted tokens
        for (uint256 i = 0; i < len; i++) {
            if (_tokenState[_rewardTokens[i]].whitelisted) {
                count++;
            }
        }

        // Build array
        address[] memory whitelisted = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < len; i++) {
            if (_tokenState[_rewardTokens[i]].whitelisted) {
                whitelisted[index] = _rewardTokens[i];
                index++;
            }
        }

        return whitelisted;
    }

    /// @inheritdoc ILevrStaking_v1
    function isTokenWhitelisted(address token) external view returns (bool) {
        return _tokenState[token].whitelisted;
    }

    /// @inheritdoc ILevrStaking_v1
    function rewardRatePerSecond(address token) external view returns (uint256) {
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

        // Use PER-TOKEN stream window (CRITICAL-3 fix: isolation)
        uint64 start = tokenState.streamStart;
        uint64 end = tokenState.streamEnd;
        if (end == 0 || end <= start) return 0;
        if (block.timestamp >= end) return 0;
        uint256 window = end - start;
        return tokenState.streamTotal / window;
    }

    /// @inheritdoc ILevrStaking_v1
    function aprBps() external view returns (uint256) {
        if (_totalStaked == 0) return 0;

        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);
        if (window == 0) return 0;

        // CRITICAL-3 fix: Aggregate APR from ALL active streams
        uint256 totalAnnualRate = 0;

        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address token = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

            // Only include active streams
            if (
                tokenState.streamTotal > 0 &&
                tokenState.streamEnd > block.timestamp &&
                tokenState.streamStart > 0
            ) {
                uint256 rate = tokenState.streamTotal / window;
                uint256 annual = rate * 365 days;
                totalAnnualRate += annual;
            }
        }

        if (totalAnnualRate == 0) return 0;
        return (totalAnnualRate * BASIS_POINTS) / _totalStaked;
    }

    function _resetStreamForToken(address token, uint256 amount) internal {
        // Query stream window from factory config
        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);

        // Set PER-TOKEN stream window (CRITICAL-3 fix: isolation)
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        tokenState.streamStart = uint64(block.timestamp);
        tokenState.streamEnd = uint64(block.timestamp + window);
        tokenState.streamTotal = amount;
        tokenState.lastUpdate = uint64(block.timestamp);

        emit StreamReset(token, window, tokenState.streamStart, tokenState.streamEnd);
    }

    function _creditRewards(address token, uint256 amount) internal {
        require(amount >= MIN_REWARD_AMOUNT, 'REWARD_TOO_SMALL');

        RewardTokenState storage tokenState = _ensureRewardToken(token);

        _settlePoolForToken(token);

        // Add new rewards to stream (preserves unvested from previous stream)
        _resetStreamForToken(token, amount + tokenState.streamTotal);

        emit RewardsAccrued(token, amount, tokenState.availablePool);
    }

    function _ensureRewardToken(
        address token
    ) internal returns (ILevrStaking_v1.RewardTokenState storage tokenState) {
        tokenState = _tokenState[token];
        if (!tokenState.exists) {
            bool wasWhitelisted = tokenState.whitelisted;
            if (!wasWhitelisted) {
                // Enforce max reward tokens (whitelisted tokens exempt)
                uint16 maxRewardTokens = ILevrFactory_v1(factory).maxRewardTokens(underlying);

                uint256 nonWhitelistedCount = 0;
                for (uint256 i = 0; i < _rewardTokens.length; i++) {
                    if (!_tokenState[_rewardTokens[i]].whitelisted) {
                        nonWhitelistedCount++;
                    }
                }
                require(nonWhitelistedCount < maxRewardTokens, 'MAX_REWARD_TOKENS_REACHED');
            }

            _tokenState[token] = ILevrStaking_v1.RewardTokenState({
                availablePool: 0,
                streamTotal: 0,
                lastUpdate: 0,
                exists: true,
                whitelisted: wasWhitelisted,
                streamStart: 0,
                streamEnd: 0
            });
            tokenState = _tokenState[token];
            _rewardTokens.push(token);
        }
    }

    /// @notice Internal helper to remove token from array
    /// @param token The token to remove
    function _removeTokenFromArray(address token) internal {
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            if (_rewardTokens[i] == token) {
                // Swap with last element and pop
                _rewardTokens[i] = _rewardTokens[_rewardTokens.length - 1];
                _rewardTokens.pop();
                break;
            }
        }
    }

    function _availableUnaccountedRewards(address token) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));

        // Exclude escrowed principal for underlying token
        if (token == underlying) {
            if (bal > _escrowBalance[underlying]) {
                bal -= _escrowBalance[underlying];
            } else {
                bal = 0;
            }
        }

        // Unaccounted = balance - (pool + streaming)
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        uint256 accounted = tokenState.availablePool + tokenState.streamTotal;
        return bal > accounted ? bal - accounted : 0;
    }

    /// @notice Auto-claim all rewards for a user (used in unstake)
    /// @param claimer The user claiming rewards
    /// @param to The address to send rewards to
    function _claimAllRewards(address claimer, address to) internal {
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        uint256 cachedTotalStaked = _totalStaked;
        if (cachedTotalStaked == 0) return;

        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue;

            // Settle pool to latest
            _settlePoolForToken(token);

            // Calculate proportional share
            uint256 claimable = RewardMath.calculateProportionalClaim(
                userBalance,
                cachedTotalStaked,
                tokenState.availablePool
            );

            if (claimable > 0) {
                // Reduce pool
                tokenState.availablePool -= claimable;

                // Transfer rewards
                IERC20(token).safeTransfer(to, claimable);
                emit RewardsClaimed(claimer, to, token, claimable);
            }
        }
    }

    /// @notice Settle all reward pools to current time
    function _settleAllPools() internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _settlePoolForToken(_rewardTokens[i]);
        }
    }

    /// @notice Settle reward pool by vesting streamed rewards
    function _settlePoolForToken(address token) internal {
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

        // Use PER-TOKEN stream window (CRITICAL-3 fix: isolation)
        uint64 start = tokenState.streamStart;
        uint64 end = tokenState.streamEnd;
        if (end == 0 || start == 0) return;

        // Pause if no stakers (preserves rewards)
        if (_totalStaked == 0) {
            tokenState.lastUpdate = uint64(block.timestamp);
            return;
        }

        uint64 last = tokenState.lastUpdate;
        uint64 current = uint64(block.timestamp);

        uint64 settleTo;
        if (current > end) {
            if (last >= end) return;
            settleTo = end;
        } else {
            settleTo = current;
        }

        (uint256 vestAmount, uint64 newLast) = RewardMath.calculateVestedAmount(
            tokenState.streamTotal,
            start,
            end,
            last,
            settleTo
        );

        if (vestAmount > 0) {
            tokenState.availablePool += vestAmount;
            tokenState.streamTotal -= vestAmount;
        }

        tokenState.lastUpdate = newLast;
    }

    // ============ Governance Functions ============

    /// @inheritdoc ILevrStaking_v1
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        uint256 startTime = stakeStartTime[user];
        if (startTime == 0) return 0;

        uint256 balance = ILevrStakedToken_v1(stakedToken).balanceOf(user);
        if (balance == 0) return 0;

        uint256 timeStaked = block.timestamp - startTime;

        // VP = balance × time / (1e18 × 86400) → token-days (e.g., 1000 tokens × 100 days = 100k)
        return (balance * timeStaked) / (PRECISION * SECONDS_PER_DAY);
    }

    // ============ Internal Wrappers for Stake/Unstake Operations ============

    /// @notice Internal version for stake operation
    /// @dev Uses weighted average to preserve voting power while reflecting dilution
    /// @param stakeAmount Amount being staked
    /// @return newStartTime New timestamp to set
    function _onStakeNewTimestamp(
        uint256 stakeAmount
    ) internal view returns (uint256 newStartTime) {
        address staker = _msgSender();
        uint256 oldBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
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

    /// @notice Internal version for unstake operation
    /// @dev Reduces time accumulation proportionally to amount unstaked
    /// @param unstakeAmount Amount being unstaked
    /// @return newStartTime New timestamp to set (0 if full unstake)
    function _onUnstakeNewTimestamp(
        uint256 unstakeAmount
    ) internal view returns (uint256 newStartTime) {
        address staker = _msgSender();
        uint256 currentStartTime = stakeStartTime[staker];

        // If never staked, return 0
        if (currentStartTime == 0) return 0;

        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);

        // If no balance remaining, reset to 0
        if (remainingBalance == 0) return 0;

        // Calculate original balance before unstake
        uint256 originalBalance = remainingBalance + unstakeAmount;

        // Calculate time accumulated so far
        uint256 timeAccumulated = block.timestamp - currentStartTime;

        // Preserve precision: calculate (oldTime * remaining) / original
        uint256 newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;

        // Calculate new start time
        newStartTime = block.timestamp - newTimeAccumulated;
    }
}
