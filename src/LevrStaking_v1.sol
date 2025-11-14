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
/// @dev - Staking: Direct underlying token deposits
///      - Rewards: Pool-based distribution with streaming
///      - Voting: Normalized to 18 decimals for fair governance
contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @inheritdoc ILevrStaking_v1
    uint256 public constant PRECISION = 1e18;

    /// @inheritdoc ILevrStaking_v1
    uint256 public constant SECONDS_PER_DAY = 86400;

    /// @inheritdoc ILevrStaking_v1
    uint256 public constant BASIS_POINTS = 10_000;

    /// @inheritdoc ILevrStaking_v1
    uint256 public constant MIN_REWARD_AMOUNT = 1e4;

    constructor(address trustedForwarder, address factory_) ERC2771ContextBase(trustedForwarder) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @inheritdoc ILevrStaking_v1
    address public immutable factory;

    /// @inheritdoc ILevrStaking_v1
    address public underlying;

    /// @inheritdoc ILevrStaking_v1
    address public stakedToken;

    /// @inheritdoc ILevrStaking_v1
    address public treasury;

    /// @inheritdoc ILevrStaking_v1
    uint256 public totalStaked;

    /// @inheritdoc ILevrStaking_v1
    mapping(address => uint256) public stakeStartTime;

    /// @inheritdoc ILevrStaking_v1
    mapping(address => uint256) public lastStakeBlock;

    /// @notice Array of all registered reward tokens
    /// @dev Underlying is always first, whitelisted tokens added during init/whitelist
    address[] private _rewardTokens;

    /// @notice State tracking for each reward token
    /// @dev Maps token address to pool state (balance, streaming, whitelist status)
    mapping(address => ILevrStaking_v1.RewardTokenState) private _tokenState;

    /// @inheritdoc ILevrStaking_v1
    mapping(address => uint256) public escrowBalance;

    // Reward accounting: prevents dilution attack (MasterChef pattern)
    // Tracks cumulative rewards per staked token (scaled by PRECISION, never decreases)
    mapping(address => uint256) public accRewardPerShare;
    // Tracks user's reward debt per token (what they've already accounted for)
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /// @inheritdoc ILevrStaking_v1
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

        // Initialize underlying token with pool-based state (ALWAYS whitelisted - separate from array)
        _initRewardToken(underlying_, true);

        // Initialize additional whitelisted tokens from factory config (e.g., WETH)
        for (uint256 i = 0; i < initialWhitelistedTokens.length; i++) {
            address token = initialWhitelistedTokens[i];

            // Factory ensures: token is not underlying and token is not zero address and no duplicates
            if (token == address(0) || token == underlying_ || _tokenState[token].exists) continue;

            // Initialize whitelisted token
            _initRewardToken(token, true);
        }

        emit Initialized(underlying_, stakedToken_, treasury_);
    }

    /// @inheritdoc ILevrStaking_v1
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        address staker = _msgSender();

        bool isFirstStaker = totalStaked == 0;

        // Settle all reward pools to latest state
        _settleAllPools();

        // Auto-claim existing rewards before staking more (prevents self-dilution)
        uint256 existingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (existingBalance > 0) {
            _claimAllRewards(staker, staker);
        }

        // Declare len once for reuse in both loops
        uint256 len = _rewardTokens.length;

        // First staker: restart paused streams
        if (isFirstStaker) {
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

        // Track last stake block (MEV protection - only stake inflates balance)
        lastStakeBlock[staker] = block.number;

        // Update accounting: escrow, total staked, mint receipt token
        escrowBalance[underlying] += actualReceived;
        totalStaked += actualReceived;
        ILevrStakedToken_v1(stakedToken).mint(staker, actualReceived);

        // Update reward debt for all tokens (prevents dilution on future claims)
        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens[i];
            rewardDebt[staker][token] = accRewardPerShare[token];
        }

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

        // Auto-claim all rewards to prevent user accidentally losing unclaimed rewards
        _claimAllRewards(staker, to);

        // Burn receipt token and update accounting
        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        totalStaked -= amount;
        uint256 esc = escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow(); // Safety check
        escrowBalance[underlying] = esc - amount;

        // Transfer underlying back to recipient
        IERC20(underlying).safeTransfer(to, amount);

        // Update voting power (proportional time reduction on partial unstake)
        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new voting power for return value (UI can display impact)
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

        for (uint256 i = 0; i < tokens.length; i++) {
            _claimRewards(claimer, to, tokens[i], userBalance);
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function accrueRewards(address token) external nonReentrant {
        // Calculate unaccounted rewards (balance - escrow - accounted rewards)
        uint256 available = _availableUnaccountedRewards(token);
        if (available > 0) {
            _creditRewards(token, available);
        }
    }

    /// @inheritdoc ILevrStaking_v1
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
            tokenState.originalStreamTotal = 0;
            tokenState.totalVested = 0;
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
        if (!tokenState.whitelisted) revert TokenNotWhitelisted();

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
            revert RewardsStillPending();
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

        uint256 cachedTotalStaked = totalStaked;
        if (cachedTotalStaked == 0) return 0;

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) return 0;

        // Calculate what accRewardPerShare would be if we settled now
        uint256 currentAccRewardPerShare = accRewardPerShare[token];

        // Calculate pending vested rewards
        uint256 newlyVested = RewardMath.calculateTimeBasedVesting(
            tokenState.originalStreamTotal,
            tokenState.totalVested,
            tokenState.streamStart,
            tokenState.streamEnd,
            uint64(block.timestamp)
        );

        if (newlyVested > 0 && cachedTotalStaked > 0) {
            currentAccRewardPerShare += (newlyVested * PRECISION) / cachedTotalStaked;
        }

        // Calculate pending using debt accounting (prevents dilution attack)
        claimable = RewardMath.calculatePendingRewards(
            userBalance,
            currentAccRewardPerShare,
            rewardDebt[account][token],
            PRECISION
        );
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

        // Use per-token stream window for isolation
        uint64 start = tokenState.streamStart;
        uint64 end = tokenState.streamEnd;
        if (end == 0 || end <= start) return 0;
        if (block.timestamp >= end) return 0;
        uint256 window = end - start;
        return tokenState.streamTotal / window;
    }

    /// @inheritdoc ILevrStaking_v1
    function aprBps() external view returns (uint256) {
        if (totalStaked == 0) return 0;

        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);
        if (window == 0) return 0;

        // Aggregate APR from all active reward streams
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
        return (totalAnnualRate * BASIS_POINTS) / totalStaked;
    }

    function _resetStreamForToken(address token, uint256 amount) internal {
        // Query stream window from factory config
        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);

        // Set per-token stream window
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        tokenState.streamStart = uint64(block.timestamp);
        tokenState.streamEnd = uint64(block.timestamp + window);
        tokenState.streamTotal = amount;
        tokenState.lastUpdate = uint64(block.timestamp);

        // Initialize time-based vesting tracking
        tokenState.originalStreamTotal = amount;
        tokenState.totalVested = 0;

        emit StreamReset(token, window, tokenState.streamStart, tokenState.streamEnd);
    }

    /// @notice Credit rewards to the pool with streaming
    /// @dev Minimum check (0.01 tokens) is enforced in _ensureRewardToken()
    /// @param token The reward token address
    /// @param amount The amount to credit (in token's native units)
    function _creditRewards(address token, uint256 amount) internal {
        // Ensure token is registered, whitelisted, and amount meets minimum
        RewardTokenState storage tokenState = _ensureRewardToken(token, amount);

        // Settle pool to move vested rewards from stream to available pool
        _settlePoolForToken(token);

        // Add new rewards to stream, preserving unvested from previous stream
        // This extends the streaming window and includes both old unvested + new rewards
        _resetStreamForToken(token, amount + tokenState.streamTotal);

        emit RewardsAccrued(token, amount, tokenState.availablePool);
    }

    /// @notice Validates reward token and minimum amount to prevent duration dilution attack
    /// @dev Requires minimum 10,000 wei to make repeated attacks impractical while allowing all tokens
    /// @param token The reward token address
    /// @param amount The amount being credited (in token's native units)
    /// @return tokenState Storage pointer to token state
    function _ensureRewardToken(
        address token,
        uint256 amount
    ) internal view returns (ILevrStaking_v1.RewardTokenState storage tokenState) {
        tokenState = _tokenState[token];

        // Token MUST exist and be whitelisted
        if (!tokenState.exists || !tokenState.whitelisted) revert TokenNotWhitelisted();

        // Prevent duration dilution attack: require minimum amount
        // Examples: 18 dec = 0.00001 tokens, 6 dec (USDC) = 0.01 cents, 8 dec (WBTC) = 0.0001 WBTC ($6)
        if (amount < MIN_REWARD_AMOUNT) revert RewardTooSmall();
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

    /// @notice Shared initializer for reward token state
    /// @param token Token address
    /// @param whitelisted Whether token starts whitelisted
    function _initRewardToken(address token, bool whitelisted) internal {
        _tokenState[token] = ILevrStaking_v1.RewardTokenState({
            availablePool: 0,
            streamTotal: 0,
            lastUpdate: 0,
            exists: true,
            whitelisted: whitelisted,
            streamStart: 0,
            streamEnd: 0,
            originalStreamTotal: 0,
            totalVested: 0
        });
        _rewardTokens.push(token);
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
            if (bal > escrowBalance[underlying]) {
                bal -= escrowBalance[underlying];
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

    /// @notice Internal claim logic for a single token
    /// @param claimer The user claiming rewards
    /// @param to The address to send rewards to
    /// @param token The reward token to claim
    /// @param userBalance The user's staked balance (passed to avoid redundant SLOAD)
    function _claimRewards(
        address claimer,
        address to,
        address token,
        uint256 userBalance
    ) internal {
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) return;

        // Settle pool to latest (updates accRewardPerShare)
        _settlePoolForToken(token);

        // Get effective debt (auto-resets stale debt from token removal/re-add)
        uint256 effectiveDebt = _getEffectiveDebt(claimer, token);

        // Calculate pending rewards using debt accounting (prevents dilution attack)
        uint256 pending = RewardMath.calculatePendingRewards(
            userBalance,
            accRewardPerShare[token],
            effectiveDebt,
            PRECISION
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

    /// @notice Auto-claim all rewards for a user (used in unstake)
    /// @param claimer The user claiming rewards
    /// @param to The address to send rewards to
    function _claimAllRewards(address claimer, address to) internal {
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return;

        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _claimRewards(claimer, to, _rewardTokens[i], userBalance);
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

        // Use per-token stream window for isolation
        uint64 start = tokenState.streamStart;
        uint64 end = tokenState.streamEnd;
        if (end == 0 || start == 0) return;

        // Pause streaming if no stakers (preserves rewards for future stakers)
        // Updates lastUpdate so when stakers return, streaming resumes from current time
        if (totalStaked == 0) {
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

        // Calculate vesting based on time elapsed from stream start
        uint256 newlyVested = RewardMath.calculateTimeBasedVesting(
            tokenState.originalStreamTotal,
            tokenState.totalVested,
            start,
            end,
            settleTo
        );

        if (newlyVested > 0) {
            tokenState.totalVested += newlyVested;
            tokenState.availablePool += newlyVested;
            tokenState.streamTotal -= newlyVested;

            // Update cumulative rewards per share (prevents dilution attack)
            accRewardPerShare[token] += (newlyVested * PRECISION) / totalStaked;
        }

        tokenState.lastUpdate = settleTo;
    }

    // ============ Governance Functions ============

    /// @inheritdoc ILevrStaking_v1
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        uint256 startTime = stakeStartTime[user];
        if (startTime == 0) return 0; // Never staked or fully unstaked

        uint256 balance = ILevrStakedToken_v1(stakedToken).balanceOf(user);
        if (balance == 0) return 0;

        uint256 timeStaked = block.timestamp - startTime;

        // VP = balance × time / (PRECISION × SECONDS_PER_DAY) → token-days
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
