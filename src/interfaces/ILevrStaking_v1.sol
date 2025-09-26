// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Staking v1 Interface
/// @notice Stakes underlying directly; mints staked ERC20; accrues multi-token rewards.
interface ILevrStaking_v1 {
    error ZeroAddress();
    error InvalidAmount();
    error InsufficientStake();
    error InsufficientRewardLiquidity();
    error InsufficientEscrow();

    /// @notice Reward token accumulator info.
    /// @param accPerShare Accumulated rewards per staked token, scaled by 1e18
    /// @param exists Whether this reward token is registered
    struct RewardInfo {
        uint256 accPerShare;
        bool exists;
    }

    /// @notice Emitted when a user stakes underlying.
    event Staked(address indexed staker, uint256 amount);
    /// @notice Emitted when a user unstakes underlying.
    event Unstaked(address indexed staker, address indexed to, uint256 amount);
    /// @notice Emitted when rewards accrue for a token.
    event RewardsAccrued(
        address indexed token,
        uint256 amount,
        uint256 newAccPerShare
    );
    /// @notice Emitted when rewards claimed.
    event RewardsClaimed(
        address indexed account,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    /// @notice Initialize staking module.
    function initialize(
        address underlying,
        address stakedToken,
        address treasury
    ) external;

    /// @notice Stake underlying; mints staked token to msg.sender.
    function stake(uint256 amount) external;

    /// @notice Unstake; burns staked token and returns underlying to `to`.
    function unstake(uint256 amount, address to) external;

    /// @notice Claim rewards for tokens to `to`.
    function claimRewards(address[] calldata tokens, address to) external;

    /// @notice Accrue rewards for token.
    function accrueRewards(address token, uint256 amount) external;

    /// @notice Accrue rewards from treasury, optionally pulling tokens from treasury first.
    /// @param token Reward token
    /// @param amount Amount to accrue
    /// @param pullFromTreasury If true, transfer `amount` from treasury before accrual
    function accrueFromTreasury(
        address token,
        uint256 amount,
        bool pullFromTreasury
    ) external;

    /// @notice View functions.
    function stakedBalanceOf(address account) external view returns (uint256);
    function totalStaked() external view returns (uint256);

    /// @notice Escrow balance per token (non-reward reserves held for users).
    function escrowBalance(address token) external view returns (uint256);
}
