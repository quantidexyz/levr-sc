// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Fee Splitter v1 Interface
/// @notice Singleton that enables flexible fee distribution for all Clanker tokens
/// @dev Acts as fee receiver from ClankerLpLocker and distributes fees according to per-project configuration
interface ILevrFeeSplitter_v1 {
    // ============ Structs ============

    /// @notice Split configuration for a specific receiver
    struct SplitConfig {
        address receiver; // Receiver address (can be staking contract or any address)
        uint16 bps; // Basis points (e.g., 3000 = 30%)
    }

    /// @notice Distribution state per project per reward token
    struct DistributionState {
        uint256 totalDistributed; // Total amount distributed for this token
        uint256 lastDistribution; // Timestamp of last distribution
    }

    // ============ Errors ============

    error OnlyTokenAdmin();
    error InvalidSplits();
    error InvalidTotalBps();
    error ZeroAddress();
    error ZeroBps();
    error DuplicateStakingReceiver();
    error SplitsNotConfigured();
    error NoPendingFees();
    error NoReceivers();
    error ProjectNotRegistered();
    error ClankerMetadataNotFound();
    error LpLockerNotConfigured();

    // ============ Events ============

    /// @notice Emitted when splits are configured for a project
    /// @param clankerToken The Clanker token address (identifies the project)
    /// @param splits Array of split configurations
    event SplitsConfigured(address indexed clankerToken, SplitConfig[] splits);

    /// @notice Emitted when fees are distributed for a project
    /// @param clankerToken The Clanker token address
    /// @param token The reward token that was distributed
    /// @param totalAmount Total amount distributed
    event Distributed(address indexed clankerToken, address indexed token, uint256 totalAmount);

    /// @notice Emitted for each fee distribution to a receiver
    /// @param clankerToken The Clanker token address
    /// @param token The reward token
    /// @param receiver The receiver address
    /// @param amount The amount sent to receiver
    event FeeDistributed(
        address indexed clankerToken,
        address indexed token,
        address indexed receiver,
        uint256 amount
    );

    /// @notice Emitted when fees are distributed to staking contract (signals manual accrual needed)
    /// @param clankerToken The Clanker token address
    /// @param token The reward token
    /// @param amount The amount sent to staking
    event StakingDistribution(address indexed clankerToken, address indexed token, uint256 amount);

    /// @notice Emitted when automatic accrual succeeds after distribution
    /// @param clankerToken The Clanker token address
    /// @param token The reward token
    event AutoAccrualSuccess(address indexed clankerToken, address indexed token);

    /// @notice Emitted when automatic accrual fails after distribution
    /// @param clankerToken The Clanker token address
    /// @param token The reward token
    event AutoAccrualFailed(address indexed clankerToken, address indexed token);

    // ============ Admin Functions ============

    /// @notice Configure fee splits for a project (only token admin)
    /// @dev Total bps must equal 10,000 (100%)
    ///      Caller must be the token admin (IClankerToken(clankerToken).admin())
    ///      At most one split can point to the staking contract
    /// @param clankerToken The Clanker token address (identifies the project)
    /// @param splits Array of split configurations for this project
    function configureSplits(address clankerToken, SplitConfig[] calldata splits) external;

    // ============ Distribution Functions ============

    /// @notice Collect rewards from LP locker and distribute according to configured splits
    /// @dev Permissionless - anyone can trigger distribution
    ///      Supports multiple tokens (ETH, WETH, underlying, etc.)
    ///      ⚠️ IMPORTANT: Call once per (clankerToken, rewardToken) pair
    ///         Multiple calls for same pair will have no effect (second call finds 0 balance)
    /// @param clankerToken The Clanker token address (identifies the project)
    /// @param rewardToken The reward token to distribute (e.g., WETH, clankerToken itself)
    function distribute(address clankerToken, address rewardToken) external;

    /// @notice Batch distribute multiple reward tokens for a single project
    /// @dev More gas efficient than calling distribute() multiple times
    ///      Use this for multi-token fee distribution (e.g., WETH + Clanker token)
    /// @param clankerToken The Clanker token address (identifies the project)
    /// @param rewardTokens Array of reward tokens to distribute
    function distributeBatch(address clankerToken, address[] calldata rewardTokens) external;

    // ============ View Functions ============

    /// @notice Get current split configuration for a project
    /// @param clankerToken The Clanker token address
    /// @return splits Array of split configurations
    function getSplits(address clankerToken) external view returns (SplitConfig[] memory splits);

    /// @notice Get total configured split percentage for a project
    /// @param clankerToken The Clanker token address
    /// @return totalBps Total basis points (should always be 10,000 if configured)
    function getTotalBps(address clankerToken) external view returns (uint256 totalBps);

    /// @notice Get pending fees for a project's reward token (balance in this contract)
    /// @param clankerToken The Clanker token address (identifies the project)
    /// @param rewardToken The reward token to check
    /// @return pending Pending fees available to distribute
    function pendingFees(
        address clankerToken,
        address rewardToken
    ) external view returns (uint256 pending);

    /// @notice Get distribution state for a project's reward token
    /// @param clankerToken The Clanker token address
    /// @param rewardToken The reward token to check
    /// @return state Distribution state (total distributed, last distribution time)
    function getDistributionState(
        address clankerToken,
        address rewardToken
    ) external view returns (DistributionState memory state);

    /// @notice Check if splits are configured for a project (sum to 100%)
    /// @param clankerToken The Clanker token address
    /// @return configured True if splits are properly configured
    function isSplitsConfigured(address clankerToken) external view returns (bool configured);

    /// @notice Get the staking contract address for a project
    /// @dev Queries factory.getProjectContracts(clankerToken).staking
    /// @param clankerToken The Clanker token address
    /// @return staking The staking contract address
    function getStakingAddress(address clankerToken) external view returns (address staking);

    /// @notice Get the factory address
    /// @return factory The Levr factory address
    function factory() external view returns (address);
}
