// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {IClankerToken} from './interfaces/external/IClankerToken.sol';
import {RewardMath} from './libraries/RewardMath.sol';
import {VotingPowerMath} from './libraries/VotingPowerMath.sol';

/// @title Levr Staking v1
/// @notice Multi-token reward staking with time-weighted voting power
/// @dev Supports tokens with different decimals via normalization. Pool-based distribution with streaming.
contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant TARGET_DECIMALS = 18;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant BASIS_POINTS = 10_000;

    constructor(address trustedForwarder, address factory_) ERC2771ContextBase(trustedForwarder) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    address public underlying;
    address public stakedToken;
    address public treasury;
    address public immutable factory;

    uint256 private _totalStaked;

    uint8 public underlyingDecimals;
    uint256 public precision;

    mapping(address => uint256) public stakeStartTime;
    mapping(address => uint256) private _lastStakeBlock;

    address[] private _rewardTokens;
    mapping(address => ILevrStaking_v1.RewardTokenState) private _tokenState;
    mapping(address => uint256) private _escrowBalance;

    // MasterChef pattern: accRewardPerShare tracks cumulative rewards, rewardDebt tracks user's accounted amount
    mapping(address => uint256) public accRewardPerShare;
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /// @inheritdoc ILevrStaking_v1
    function initialize(
        address underlying_,
        address stakedToken_,
        address treasury_,
        address[] memory initialWhitelistedTokens
    ) external {
        if (underlying != address(0)) revert AlreadyInitialized();
        if (underlying_ == address(0) || stakedToken_ == address(0) || treasury_ == address(0))
            revert ZeroAddress();
        if (_msgSender() != factory) revert OnlyFactory();

        underlying = underlying_;
        stakedToken = stakedToken_;
        treasury = treasury_;

        underlyingDecimals = _queryDecimals(underlying_);
        precision = 10 ** uint256(underlyingDecimals);

        // Initialize underlying token state (always whitelisted)
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

        // Initialize whitelisted tokens from factory config
        for (uint256 i; i < initialWhitelistedTokens.length; ++i) {
            address token = initialWhitelistedTokens[i];

            if (token == address(0) || token == underlying_ || _tokenState[token].exists) continue;

            _tokenState[token] = ILevrStaking_v1.RewardTokenState({
                availablePool: 0,
                streamTotal: 0,
                lastUpdate: 0,
                exists: true,
                whitelisted: true,
                streamStart: 0,
                streamEnd: 0
            });
            _rewardTokens.push(token);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Measures actual received for fee-on-transfer tokens. First staker resumes paused streams.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        address staker = _msgSender();

        bool isFirstStaker = _totalStaked == 0;

        _settleAllPools();

        // Auto-claim existing rewards before staking (prevents self-dilution)
        uint256 existingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (existingBalance > 0) {
            _claimAllRewards(staker, staker);
        }

        // First staker: restart paused streams and accrue unaccounted rewards
        if (isFirstStaker) {
            uint256 len = _rewardTokens.length;
            for (uint256 i; i < len; ++i) {
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

        // Measure actual received (critical for fee-on-transfer tokens)
        uint256 balanceBefore = IERC20(underlying).balanceOf(address(this));
        IERC20(underlying).safeTransferFrom(staker, address(this), amount);
        uint256 actualReceived = IERC20(underlying).balanceOf(address(this)) - balanceBefore;

        stakeStartTime[staker] = _onStakeNewTimestamp(actualReceived);
        _lastStakeBlock[staker] = block.number;

        _escrowBalance[underlying] += actualReceived;
        _totalStaked += actualReceived;
        ILevrStakedToken_v1(stakedToken).mint(staker, actualReceived);

        // Update reward debt for all tokens (prevents dilution)
        uint256 rewardTokensLen = _rewardTokens.length;
        for (uint256 i; i < rewardTokensLen; ++i) {
            address token = _rewardTokens[i];
            rewardDebt[staker][token] = accRewardPerShare[token];
        }

        emit Staked(staker, actualReceived);
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Auto-claims all rewards before unstaking. Returns new voting power for UI.
    function unstake(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 newVotingPower) {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert ZeroAddress();
        address staker = _msgSender();
        uint256 bal = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (bal < amount) revert InsufficientStake();

        _claimAllRewards(staker, to);

        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        _totalStaked -= amount;
        uint256 esc = _escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow();
        _escrowBalance[underlying] = esc - amount;

        IERC20(underlying).safeTransfer(to, amount);

        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new voting power for return value
        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 newStartTime = stakeStartTime[staker];
        if (remainingBalance > 0 && newStartTime > 0) {
            uint256 timeStaked = block.timestamp - newStartTime;
            uint256 normalizedBalance = VotingPowerMath.normalizeBalance(
                remainingBalance,
                underlyingDecimals
            );
            newVotingPower = (normalizedBalance * timeStaked) / (1e18 * SECONDS_PER_DAY);
        }

        emit Unstaked(staker, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Uses debt accounting to prevent dilution attacks (MasterChef pattern)
    function claimRewards(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address claimer = _msgSender();
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue;

            _settlePoolForToken(token);

            uint256 effectiveDebt = _getEffectiveDebt(claimer, token);

            uint256 pending = RewardMath.calculatePendingRewards(
                userBalance,
                accRewardPerShare[token],
                effectiveDebt
            );

            if (pending > 0) {
                tokenState.availablePool -= pending;
                rewardDebt[claimer][token] = accRewardPerShare[token];

                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(claimer, to, token, pending);
            }
        }
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Permissionless - anyone can trigger accrual of unaccounted balances
    function accrueRewards(address token) external nonReentrant {
        uint256 available = _availableUnaccountedRewards(token);
        if (available > 0) {
            _creditRewards(token, available);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Only token admin can whitelist. Underlying always whitelisted (cannot be modified).
    function whitelistToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (token == underlying) revert CannotModifyUnderlying();

        address tokenAdmin = IClankerToken(underlying).admin();
        if (_msgSender() != tokenAdmin) revert OnlyTokenAdmin();

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (tokenState.whitelisted) revert AlreadyWhitelisted();

        // If exists, ensure no pending rewards
        if (tokenState.exists) {
            if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
                revert CannotWhitelistWithPendingRewards();
            }
        }

        tokenState.whitelisted = true;

        // Initialize if first time
        if (!tokenState.exists) {
            tokenState.exists = true;
            tokenState.availablePool = 0;
            tokenState.streamTotal = 0;
            tokenState.lastUpdate = 0;
            tokenState.streamStart = 0;
            tokenState.streamEnd = 0;
            _rewardTokens.push(token);

            // Reset accounting for clean start (prevents corruption on re-add)
            accRewardPerShare[token] = 0;
        }

        emit ILevrStaking_v1.TokenWhitelisted(token);
    }

    /// @inheritdoc ILevrStaking_v1
    function unwhitelistToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (token == underlying) revert CannotUnwhitelistUnderlying();

        address tokenAdmin = IClankerToken(underlying).admin();
        if (_msgSender() != tokenAdmin) revert OnlyTokenAdmin();

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) revert TokenNotRegistered();
        if (!tokenState.whitelisted) revert NotWhitelisted();

        // Cannot unwhitelist with pending rewards
        if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
            revert CannotUnwhitelistWithPendingRewards();
        }

        _settlePoolForToken(token);

        // Verify again after settlement
        if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
            revert CannotUnwhitelistWithPendingRewards();
        }

        tokenState.whitelisted = false;

        emit ILevrStaking_v1.TokenUnwhitelisted(token);
    }

    /// @inheritdoc ILevrStaking_v1
    function cleanupFinishedRewardToken(address token) external nonReentrant {
        if (token == underlying) revert CannotRemoveUnderlying();

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) revert TokenNotRegistered();
        if (tokenState.whitelisted) revert CannotRemoveWhitelisted();
        if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
            revert RewardsTillPending();
        }

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

        // Calculate what accRewardPerShare would be if we settled now
        uint256 currentAccRewardPerShare = accRewardPerShare[token];

        // Add any pending vested rewards
        (uint256 vestAmount, ) = RewardMath.calculateVestedAmount(
            tokenState.streamTotal,
            tokenState.streamStart,
            tokenState.streamEnd,
            tokenState.lastUpdate,
            uint64(block.timestamp)
        );

        if (vestAmount > 0 && cachedTotalStaked > 0) {
            currentAccRewardPerShare += (vestAmount * 1e18) / cachedTotalStaked;
        }

        // Calculate pending using debt accounting (prevents dilution attack)
        claimable = RewardMath.calculatePendingRewards(
            userBalance,
            currentAccRewardPerShare,
            rewardDebt[account][token]
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
            if (_msgSender() != treasury) revert ILevrFactory_v1.UnauthorizedCaller();
            uint256 beforeAvail = _availableUnaccountedRewards(token);
            IERC20(token).safeTransferFrom(treasury, address(this), amount);
            uint256 afterAvail = _availableUnaccountedRewards(token);
            uint256 delta = afterAvail > beforeAvail ? afterAvail - beforeAvail : 0;
            if (delta > 0) {
                _creditRewards(token, delta);
            }
        } else {
            uint256 available = _availableUnaccountedRewards(token);
            if (available < amount) revert InsufficientAvailable();
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
        for (uint256 i; i < len; ++i) {
            if (_tokenState[_rewardTokens[i]].whitelisted) {
                count++;
            }
        }

        // Build array
        address[] memory whitelisted = new address[](count);
        uint256 index = 0;
        for (uint256 i; i < len; ++i) {
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

        for (uint256 i; i < _rewardTokens.length; ++i) {
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
        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        tokenState.streamStart = uint64(block.timestamp);
        tokenState.streamEnd = uint64(block.timestamp + window);
        tokenState.streamTotal = amount;
        tokenState.lastUpdate = uint64(block.timestamp);

        emit StreamReset(token, window, tokenState.streamStart, tokenState.streamEnd);
    }

    /// @notice Credit rewards with streaming. Minimum: 0.001 tokens (prevents DoS)
    /// @dev Extends stream window and includes unvested from previous stream
    function _creditRewards(address token, uint256 amount) internal {
        // Token-aware minimum: 0.001 tokens prevents DoS
        uint8 tokenDecimals = _queryDecimals(token);
        uint256 minReward = (10 ** uint256(tokenDecimals)) / 1000;
        if (amount < minReward) revert RewardTooSmall();

        RewardTokenState storage tokenState = _ensureRewardToken(token);

        _settlePoolForToken(token);

        // Add to stream (includes unvested from previous)
        _resetStreamForToken(token, amount + tokenState.streamTotal);

        emit RewardsAccrued(token, amount, tokenState.availablePool);
    }

    function _ensureRewardToken(
        address token
    ) internal view returns (ILevrStaking_v1.RewardTokenState storage tokenState) {
        tokenState = _tokenState[token];

        if (!tokenState.exists) revert TokenNotWhitelisted();
        if (!tokenState.whitelisted) revert TokenNotWhitelisted();
    }

    /// @notice Remove token from array
    function _removeTokenFromArray(address token) internal {
        for (uint256 i; i < _rewardTokens.length; ++i) {
            if (_rewardTokens[i] == token) {
                _rewardTokens[i] = _rewardTokens[_rewardTokens.length - 1];
                _rewardTokens.pop();
                break;
            }
        }
    }

    /// @notice Calculate unaccounted rewards (balance - escrow - tracked)
    /// @dev For underlying: excludes escrowed principal
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

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        uint256 accounted = tokenState.availablePool + tokenState.streamTotal;
        return bal > accounted ? bal - accounted : 0;
    }

    /// @notice Get effective debt, auto-resetting stale debt from token re-add
    /// @dev Stale debt detected when debt > accRewardPerShare (only after accRewardPerShare reset)
    function _getEffectiveDebt(
        address user,
        address token
    ) internal returns (uint256 effectiveDebt) {
        uint256 debt = rewardDebt[user][token];
        uint256 accReward = accRewardPerShare[token];

        // Stale debt: reset to 0 to allow claiming from re-whitelist point
        if (debt > accReward) {
            rewardDebt[user][token] = 0;
            return 0;
        }

        return debt;
    }

    /// @notice Auto-claim all rewards for user (used in unstake)
    function _claimAllRewards(address claimer, address to) internal {
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        uint256 len = _rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue;

            _settlePoolForToken(token);

            uint256 effectiveDebt = _getEffectiveDebt(claimer, token);

            uint256 pending = RewardMath.calculatePendingRewards(
                userBalance,
                accRewardPerShare[token],
                effectiveDebt
            );

            if (pending > 0) {
                tokenState.availablePool -= pending;
                rewardDebt[claimer][token] = accRewardPerShare[token];

                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(claimer, to, token, pending);
            }
        }
    }

    /// @notice Settle all reward pools to current timestamp
    function _settleAllPools() internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            _settlePoolForToken(_rewardTokens[i]);
        }
    }

    /// @notice Settle pool by vesting streamed rewards. Pauses if no stakers.
    function _settlePoolForToken(address token) internal {
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

        uint64 start = tokenState.streamStart;
        uint64 end = tokenState.streamEnd;
        if (end == 0 || start == 0) return;

        // Pause streaming if no stakers (preserves rewards)
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

            // Update accRewardPerShare (prevents dilution)
            accRewardPerShare[token] += (vestAmount * 1e18) / _totalStaked;
        }

        tokenState.lastUpdate = newLast;
    }

    /// @notice Query token decimals (1-18). Falls back to 18 for non-standard tokens.
    function _queryDecimals(address token) internal view returns (uint8 decimals) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            if (d == 0 || d > 18) revert InvalidTokenDecimals();
            return d;
        } catch {
            return 18;
        }
    }

    // ============ Governance Functions ============

    /// @inheritdoc ILevrStaking_v1
    function lastStakeBlock(address user) external view returns (uint256) {
        return _lastStakeBlock[user];
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Returns token-days. Normalized to 18 decimals for fair cross-token governance.
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        uint256 balance = ILevrStakedToken_v1(stakedToken).balanceOf(user);
        if (balance == 0) return 0;

        uint256 normalizedBalance = VotingPowerMath.normalizeBalance(balance, underlyingDecimals);

        return VotingPowerMath.calculateVotingPower(normalizedBalance, stakeStartTime[user]);
    }

    // ============ Internal Wrappers for Stake/Unstake Operations ============

    /// @notice Calculate new timestamp for stake (weighted average preserves VP)
    function _onStakeNewTimestamp(
        uint256 stakeAmount
    ) internal view returns (uint256 newStartTime) {
        address staker = _msgSender();
        uint256 oldBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 currentStartTime = stakeStartTime[staker];

        return VotingPowerMath.calculateStakeTimestamp(oldBalance, stakeAmount, currentStartTime);
    }

    /// @notice Calculate new timestamp for unstake (proportional reduction)
    function _onUnstakeNewTimestamp(
        uint256 unstakeAmount
    ) internal view returns (uint256 newStartTime) {
        address staker = _msgSender();
        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 currentStartTime = stakeStartTime[staker];

        return
            VotingPowerMath.calculateUnstakeTimestamp(
                remainingBalance,
                unstakeAmount,
                currentStartTime
            );
    }
}
