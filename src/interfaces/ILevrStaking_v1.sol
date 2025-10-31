// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Levr Staking v1 Interface
/// @notice Stakes underlying directly; mints staked ERC20; accrues multi-token rewards.
interface ILevrStaking_v1 {
    // ============ Constants ============

    /// @notice Precision scale for token decimals in voting power calculations
    function PRECISION() external view returns (uint256);

    /// @notice Seconds per day (86400 seconds)
    function SECONDS_PER_DAY() external view returns (uint256);

    /// @notice Basis points for APR calculations (10000 = 100%)
    function BASIS_POINTS() external view returns (uint256);

    /// @notice Minimum reward amount to prevent DoS attack
    function MIN_REWARD_AMOUNT() external view returns (uint256);

    // ============ Structs ============

    /// @notice Pool-based token state - simple and efficient
    /// @param availablePool Current claimable pool (grows as rewards vest)
    /// @param streamTotal Total amount to vest in current stream
    /// @param lastUpdate Last streaming settlement timestamp
    /// @param exists Whether token is registered
    /// @param whitelisted Whether token is whitelisted (exempt from MAX_REWARD_TOKENS)
    struct RewardTokenState {
        uint256 availablePool;
        uint256 streamTotal;
        uint64 lastUpdate;
        bool exists;
        bool whitelisted;
        uint64 streamStart; // Per-token stream start (isolation fix for CRITICAL-3)
        uint64 streamEnd; // Per-token stream end (isolation fix for CRITICAL-3)
    }

    // ============ Errors ============

    error ZeroAddress();
    error InvalidAmount();
    error InsufficientStake();
    error InsufficientRewardLiquidity();
    error InsufficientEscrow();
    error AlreadyInitialized();
    error OnlyFactory();

    // ============ Events ============

    /// @notice Emitted when a user stakes underlying.
    event Staked(address indexed staker, uint256 amount);

    /// @notice Emitted when a user unstakes underlying.
    event Unstaked(address indexed staker, address indexed to, uint256 amount);

    /// @notice Emitted when rewards accrue for a token.
    event RewardsAccrued(address indexed token, uint256 amount, uint256 newPoolTotal);

    /// @notice Emitted when streaming window resets due to new accruals.
    event StreamReset(
        address indexed token,
        uint32 windowSeconds,
        uint64 streamStart,
        uint64 streamEnd
    );

    /// @notice Emitted when rewards claimed.
    event RewardsClaimed(
        address indexed account,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a finished reward token is removed from the system
    event RewardTokenRemoved(address indexed token);

    /// @notice Emitted when a token is added to the whitelist
    event TokenWhitelisted(address indexed token);

    // ============ State Variables ============

    /// @notice The underlying token being staked
    function underlying() external view returns (address);

    /// @notice The staked token (receipt token)
    function stakedToken() external view returns (address);

    /// @notice The treasury address
    function treasury() external view returns (address);

    /// @notice The Levr factory instance
    function factory() external view returns (address);

    // ============ Functions ============

    /// @notice Initialize staking module.
    /// @param underlying The underlying token to stake
    /// @param stakedToken The staked token to mint/burn
    /// @param treasury The treasury address
    /// @param factory The Levr factory instance
    function initialize(
        address underlying,
        address stakedToken,
        address treasury,
        address factory
    ) external;

    /// @notice Stake underlying; mints staked token to msg.sender.
    function stake(uint256 amount) external;

    /// @notice Unstake; burns staked token and returns underlying to `to`.
    /// @param amount Amount to unstake
    /// @param to Address to receive the unstaked tokens
    /// @return newVotingPower The user's voting power after unstaking (useful for UI simulation)
    function unstake(uint256 amount, address to) external returns (uint256 newVotingPower);

    /// @notice Claim rewards for tokens to `to`.
    function claimRewards(address[] calldata tokens, address to) external;

    /// @notice Accrue rewards for token
    /// @dev Fee collection handled externally via SDK
    /// @param token Reward token to accrue
    function accrueRewards(address token) external;

    /// @notice Accrue rewards from treasury, optionally pulling tokens from treasury first.
    /// @param token Reward token
    /// @param amount Amount to accrue
    /// @param pullFromTreasury If true, transfer `amount` from treasury before accrual
    function accrueFromTreasury(address token, uint256 amount, bool pullFromTreasury) external;

    /// @notice Get outstanding rewards for a token - available rewards in the contract balance
    /// @param token The reward token to check
    /// @return available Rewards available in the contract balance (unaccounted)
    function outstandingRewards(address token) external view returns (uint256 available);

    /// @notice Get claimable rewards for a specific user and token
    /// @param account The user to check rewards for
    /// @param token The reward token to check
    /// @return claimable The amount of rewards the user can claim right now
    function claimableRewards(
        address account,
        address token
    ) external view returns (uint256 claimable);

    /// @notice View streaming parameters.
    function streamWindowSeconds() external view returns (uint32);

    /// @notice Get stream info for a specific reward token
    /// @param token The reward token address
    /// @return streamStart Per-token stream start timestamp
    /// @return streamEnd Per-token stream end timestamp
    /// @return streamTotal Total amount streaming for this token
    function getTokenStreamInfo(
        address token
    ) external view returns (uint64 streamStart, uint64 streamEnd, uint256 streamTotal);

    /// @notice Current reward emission rate per second for a token, based on remaining stream.
    function rewardRatePerSecond(address token) external view returns (uint256);

    /// @notice Pool APR in basis points for the underlying token, annualized from current stream.
    function aprBps() external view returns (uint256);

    /// @notice View functions.
    function stakedBalanceOf(address account) external view returns (uint256);
    function totalStaked() external view returns (uint256);

    /// @notice Escrow balance per token (non-reward reserves held for users).
    function escrowBalance(address token) external view returns (uint256);

    // ============ Admin Functions ============

    /// @notice Add a token to the whitelist (exempt from MAX_REWARD_TOKENS)
    /// @dev Only token admin can call - useful for trusted tokens like WETH, USDC
    /// @param token The token to whitelist
    function whitelistToken(address token) external;

    /// @notice Clean up finished reward tokens to free slots
    /// @dev Permissionless cleanup when token has no rewards remaining
    ///      Cannot remove underlying or whitelisted tokens
    /// @param token The token to clean up
    function cleanupFinishedRewardToken(address token) external;

    // ============ View Functions (Whitelist) ============

    /// @notice Get all whitelisted tokens
    /// @return Array of whitelisted token addresses
    function getWhitelistedTokens() external view returns (address[] memory);

    /// @notice Check if a token is whitelisted
    /// @param token The token address to check
    /// @return True if whitelisted, false otherwise
    function isTokenWhitelisted(address token) external view returns (bool);

    // ============ Governance Functions ============

    /// @notice Get the timestamp when user started staking (0 if not staking)
    /// @param user The user address
    /// @return timestamp The timestamp when staking started
    function stakeStartTime(address user) external view returns (uint256 timestamp);

    /// @notice Calculate voting power for a user
    /// @dev VP = (staked balance × time staked) / (1e18 × 86400)
    ///      Normalized to token-days for UI-friendly numbers
    ///      Example: 1000 tokens staked for 100 days = 100,000 token-days
    ///      Returns 0 if user has never staked or has unstaked completely
    /// @param user The user address
    /// @return votingPower The user's voting power in token-days
    function getVotingPower(address user) external view returns (uint256 votingPower);
}
