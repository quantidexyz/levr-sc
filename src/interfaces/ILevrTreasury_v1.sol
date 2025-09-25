// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Treasury v1 Interface
/// @notice Per-project treasury handling wrap/unwrap and governance execution.
interface ILevrTreasury_v1 {
    /// @notice Revert if caller is not the project governor.
    error OnlyGovernor();

    /// @notice Revert if caller is not the project wrapper.
    error OnlyWrapper();

    /// @notice Revert if zero address is provided.
    error ZeroAddress();

    /// @notice Revert if invalid amount is provided.
    error InvalidAmount();

    /// @notice Revert if user attempts to unstake more than staked.
    error InsufficientStake();

    /// @notice Reward token accumulator info.
    /// @param accPerShare Accumulated rewards per staked token, scaled by 1e18
    /// @param exists Whether this reward token is registered
    struct RewardInfo {
        uint256 accPerShare;
        bool exists;
    }

    /// @notice Emitted when the treasury is initialized by the factory.
    /// @param underlying Underlying token address
    /// @param governor Project governor address
    /// @param wrapper Project wrapper token address
    event Initialized(
        address indexed underlying,
        address indexed governor,
        address indexed wrapper
    );

    /// @notice Emitted on wrap (mint) operation.
    /// @param sender Caller who provided underlying
    /// @param to Recipient of wrapper tokens
    /// @param amount Underlying amount provided
    /// @param minted Wrapper tokens minted
    /// @param fees Total fees deducted from the operation
    event Wrapped(
        address indexed sender,
        address indexed to,
        uint256 amount,
        uint256 minted,
        uint256 fees
    );

    /// @notice Emitted on unwrap (redeem) operation.
    /// @param sender Caller who burned wrapper
    /// @param to Recipient of underlying
    /// @param amount Wrapper amount burned
    /// @param returned Underlying returned to the recipient
    /// @param fees Total fees deducted from the operation
    event Unwrapped(
        address indexed sender,
        address indexed to,
        uint256 amount,
        uint256 returned,
        uint256 fees
    );

    /// @notice Emitted when a boost is applied and rewards are accrued for stakers for a token.
    /// @param token Reward token accrued
    /// @param amount Amount of token allocated to stakers
    /// @param newAccRewardPerShare Updated accumulator value for this token
    event BoostApplied(
        address indexed token,
        uint256 amount,
        uint256 newAccRewardPerShare
    );

    /// @notice Emitted when pending rewards are paid to a staker for a token.
    /// @param staker Address receiving rewards
    /// @param to Recipient of rewards
    /// @param token Reward token paid
    /// @param amount Amount of token paid
    event RewardsClaimed(
        address indexed staker,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a user stakes wrapper tokens into this treasury.
    /// @param staker Address staking
    /// @param amount Amount staked
    event Staked(address indexed staker, uint256 amount);

    /// @notice Emitted when a user unstakes wrapper tokens from this treasury.
    /// @param staker Address unstaking
    /// @param to Recipient of unstaked wrapper tokens
    /// @param amount Amount unstaked
    event Unstaked(address indexed staker, address indexed to, uint256 amount);

    /// @notice Wrap underlying into wrapper tokens.
    /// @param amount Underlying amount to deposit
    /// @param to Recipient of wrapper tokens
    /// @return minted Amount of wrapper tokens minted
    function wrap(uint256 amount, address to) external returns (uint256 minted);

    /// @notice Unwrap wrapper into underlying tokens.
    /// @param amount Wrapper amount to burn
    /// @param to Recipient of underlying tokens
    /// @return returned Amount of underlying returned
    function unwrap(
        uint256 amount,
        address to
    ) external returns (uint256 returned);

    /// @notice Execute a governor-authorized transfer of underlying.
    /// @param to Recipient
    /// @param amount Amount to transfer
    function transfer(address to, uint256 amount) external;

    /// @notice Apply a staking boost by accruing `amount` of underlying to current stakers pro‑rata.
    /// @dev Requires there to be active stake; uses cumulative per‑share accounting.
    /// @param amount Amount of underlying to allocate to stakers
    function applyBoost(uint256 amount) external;

    /// @notice Accrue rewards for an arbitrary ERC20 token (e.g., the paired pool token).
    /// @param token Reward token to accrue
    /// @param amount Amount of token to allocate to stakers
    function accrueRewards(address token, uint256 amount) external;

    /// @notice Current underlying balance held by the treasury.
    /// @return balance Underlying token balance
    function getUnderlyingBalance() external view returns (uint256 balance);

    /// @notice Stake wrapper tokens into this treasury.
    /// @param amount Amount of wrapper tokens to stake
    function stake(uint256 amount) external;

    /// @notice Unstake wrapper tokens previously staked.
    /// @param amount Amount to unstake
    /// @param to Recipient for returned wrapper tokens
    function unstake(uint256 amount, address to) external;

    /// @notice Staked wrapper balance for a user.
    /// @param account Address to query
    /// @return balance Staked amount
    function stakedBalanceOf(
        address account
    ) external view returns (uint256 balance);

    /// @notice Total staked wrapper amount in this treasury.
    /// @return total Amount of staked wrapper
    function totalStaked() external view returns (uint256 total);

    /// @notice Claim pending rewards for selected tokens.
    /// @param tokens List of reward token addresses to claim
    /// @param to Recipient of rewards
    function claimRewards(address[] calldata tokens, address to) external;
}
