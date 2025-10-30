// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
    mapping(address => mapping(address => ILevrStaking_v1.UserRewardState)) private _userRewards;

    uint256 private constant ACC_SCALE = 1e18;

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

        // Initialize underlying token in consolidated state
        _tokenState[underlying_] = ILevrStaking_v1.RewardTokenState({
            accPerShare: 0,
            reserve: 0,
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

        // Settle streaming for all reward tokens before balance changes
        _settleStreamingAll();

        // FIX: If becoming first staker, reset stream for all tokens with available rewards
        // This prevents giving rewards for the period when no one was staked
        if (isFirstStaker) {
            uint256 len = _rewardTokens.length;
            for (uint256 i = 0; i < len; i++) {
                address rt = _rewardTokens[i];
                uint256 available = _availableUnaccountedRewards(rt);
                if (available > 0) {
                    // Reset stream with available rewards, starting from NOW
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

        // CRITICAL FIX: Keep pending rewards separate when restaking
        // Pending rewards are claimable independently of balance-based rewards
        // No conversion needed - user can claim both pending (from unstake) and new rewards

        // Increase debt to match new accumulated amount, preventing instant rewards
        // pending = (balance * accPerShare) - debt, so increasing both keeps pending same
        _increaseDebtForAll(staker, amount);

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

        // Settle streaming before changing balances
        _settleStreamingAll();

        // NEW DESIGN: Don't auto-claim rewards on unstake
        // Rewards stay tracked, user can claim manually anytime
        // This prevents the "unvested rewards to new staker" bug

        ILevrStakedToken_v1(stakedToken).burn(staker, amount);
        _totalStaked -= amount;
        uint256 esc = _escrowBalance[underlying];
        if (esc < amount) revert InsufficientEscrow();
        _escrowBalance[underlying] = esc - amount;
        IERC20(underlying).safeTransfer(to, amount);

        // Governance: Proportionally reduce time on partial unstake, reset to 0 on full unstake
        stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

        // Calculate new voting power after unstake (for UI simulation)
        // Normalized to token-days for UI-friendly numbers
        uint256 remainingBalance = ILevrStakedToken_v1(stakedToken).balanceOf(staker);
        uint256 newStartTime = stakeStartTime[staker];
        if (remainingBalance > 0 && newStartTime > 0) {
            uint256 timeStaked = block.timestamp - newStartTime;
            newVotingPower = (remainingBalance * timeStaked) / (1e18 * 86400);
        } else {
            newVotingPower = 0;
        }

        // CRITICAL FIX: Calculate and preserve pending rewards before resetting debt
        // This prevents permanent fund loss when users unstake
        uint256 oldBalance = bal; // Balance before unstake
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[rt];
            if (tokenState.exists && oldBalance > 0) {
                // Calculate accumulated rewards using library
                uint256 accumulated = RewardMath.calculateAccumulated(
                    oldBalance,
                    tokenState.accPerShare
                );
                ILevrStaking_v1.UserRewardState storage userState = _userRewards[staker][rt];
                int256 currentDebt = userState.debt;

                // Calculate pending rewards earned before unstaking
                if (accumulated > uint256(currentDebt)) {
                    uint256 pending = accumulated - uint256(currentDebt);
                    // Add to existing pending rewards (in case of multiple unstakes)
                    userState.pending += pending;
                }
            }
        }

        // Update debt to freeze rewards at current level (stop accumulating while unstaked)
        _updateDebtAll(staker, remainingBalance);

        emit Unstaked(staker, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function claimRewards(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address claimer = _msgSender();
        uint256 bal = ILevrStakedToken_v1(stakedToken).balanceOf(claimer);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            _settleStreamingForToken(token);

            // Claim from balance-based rewards if user has balance
            if (bal > 0) {
                _settle(token, claimer, to, bal);
                ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
                ILevrStaking_v1.UserRewardState storage userState = _userRewards[claimer][token];
                // Update debt to current accumulated amount using library
                uint256 accumulated = RewardMath.calculateAccumulated(bal, tokenState.accPerShare);
                userState.debt = int256(accumulated);
            }

            // Claim from pending rewards (for users who unstaked)
            ILevrStaking_v1.UserRewardState storage userState2 = _userRewards[claimer][token];
            uint256 pending = userState2.pending;
            if (pending > 0) {
                ILevrStaking_v1.RewardTokenState storage tokenState2 = _tokenState[token];
                if (tokenState2.reserve < pending) revert InsufficientRewardLiquidity();
                tokenState2.reserve -= pending;
                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(claimer, to, token, pending);
                // Clear pending rewards after claiming
                userState2.pending = 0;
            }
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
            tokenState.accPerShare = 0;
            tokenState.reserve = 0;
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

        // All rewards must be claimed (reserve = 0)
        require(tokenState.reserve == 0, 'REWARDS_STILL_PENDING');

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
        uint256 bal = ILevrStakedToken_v1(stakedToken).balanceOf(account);

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        ILevrStaking_v1.UserRewardState storage userState = _userRewards[account][token];

        if (!tokenState.exists) {
            // If token doesn't exist, return only pending rewards
            return userState.pending;
        }

        // If user has balance, calculate balance-based rewards
        if (bal > 0) {
            // Calculate what would be accumulated after settling streaming
            uint256 accPerShare = tokenState.accPerShare;

            // Add any pending streaming rewards using GLOBAL stream window
            uint64 start = _streamStart;
            uint64 end = _streamEnd;
            if (end > 0 && start > 0 && _totalStaked > 0) {
                uint64 last = tokenState.lastUpdate;
                uint64 current = uint64(block.timestamp);

                // Determine how far to vest for view calculation (matches _settleStreamingForToken logic)
                uint64 settleTo;
                if (current > end) {
                    // Stream ended
                    if (last >= end) {
                        // Already fully settled - use accPerShare as-is
                        settleTo = last;
                    } else {
                        // Stream ended but wasn't fully settled - vest up to end
                        settleTo = end;
                    }
                } else {
                    // Stream is still active - vest up to current time
                    settleTo = current;
                }

                if (settleTo > last) {
                    // Calculate pending rewards
                    (uint256 vestAmount, ) = RewardMath.calculateVestedAmount(
                        tokenState.streamTotal,
                        start,
                        end,
                        last,
                        settleTo
                    );
                    if (vestAmount > 0) {
                        accPerShare = RewardMath.calculateAccPerShare(
                            accPerShare,
                            vestAmount,
                            _totalStaked
                        );
                    }
                }
            }

            // Calculate accumulated and claimable using library functions
            uint256 accumulated = RewardMath.calculateAccumulated(bal, accPerShare);
            claimable = RewardMath.calculateClaimable(
                accumulated,
                userState.debt,
                userState.pending
            );
        } else {
            // If bal == 0, return only pending rewards
            claimable = userState.pending;
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
        return (annual * 10_000) / _totalStaked;
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
        RewardTokenState storage tokenState = _ensureRewardToken(token);
        // Settle current stream up to now before resetting
        _settleStreamingForToken(token);

        // FIX: Calculate unvested rewards from current stream
        uint256 unvested = _calculateUnvested(token);

        // Reset stream with NEW amount + UNVESTED from previous stream
        _resetStreamForToken(token, amount + unvested);

        // Increase reserve by newly provided amount only
        // (unvested is already in reserve from previous accrual)
        tokenState.reserve += amount;
        emit RewardsAccrued(token, amount, tokenState.accPerShare);
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
                accPerShare: 0,
                reserve: 0,
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
        uint256 accounted = _tokenState[token].reserve;
        return bal > accounted ? bal - accounted : 0;
    }

    function _increaseDebtForAll(address account, uint256 amount) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[rt];
            if (tokenState.accPerShare > 0) {
                // Calculate accumulated for new amount using library
                uint256 accumulated = RewardMath.calculateAccumulated(
                    amount,
                    tokenState.accPerShare
                );
                _userRewards[account][rt].debt += int256(accumulated);
            }
        }
    }

    function _updateDebtAll(address account, uint256 newBal) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[rt];
            // Calculate accumulated for new balance using library
            uint256 accumulated = RewardMath.calculateAccumulated(newBal, tokenState.accPerShare);
            _userRewards[account][rt].debt = int256(accumulated);
        }
    }

    function _settle(address token, address account, address to, uint256 bal) internal {
        _settleStreamingForToken(token);
        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        if (!tokenState.exists) return;

        // Calculate accumulated rewards using library
        uint256 accumulated = RewardMath.calculateAccumulated(bal, tokenState.accPerShare);
        ILevrStaking_v1.UserRewardState storage userState = _userRewards[account][token];

        // Calculate claimable (balance-based only, pending handled separately in claimRewards)
        uint256 balanceBasedClaimable = RewardMath.calculateClaimable(
            accumulated,
            userState.debt,
            0 // pending handled separately
        );

        if (balanceBasedClaimable > 0) {
            if (tokenState.reserve < balanceBasedClaimable) revert InsufficientRewardLiquidity();
            tokenState.reserve -= balanceBasedClaimable;
            IERC20(token).safeTransfer(to, balanceBasedClaimable);
            emit RewardsClaimed(account, to, token, balanceBasedClaimable);
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
        // Use GLOBAL stream window (shared by all tokens)
        uint64 start = _streamStart;
        uint64 end = _streamEnd;
        if (end == 0 || start == 0) return;

        // Don't consume stream time if no stakers to preserve rewards
        if (_totalStaked == 0) return;

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
        uint64 last = tokenState.lastUpdate;
        uint64 current = uint64(block.timestamp);

        // Determine how far to vest
        uint64 settleTo;
        if (current > end) {
            // Stream ended
            if (last >= end) {
                // Already fully settled - nothing to do
                return;
            }
            // Stream ended but wasn't fully settled - vest up to end
            settleTo = end;
        } else {
            // Stream is still active - vest up to current time
            settleTo = current;
        }

        // Use library function for vesting calculation
        (uint256 vestAmount, uint64 newLast) = RewardMath.calculateVestedAmount(
            tokenState.streamTotal,
            start,
            end,
            last,
            settleTo
        );

        if (vestAmount > 0) {
            tokenState.accPerShare = RewardMath.calculateAccPerShare(
                tokenState.accPerShare,
                vestAmount,
                _totalStaked
            );
        }
        // Advance last update to reflect settlement
        tokenState.lastUpdate = newLast;
    }

    /// @notice Calculate unvested rewards from current stream
    /// @dev Returns the amount of rewards that haven't been distributed yet
    /// @param token The reward token to check
    /// @return unvested Amount of unvested rewards (0 if stream is complete or doesn't exist)
    function _calculateUnvested(address token) internal view returns (uint256 unvested) {
        // Use GLOBAL stream window (shared by all tokens)
        uint64 start = _streamStart;
        uint64 end = _streamEnd;

        ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

        // Use library function for unvested calculation
        return
            RewardMath.calculateUnvested(
                tokenState.streamTotal,
                start,
                end,
                tokenState.lastUpdate,
                uint64(block.timestamp)
            );
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
        return (balance * timeStaked) / (1e18 * 86400);
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
