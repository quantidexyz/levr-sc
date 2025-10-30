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
import {IClankerFeeLocker} from './interfaces/external/IClankerFeeLocker.sol';
import {IClankerLpLocker} from './interfaces/external/IClankerLpLocker.sol';
import {RewardMath} from './libraries/RewardMath.sol';

contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    // ============ Constants - LOW-3: Replace magic numbers ============
    /// @notice Precision scale for token decimals in voting power calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Seconds per day (86400 seconds)
    uint256 public constant SECONDS_PER_DAY = 86400;

    /// @notice Basis points for APR calculations (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Minimum reward amount to prevent DoS attack - MEDIUM-2 fix
    /// Prevents attackers from filling reward token slots with dust
    uint256 public constant MIN_REWARD_AMOUNT = 1e15; // 0.001 tokens (18 decimals)

    constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {}

    address public underlying;
    address public stakedToken;
    address public treasury; // for future integrations
    address public factory; // Levr factory instance

    // Global streaming state - shared by all reward tokens for gas efficiency
    uint64 private _streamStart;
    uint64 private _streamEnd;

    uint256 private _totalStaked;

    // Governance: track when each user started staking for time-weighted voting power
    mapping(address => uint256) public stakeStartTime;

    address[] private _rewardTokens;
    mapping(address => ILevrStaking_v1.RewardTokenState) private _tokenState;

    // POOL-BASED SYSTEM: Simple and clean - reduce pool on claim
    // Perfect accounting: Σ(claimable) = pool

    // Track escrowed principal per token to separate it from reward liquidity
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
            whitelisted: true
        });
        _rewardTokens.push(underlying_);
    }

    /// @inheritdoc ILevrStaking_v1
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        address staker = _msgSender();

        // Check if this is the first staker (totalStaked is currently 0)
        bool isFirstStaker = _totalStaked == 0;

        // Settle pools for all reward tokens before balance changes
        _settleAllPools();

        // If becoming first staker, restart stream with any paused/unvested rewards
        if (isFirstStaker) {
            uint256 len = _rewardTokens.length;
            for (uint256 i = 0; i < len; i++) {
                address rt = _rewardTokens[i];
                ILevrStaking_v1.RewardTokenState storage rtState = _tokenState[rt];

                // If there are unvested rewards (stream was paused), restart with them
                if (rtState.streamTotal > 0) {
                    // Restart stream with existing streamTotal (the paused/unvested amount)
                    _resetStreamForToken(rt, rtState.streamTotal);
                }

                // Also accrue any truly new unaccounted rewards
                uint256 available = _availableUnaccountedRewards(rt);
                if (available > 0) {
                    _creditRewards(rt, available);
                }
            }
        }

        // Governance: Calculate weighted average timestamp for voting power preservation
        stakeStartTime[staker] = _onStakeNewTimestamp(amount);

        IERC20(underlying).safeTransferFrom(staker, address(this), amount);
        _escrowBalance[underlying] += amount;
        _totalStaked += amount;
        ILevrStakedToken_v1(stakedToken).mint(staker, amount);

        // POOL-BASED: No debt tracking needed!
        // User's rewards automatically calculated: (balance / totalStaked) × pool

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
        uint256 bal = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        if (bal < amount) revert InsufficientStake();

        // OPTION A: Auto-claim all rewards before unstaking
        // This prevents accidental reward loss and simplifies accounting
        _claimAllRewards(staker, to);

        // Burn staked tokens and transfer underlying
        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        _totalStaked -= amount;
        uint256 esc = _escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow();
        _escrowBalance[underlying] = esc - amount;
        IERC20(underlying).safeTransfer(to, amount);

        // Governance: Proportionally reduce time on partial unstake, reset to 0 on full unstake
        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new voting power after unstake (for UI simulation)
        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 newStartTime = stakeStartTime[staker];
        if (remainingBalance > 0 && newStartTime > 0) {
            uint256 timeStaked = block.timestamp - newStartTime;
            newVotingPower = (remainingBalance * timeStaked) / (PRECISION * SECONDS_PER_DAY);
        } else {
            newVotingPower = 0;
        }

        // POOL-BASED: No debt tracking needed!
        // Rewards already claimed above

        emit Unstaked(staker, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function claimRewards(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address claimer = _msgSender();
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        if (userBalance == 0) return; // No balance = no rewards

        uint256 totalStaked = _totalStaked;
        if (totalStaked == 0) return; // Safety check

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
            if (!tokenState.exists) continue;

            // Settle pool to latest state
            _settlePoolForToken(token);

            // Calculate proportional share of available pool
            uint256 claimable = RewardMath.calculateProportionalClaim(
                userBalance,
                totalStaked,
                tokenState.availablePool
            );

            if (claimable > 0) {
                // Reduce pool (simple and clean)
                tokenState.availablePool -= claimable;

                // Transfer rewards
                IERC20(token).safeTransfer(to, claimable);
                emit RewardsClaimed(claimer, to, token, claimable);
            }
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function accrueRewards(address token) external nonReentrant {
        // Optionally collect from LP/Fee lockers first (convenience)
        // But accounting works the same whether we do this or not
        _claimFromClankerFeeLocker(token);

        // Core accounting: count what's in the contract and update reserve
        // Works regardless of how tokens arrived (LP claim, direct transfer, etc.)
        uint256 available = _availableUnaccountedRewards(token);
        if (available > 0) {
            _creditRewards(token, available);
        }
    }

    /// @notice Add a token to the whitelist (doesn't count toward MAX_REWARD_TOKENS)
    /// @dev Only callable by the clanker token admin
    ///      Whitelisted tokens are exempt from the MAX_REWARD_TOKENS limit
    ///      Useful for trusted tokens like WETH, USDC, etc.
    /// @param token The token to whitelist
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
        }

        emit ILevrStaking_v1.TokenWhitelisted(token);
    }

    /// @notice Clean up finished reward tokens to free up slots
    /// @dev Removes tokens whose streams have ended and all rewards claimed
    ///      Can only remove non-underlying tokens
    ///      Anyone can call to help maintain the system
    /// @param token The token to clean up
    function cleanupFinishedRewardToken(address token) external nonReentrant {
        // Cannot remove underlying token
        require(token != underlying, 'CANNOT_REMOVE_UNDERLYING');

        // Token must exist in the system
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        require(tokenState.exists, 'TOKEN_NOT_REGISTERED');

        // Stream must be finished (global stream ended and past end time)
        // Check if global stream has ended
        require(_streamEnd > 0 && block.timestamp >= _streamEnd, 'STREAM_NOT_FINISHED');

        // All rewards must be claimed (pool = 0 AND no streaming rewards left)
        require(
            tokenState.availablePool == 0 && tokenState.streamTotal == 0,
            'REWARDS_STILL_PENDING'
        );

        // Remove from _rewardTokens array
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            if (_rewardTokens[i] == token) {
                // Swap with last element and pop
                _rewardTokens[i] = _rewardTokens[_rewardTokens.length - 1];
                _rewardTokens.pop();
                break;
            }
        }

        // Mark as non-existent (clears all token state)
        delete _tokenState[token];

        emit ILevrStaking_v1.RewardTokenRemoved(token);
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
        uint256 userBalance = ILevrStakedToken_v1(stakedToken).balanceOf(account);
        if (userBalance == 0) return 0;

        uint256 totalStaked = _totalStaked;
        if (totalStaked == 0) return 0;

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) return 0;

        // Calculate current pool including vested rewards using library
        uint256 currentPool = RewardMath.calculateCurrentPool(
            tokenState.availablePool,
            tokenState.streamTotal,
            _streamStart,
            _streamEnd,
            tokenState.lastUpdate,
            uint64(block.timestamp)
        );

        // Calculate proportional claim (simple pool-based)
        claimable = RewardMath.calculateProportionalClaim(userBalance, totalStaked, currentPool);
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

    /// @notice Get all whitelisted tokens
    /// @return Array of whitelisted token addresses
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

    /// @notice Check if a token is whitelisted
    /// @param token The token address to check
    /// @return True if whitelisted, false otherwise
    function isTokenWhitelisted(address token) external view returns (bool) {
        return _tokenState[token].whitelisted;
    }

    /// @inheritdoc ILevrStaking_v1
    function rewardRatePerSecond(address token) external view returns (uint256) {
        // Use GLOBAL stream window
        uint64 start = _streamStart;
        uint64 end = _streamEnd;
        if (end == 0 || end <= start) return 0;
        if (block.timestamp >= end) return 0;
        uint256 window = end - start;
        uint256 total = _tokenState[token].streamTotal;
        return total / window;
    }

    /// @inheritdoc ILevrStaking_v1
    function aprBps() external view returns (uint256) {
        if (_totalStaked == 0) return 0;
        // Use GLOBAL stream window
        uint64 start = _streamStart;
        uint64 end = _streamEnd;
        if (end == 0 || end <= start) return 0;
        if (block.timestamp >= end) return 0;
        uint256 window = end - start;
        uint256 total = _tokenState[underlying].streamTotal;
        if (total == 0) return 0;
        uint256 rate = total / window;
        uint256 annual = rate * 365 days;
        return (annual * BASIS_POINTS) / _totalStaked;
    }

    function _resetStreamForToken(address token, uint256 amount) internal {
        // Query stream window from factory config
        uint32 window = ILevrFactory_v1(factory).streamWindowSeconds();

        // Reset GLOBAL stream window (shared by all tokens)
        _streamStart = uint64(block.timestamp);
        _streamEnd = uint64(block.timestamp + window);
        emit StreamReset(window, _streamStart, _streamEnd);

        // Set per-token amount and last update
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        tokenState.streamTotal = amount;
        tokenState.lastUpdate = uint64(block.timestamp);
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
    /// @dev This is a convenience function - accounting works the same with or without it
    ///      Tokens can arrive via direct transfer, and accrueRewards will handle them
    function _claimFromClankerFeeLocker(address token) internal {
        if (factory == address(0)) return;

        // Get clanker metadata from our factory
        // Wrapped in try/catch to handle cases where Clanker factory doesn't exist (e.g., unit tests)
        ILevrFactory_v1.ClankerMetadata memory metadata;
        try ILevrFactory_v1(factory).getClankerMetadata(underlying) returns (
            ILevrFactory_v1.ClankerMetadata memory _metadata
        ) {
            metadata = _metadata;
        } catch {
            // Clanker factory not available or errored - skip claiming
            return;
        }
        if (!metadata.exists) return;

        // CRITICAL-2: Store balance before external calls for verification
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // First, collect rewards from LP locker to ensure ClankerFeeLocker has latest fees
        if (metadata.lpLocker != address(0)) {
            try IClankerLpLocker(metadata.lpLocker).collectRewards(underlying) {
                // Successfully collected from LP locker
            } catch (bytes memory reason) {
                // HIGH-2: Emit event on failure instead of silently failing
                emit ClaimFailed(metadata.lpLocker, token, string(reason));
            }
        }

        // Claim from ClankerFeeLocker if available
        if (metadata.feeLocker != address(0)) {
            try IClankerFeeLocker(metadata.feeLocker).availableFees(address(this), token) returns (
                uint256 availableFees
            ) {
                if (availableFees > 0) {
                    try IClankerFeeLocker(metadata.feeLocker).claim(address(this), token) {
                        // Successfully claimed
                    } catch (bytes memory reason) {
                        // HIGH-2: Emit event on failure
                        emit ClaimFailed(metadata.feeLocker, token, string(reason));
                    }
                }
            } catch {
                // Fee locker might not have this token or staking not set as fee owner
            }
        }

        // CRITICAL-2: Verify balance didn't decrease unexpectedly
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, 'BALANCE_MISMATCH');
    }

    function _creditRewards(address token, uint256 amount) internal {
        // MEDIUM-2: Prevent DoS attack by rejecting dust amounts
        require(amount >= MIN_REWARD_AMOUNT, 'REWARD_TOO_SMALL');

        RewardTokenState storage tokenState = _ensureRewardToken(token);

        // Settle to move all vested rewards to pool
        _settlePoolForToken(token);

        // IMPORTANT: `amount` from _availableUnaccountedRewards already excludes unvested
        // So it represents only the TRUE new rewards to add to the stream
        // The unvested portion remains in streamTotal after settlement above

        // Reset stream with NEW rewards + remaining unvested (in streamTotal after settlement)
        _resetStreamForToken(token, amount + tokenState.streamTotal);

        emit RewardsAccrued(token, amount, tokenState.availablePool);
    }

    function _ensureRewardToken(
        address token
    ) internal returns (ILevrStaking_v1.RewardTokenState storage tokenState) {
        tokenState = _tokenState[token];
        if (!tokenState.exists) {
            // FIX [TOKEN-AGNOSTIC-DOS]: Check max tokens limit (excluding whitelisted tokens)
            // Whitelisted tokens (including underlying at index 0) are exempt from the limit
            bool wasWhitelisted = tokenState.whitelisted; // Preserve whitelist status if set
            if (!wasWhitelisted) {
                // Read maxRewardTokens from factory config
                uint16 maxRewardTokens = ILevrFactory_v1(factory).maxRewardTokens();

                // Count non-whitelisted reward tokens
                uint256 nonWhitelistedCount = 0;
                for (uint256 i = 0; i < _rewardTokens.length; i++) {
                    if (!_tokenState[_rewardTokens[i]].whitelisted) {
                        nonWhitelistedCount++;
                    }
                }
                require(nonWhitelistedCount < maxRewardTokens, 'MAX_REWARD_TOKENS_REACHED');
            }

            // Initialize token state (create new struct)
            _tokenState[token] = ILevrStaking_v1.RewardTokenState({
                availablePool: 0,
                streamTotal: 0,
                lastUpdate: 0,
                exists: true,
                whitelisted: wasWhitelisted
            });
            tokenState = _tokenState[token];
            _rewardTokens.push(token);
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
        // In pool-based system: accounted = availablePool + streamTotal
        // streamTotal represents rewards that will vest (whether vested or not, they're accounted)
        // availablePool represents rewards already vested and claimable
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

        uint256 totalStaked = _totalStaked;
        if (totalStaked == 0) return;

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
                totalStaked,
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

    /// @notice Settle a single reward pool by adding vested rewards
    /// @param token The reward token to settle
    function _settlePoolForToken(address token) internal {
        // Use GLOBAL stream window (shared by all tokens)
        uint64 start = _streamStart;
        uint64 end = _streamEnd;
        if (end == 0 || start == 0) return;

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

        // Don't vest if no stakers (preserves rewards for when stakers return)
        // BUT update lastUpdate to mark the pause point for accurate unvested calculation
        if (_totalStaked == 0) {
            // Mark where we paused so unvested calculations know the stream stopped here
            tokenState.lastUpdate = uint64(block.timestamp);
            return;
        }
        uint64 last = tokenState.lastUpdate;
        uint64 current = uint64(block.timestamp);

        // Determine how far to vest
        uint64 settleTo;
        if (current > end) {
            // Stream ended
            if (last >= end) {
                // Already fully settled
                return;
            }
            settleTo = end;
        } else {
            // Stream active
            settleTo = current;
        }

        // Calculate vested amount using library
        (uint256 vestAmount, uint64 newLast) = RewardMath.calculateVestedAmount(
            tokenState.streamTotal,
            start,
            end,
            last,
            settleTo
        );

        if (vestAmount > 0) {
            // Add vested to available pool
            tokenState.availablePool += vestAmount;
            // Reduce streamTotal by vested amount to maintain accurate accounting
            tokenState.streamTotal -= vestAmount;
        }

        // Update last settlement time
        tokenState.lastUpdate = newLast;
    }

    // ============ Governance Functions ============

    /// @inheritdoc ILevrStaking_v1
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        uint256 startTime = stakeStartTime[user];
        if (startTime == 0) return 0; // User never staked or has unstaked

        uint256 balance = ILevrStakedToken_v1(stakedToken).balanceOf(user);
        if (balance == 0) return 0; // No staked balance

        uint256 timeStaked = block.timestamp - startTime;

        // Normalize to token-days: divide by 1e18 (token decimals) and 86400 (seconds per day)
        // This makes VP human-readable: 1000 tokens × 100 days = 100,000 token-days
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
