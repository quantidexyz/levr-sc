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

/// @title Levr Staking v1
/// @notice Multi-token reward staking with time-weighted voting power
/// @dev Supports tokens with different decimals (6, 8, 18) via automatic normalization
///      - Staking: Direct underlying token deposits
///      - Rewards: Pool-based distribution with streaming
///      - Voting: Normalized to 18 decimals for fair governance
contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Target decimals for voting power normalization
    /// @dev All balances normalized to 18 decimals for fair cross-token voting
    uint256 public constant TARGET_DECIMALS = 18;

    /// @notice Seconds per day for voting power calculations
    uint256 public constant SECONDS_PER_DAY = 86400;

    /// @notice Basis points denominator (10000 = 100%)
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

    // Token-aware precision for decimal normalization
    uint8 public underlyingDecimals; // Token decimals (6, 8, 18, etc.)
    uint256 public precision; // 10^underlyingDecimals

    // Voting power: tracks when each user started staking (time-weighted)
    mapping(address => uint256) public stakeStartTime;

    /// @notice Array of all registered reward tokens
    /// @dev Underlying is always first, whitelisted tokens added during init/whitelist
    address[] private _rewardTokens;

    /// @notice State tracking for each reward token
    /// @dev Maps token address to pool state (balance, streaming, whitelist status)
    mapping(address => ILevrStaking_v1.RewardTokenState) private _tokenState;

    /// @notice Escrowed balances per token (principal held for stakers)
    /// @dev Separates user deposits from rewards for accurate accounting
    mapping(address => uint256) private _escrowBalance;

    // Reward accounting: prevents dilution attack (MasterChef pattern)
    // Tracks cumulative rewards per staked token (scaled by 1e18, never decreases)
    mapping(address => uint256) public accRewardPerShare;
    // Tracks user's reward debt per token (what they've already accounted for)
    mapping(address => mapping(address => uint256)) public rewardDebt;

    function initialize(
        address underlying_,
        address stakedToken_,
        address treasury_,
        address[] memory initialWhitelistedTokens
    ) external {
        // Ensure initialization only happens once
        if (underlying != address(0)) revert AlreadyInitialized();
        if (underlying_ == address(0) || stakedToken_ == address(0) || treasury_ == address(0))
            revert ZeroAddress();

        // Only factory can initialize (prevents front-running attacks)
        if (_msgSender() != factory) revert OnlyFactory();

        underlying = underlying_;
        stakedToken = stakedToken_;
        treasury = treasury_;

        // Query token decimals and set precision for decimal-aware operations
        // Supports 1-18 decimals (USDC=6, WBTC=8, DAI=18)
        underlyingDecimals = _queryDecimals(underlying_);
        precision = 10 ** uint256(underlyingDecimals);
        // Note: Minimum reward = precision / 1000 (calculated inline to save storage)

        // Initialize underlying token with pool-based state (ALWAYS whitelisted - separate from array)
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

        // Initialize additional whitelisted tokens from factory config (e.g., WETH)
        for (uint256 i = 0; i < initialWhitelistedTokens.length; i++) {
            address token = initialWhitelistedTokens[i];

            // Factory ensures: token is not underlying and token is not zero address and no duplicates
            if (token == address(0) || token == underlying_ || _tokenState[token].exists) continue;

            // Initialize whitelisted token
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
    /// @dev Handles fee-on-transfer tokens by measuring actual received amount
    ///      First staker resumes paused reward streams
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        address staker = _msgSender();

        bool isFirstStaker = _totalStaked == 0;

        // Settle all reward pools to latest state
        _settleAllPools();

        // Auto-claim existing rewards before staking more (prevents self-dilution)
        uint256 existingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (existingBalance > 0) {
            _claimAllRewards(staker, staker);
        }

        // First staker: restart paused streams
        if (isFirstStaker) {
            uint256 len = _rewardTokens.length;
            for (uint256 i = 0; i < len; i++) {
                address rt = _rewardTokens[i];
                ILevrStaking_v1.RewardTokenState storage rtState = _tokenState[rt];

                // Restart streaming for tokens with unvested rewards
                if (rtState.streamTotal > 0) {
                    _resetStreamForToken(rt, rtState.streamTotal);
                }

                // Accrue any unaccounted rewards (e.g., fees collected during pause)
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

        // Update voting power using weighted average (preserves existing VP on new stakes)
        stakeStartTime[staker] = _onStakeNewTimestamp(actualReceived);

        // Update accounting: escrow, total staked, mint receipt token
        _escrowBalance[underlying] += actualReceived;
        _totalStaked += actualReceived;
        ILevrStakedToken_v1(stakedToken).mint(staker, actualReceived);

        // Update reward debt for all tokens (prevents dilution on future claims)
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens[i];
            rewardDebt[staker][token] = accRewardPerShare[token];
        }

        emit Staked(staker, actualReceived);
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Automatically claims all rewards before unstaking to prevent loss
    ///      Returns new voting power for UI convenience (reflects partial unstake impact)
    function unstake(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 newVotingPower) {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert ZeroAddress();
        address staker = _msgSender();
        uint256 bal = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (bal < amount) revert InsufficientStake();

        // Auto-claim all rewards to prevent user accidentally losing unclaimed rewards
        _claimAllRewards(staker, to);

        // Burn receipt token and update accounting
        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        _totalStaked -= amount;
        uint256 esc = _escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow(); // Safety check
        _escrowBalance[underlying] = esc - amount;

        // Transfer underlying back to recipient
        IERC20(underlying).safeTransfer(to, amount);

        // Update voting power (proportional time reduction on partial unstake)
        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new voting power for return value (UI can display impact)
        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 newStartTime = stakeStartTime[staker];
        if (remainingBalance > 0 && newStartTime > 0) {
            uint256 timeStaked = block.timestamp - newStartTime;
            // Normalize balance to 18 decimals for fair voting power
            uint256 normalizedBalance = _normalizeBalance(remainingBalance);
            newVotingPower = (normalizedBalance * timeStaked) / (1e18 * SECONDS_PER_DAY);
        }

        emit Unstaked(staker, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Pool-based rewards: user gets (balance/totalStaked) × available pool
    ///      Each token can have different decimals (handled in native units)
    function claimRewards(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address claimer = _msgSender();
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue; // Skip unregistered tokens

            // Settle to move vested stream rewards into available pool
            _settlePoolForToken(token);

            // Get effective debt (auto-resets stale debt from token removal/re-add)
            uint256 effectiveDebt = _getEffectiveDebt(claimer, token);

            // Calculate pending rewards using debt accounting (prevents dilution attack)
            uint256 pending = RewardMath.calculatePendingRewards(
                userBalance,
                accRewardPerShare[token],
                effectiveDebt
            );

            if (pending > 0) {
                tokenState.availablePool -= pending;

                // Update user's debt to current accumulated
                rewardDebt[claimer][token] = accRewardPerShare[token];

                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(claimer, to, token, pending);
            }
        }
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Permissionless: Anyone can trigger accrual of unaccounted token balances
    ///      Useful after fee collection or direct transfers to staking contract
    function accrueRewards(address token) external nonReentrant {
        // Calculate unaccounted rewards (balance - escrow - accounted rewards)
        uint256 available = _availableUnaccountedRewards(token);
        if (available > 0) {
            _creditRewards(token, available);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    /// @dev Only token admin can whitelist. Underlying is always whitelisted (cannot be modified).
    ///      Whitelisted tokens exempt from reward token limits and can always accrue rewards.
    function whitelistToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();

        // CRITICAL: Cannot modify underlying token (always whitelisted, initialized separately)
        if (token == underlying) revert CannotModifyUnderlying();

        // Only token admin can whitelist (prevents spam)
        address tokenAdmin = IClankerToken(underlying).admin();
        if (_msgSender() != tokenAdmin) revert OnlyTokenAdmin();

        // Cannot whitelist already whitelisted token
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (tokenState.whitelisted) revert AlreadyWhitelisted();

        // If token exists, ensure no pending rewards (prevents state corruption)
        if (tokenState.exists) {
            if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
                revert CannotWhitelistWithPendingRewards();
            }
        }

        // Set whitelisted status
        tokenState.whitelisted = true;

        // Initialize token state if first time (new token registration)
        if (!tokenState.exists) {
            tokenState.exists = true;
            tokenState.availablePool = 0;
            tokenState.streamTotal = 0;
            tokenState.lastUpdate = 0;
            tokenState.streamStart = 0;
            tokenState.streamEnd = 0;
            _rewardTokens.push(token);

            // Reset accounting for clean start (fresh token OR re-added token after removal)
            // This prevents corruption when tokens are removed and re-whitelisted
            accRewardPerShare[token] = 0;
        }

        emit ILevrStaking_v1.TokenWhitelisted(token);
    }

    /// @inheritdoc ILevrStaking_v1
    function unwhitelistToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();

        // CRITICAL: CANNOT unwhitelist underlying token (permanent protection)
        if (token == underlying) revert CannotUnwhitelistUnderlying();

        // Only token admin can unwhitelist
        address tokenAdmin = IClankerToken(underlying).admin();
        if (_msgSender() != tokenAdmin) revert OnlyTokenAdmin();

        // Token must exist and be whitelisted
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) revert TokenNotRegistered();
        if (!tokenState.whitelisted) revert NotWhitelisted();

        // CRITICAL: Cannot unwhitelist if token has pending rewards (would make them unclaimable)
        if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
            revert CannotUnwhitelistWithPendingRewards();
        }

        // Settle the pool to ensure all rewards are accounted for before unwhitelisting
        _settlePoolForToken(token);

        // Verify again after settlement (in case streaming added to pool)
        if (!(tokenState.availablePool == 0 && tokenState.streamTotal == 0)) {
            revert CannotUnwhitelistWithPendingRewards();
        }

        // Remove from whitelist (token state kept for historical tracking)
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

    /// @notice Credit rewards to the pool with streaming
    /// @dev Minimum check prevents reward token DoS attack (0.001 tokens minimum)
    ///      Works with any token decimals (USDC, WBTC, DAI all supported)
    /// @param token The reward token address
    /// @param amount The amount to credit (in token's native units)
    function _creditRewards(address token, uint256 amount) internal {
        // Token-aware minimum: 0.001 tokens prevents DoS while supporting all decimals
        // Examples: USDC (6 decimals) min = 1000 units, DAI (18 decimals) min = 1e15 units
        uint8 tokenDecimals = _queryDecimals(token);
        uint256 minReward = (10 ** uint256(tokenDecimals)) / 1000;
        if (amount < minReward) revert RewardTooSmall();

        // Ensure token is registered and whitelisted
        RewardTokenState storage tokenState = _ensureRewardToken(token);

        // Settle pool to move vested rewards from stream to available pool
        _settlePoolForToken(token);

        // Add new rewards to stream, preserving unvested from previous stream
        // This extends the streaming window and includes both old unvested + new rewards
        _resetStreamForToken(token, amount + tokenState.streamTotal);

        emit RewardsAccrued(token, amount, tokenState.availablePool);
    }

    function _ensureRewardToken(
        address token
    ) internal view returns (ILevrStaking_v1.RewardTokenState storage tokenState) {
        tokenState = _tokenState[token];

        // Token MUST already exist (via initialize() or whitelistToken())
        if (!tokenState.exists) revert TokenNotWhitelisted();

        // Token MUST be whitelisted
        if (!tokenState.whitelisted) revert TokenNotWhitelisted();
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

    /// @notice Calculate unaccounted rewards for a token
    /// @dev Returns rewards in contract that aren't tracked in pool or streaming
    ///      For underlying token: excludes escrowed principal (user deposits)
    /// @param token The token to check
    /// @return Unaccounted reward amount (can be accrued)
    function _availableUnaccountedRewards(address token) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));

        // For underlying token: subtract escrowed principal (staker deposits)
        // Only excess balance counts as rewards
        if (token == underlying) {
            if (bal > _escrowBalance[underlying]) {
                bal -= _escrowBalance[underlying];
            } else {
                bal = 0; // No excess balance
            }
        }

        // Unaccounted = total balance - (available pool + streaming)
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        uint256 accounted = tokenState.availablePool + tokenState.streamTotal;
        return bal > accounted ? bal - accounted : 0;
    }

    /// @notice Get effective debt for user, auto-resetting stale debt
    /// @dev Detects stale debt from token removal/re-add by checking if debt > accRewardPerShare
    /// @param user The user to check debt for
    /// @param token The reward token
    /// @return effectiveDebt The debt to use in claim calculations (reset if stale)
    function _getEffectiveDebt(
        address user,
        address token
    ) internal returns (uint256 effectiveDebt) {
        uint256 debt = rewardDebt[user][token];
        uint256 accReward = accRewardPerShare[token];

        // Normal operation: debt <= accReward (user's debt tracks what they've accounted for)
        // Stale debt: debt > accReward (only happens after accRewardPerShare reset on token re-add)
        if (debt > accReward) {
            // Stale debt detected - reset to 0 to allow user to claim all rewards from re-whitelist point
            // Returning accReward would cause user to lose all accumulated rewards in current cycle
            rewardDebt[user][token] = 0;
            return 0;
        }

        return debt;
    }

    /// @notice Auto-claim all rewards for a user (used in unstake)
    /// @param claimer The user claiming rewards
    /// @param to The address to send rewards to
    function _claimAllRewards(address claimer, address to) internal {
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue;

            // Settle pool to latest (updates accRewardPerShare)
            _settlePoolForToken(token);

            // Get effective debt (auto-resets stale debt from token removal/re-add)
            uint256 effectiveDebt = _getEffectiveDebt(claimer, token);

            // Calculate pending rewards using debt accounting (prevents dilution attack)
            uint256 pending = RewardMath.calculatePendingRewards(
                userBalance,
                accRewardPerShare[token],
                effectiveDebt
            );

            if (pending > 0) {
                // Reduce pool
                tokenState.availablePool -= pending;

                // Update user's debt to current accumulated
                rewardDebt[claimer][token] = accRewardPerShare[token];

                // Transfer rewards
                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(claimer, to, token, pending);
            }
        }
    }

    /// @notice Settle all reward pools to current timestamp
    /// @dev Moves vested rewards from streaming into available pool for all tokens
    function _settleAllPools() internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _settlePoolForToken(_rewardTokens[i]);
        }
    }

    /// @notice Settle a single reward pool by vesting streamed rewards
    /// @dev Calculates vested amount from stream and moves to available pool
    ///      Pauses streaming when totalStaked = 0 (preserves rewards for future stakers)
    /// @param token The reward token to settle
    function _settlePoolForToken(address token) internal {
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

        // Use PER-TOKEN stream window (CRITICAL-3 fix: isolation)
        uint64 start = tokenState.streamStart;
        uint64 end = tokenState.streamEnd;
        if (end == 0 || start == 0) return;

        // Pause streaming if no stakers (preserves rewards for future stakers)
        // Updates lastUpdate so when stakers return, streaming resumes from current time
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

            // Update cumulative rewards per share (prevents dilution attack)
            // accRewardPerShare tracks total rewards per staked token (scaled by 1e18)
            accRewardPerShare[token] += (vestAmount * 1e18) / _totalStaked;
        }

        tokenState.lastUpdate = newLast;
    }

    // ============ Governance Functions ============

    /// @inheritdoc ILevrStaking_v1
    /// @dev Returns voting power in token-days (e.g., 1000 tokens × 100 days = 100,000 VP)
    ///      Normalizes all balances to 18 decimals for fair cross-token governance
    ///      Examples: 1000 USDC (6 decimals) = 1000 DAI (18 decimals) in voting power
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        uint256 startTime = stakeStartTime[user];
        if (startTime == 0) return 0; // Never staked or fully unstaked

        uint256 balance = ILevrStakedToken_v1(stakedToken).balanceOf(user);
        if (balance == 0) return 0;

        uint256 timeStaked = block.timestamp - startTime;

        // Normalize balance to 18 decimals for fair voting across different decimal tokens:
        // - 1000 USDC (6 decimals) → normalized to 1000e18
        // - 1000 DAI (18 decimals) → already 1000e18
        // Both result in same voting power for same time staked
        uint256 normalizedBalance = _normalizeBalance(balance);

        // Calculate voting power: (normalized_balance × time) / (1e18 × 86400)
        // Result is in token-days for UI-friendly numbers
        return (normalizedBalance * timeStaked) / (1e18 * SECONDS_PER_DAY);
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

    // ============ Internal Helper Functions (Decimal Normalization) ============

    /// @notice Query token decimals with validation and safe defaults
    /// @dev Ensures decimal-aware operations work correctly for all supported tokens
    ///      Bounds check prevents edge cases (must be 1-18 decimals)
    ///      Falls back to 18 decimals for non-standard tokens
    /// @param token The token address to query
    /// @return decimals The token decimals in range [1, 18]
    function _queryDecimals(address token) internal view returns (uint8 decimals) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            // Validate decimals are in reasonable range
            // Standard tokens: USDC (6), WBTC (8), DAI (18)
            // Support 1-18 decimals, reject 0 or >18 to prevent edge cases
            if (d == 0 || d > 18) revert InvalidTokenDecimals();
            return d;
        } catch {
            // Non-standard token or query failed: default to 18 (safest assumption)
            return 18;
        }
    }

    /// @notice Normalize balance to 18 decimals for fair voting power
    /// @dev Ensures equal voting power for equal token amounts regardless of decimal places
    ///
    ///      Math safety: No overflow possible because:
    ///      - decimals <= 18 (validated in _queryDecimals)
    ///      - scaleFactor <= 1e18
    ///      - balance * 1e18 fits in uint256 for realistic token amounts
    ///
    ///      Examples:
    ///      - 1000 USDC (6 decimals): 1000e6 × 1e12 = 1000e18 ✓
    ///      - 1 WBTC (8 decimals): 1e8 × 1e10 = 1e18 ✓
    ///      - 1000 DAI (18 decimals): 1000e18 × 1 = 1000e18 ✓
    ///
    /// @param balance The raw token balance (in token's native units)
    /// @return normalizedBalance The balance scaled to 18 decimals
    function _normalizeBalance(uint256 balance) internal view returns (uint256 normalizedBalance) {
        uint8 decimals = underlyingDecimals;

        // Fast path: 18-decimal tokens need no normalization (most common)
        if (decimals == TARGET_DECIMALS) {
            return balance;
        }

        // Scale up low-decimal tokens to 18 decimals
        // Example: USDC (6 decimals) → multiply by 1e12
        if (decimals < TARGET_DECIMALS) {
            uint256 scaleFactor = 10 ** (TARGET_DECIMALS - decimals);
            return balance * scaleFactor; // Safe: no overflow due to bounds check
        }

        // decimals > 18 impossible due to _queryDecimals bounds check
        // Defensive: return balance as-is if somehow encountered
        return balance;
    }
}
