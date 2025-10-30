// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Levr Fee Splitter v1 Interface
/// @notice Per-project fee splitter for flexible fee distribution
/// @dev Each Clanker token gets its own dedicated fee splitter instance
///      Deploy via LevrFeeSplitterFactory_v1
interface ILevrFeeSplitter_v1 {
    // ============ Structs ============

    /// @notice Split configuration for a specific receiver
    struct SplitConfig {
        address receiver; // Receiver address (can be staking contract or any address)
        uint16 bps; // Basis points (e.g., 3000 = 30%)
    }

    /// @notice Distribution state per reward token
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
    error DuplicateReceiver();
    error TooManyReceivers();
    error SplitsNotConfigured();
    error NoPendingFees();
    error NoReceivers();
    error ProjectNotRegistered();
    error ClankerMetadataNotFound();
    error LpLockerNotConfigured();

    // ============ Events ============

    /// @notice Emitted when splits are configured for this project
    /// @param clankerToken The Clanker token address (this splitter's project)
    /// @param splits Array of split configurations
    event SplitsConfigured(address indexed clankerToken, SplitConfig[] splits);

    /// @notice Emitted when fees are distributed
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

    /// @notice Emitted when fees are distributed to staking contract
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

    /// @notice Emitted when dust is recovered from the contract
    /// @param token The token that was recovered
    /// @param to The address that received the dust
    /// @param amount The amount of dust recovered
    event DustRecovered(address indexed token, address indexed to, uint256 amount);

    // ============ Admin Functions ============

    /// @notice Configure fee splits for this project (only token admin)
    /// @dev Total bps must equal 10,000 (100%)
    ///      Caller must be the token admin (IClankerToken(clankerToken).admin())
    ///      At most one split can point to the staking contract
    /// @param splits Array of split configurations
    function configureSplits(SplitConfig[] calldata splits) external;

    /// @notice Recover trapped dust from rounding (only token admin)
    /// @dev Only allows recovery of tokens that aren't pending distribution
    ///      This prevents stealing pending fees while allowing dust cleanup
    /// @param token The token to recover dust from
    /// @param to The address to send the dust to
    function recoverDust(address token, address to) external;

    // ============ Distribution Functions ============

    /// @notice Collect rewards from LP locker and distribute according to configured splits
    /// @dev Permissionless - anyone can trigger distribution
    ///      Supports multiple tokens (ETH, WETH, underlying, etc.)
    /// @param rewardToken The reward token to distribute (e.g., WETH, clankerToken itself)
    function distribute(address rewardToken) external;

    /// @notice Batch distribute multiple reward tokens
    /// @dev More gas efficient than calling distribute() multiple times
    /// @param rewardTokens Array of reward tokens to distribute
    function distributeBatch(address[] calldata rewardTokens) external;

    // ============ View Functions ============

    /// @notice Get current split configuration
    /// @return splits Array of split configurations
    function getSplits() external view returns (SplitConfig[] memory splits);

    /// @notice Get total configured split percentage
    /// @return totalBps Total basis points (should always be 10,000 if configured)
    function getTotalBps() external view returns (uint256 totalBps);

    /// @notice Get distribution state for a reward token
    /// @param rewardToken The reward token to check
    /// @return state Distribution state (total distributed, last distribution time)
    function getDistributionState(
        address rewardToken
    ) external view returns (DistributionState memory state);

    /// @notice Check if splits are configured (sum to 100%)
    /// @return configured True if splits are properly configured
    function isSplitsConfigured() external view returns (bool configured);

    /// @notice Get the staking contract address for this project
    /// @dev Queries factory.getProjectContracts(clankerToken).staking
    /// @return staking The staking contract address
    function getStakingAddress() external view returns (address staking);

    /// @notice Get the Clanker token this splitter handles
    /// @return token The Clanker token address
    function clankerToken() external view returns (address token);

    /// @notice Get the factory address
    /// @return factory The Levr factory address
    function factory() external view returns (address);
}
