// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Factory v1 Interface
/// @notice Global configuration and per-project contract deployment/registry.
interface ILevrFactory_v1 {
  // ============ Structs ============

  /// @notice Single numeric tier value.
  struct TierConfig {
    uint256 value;
  }

  /// @notice Global protocol configuration stored in the factory.
  struct FactoryConfig {
    uint16 protocolFeeBps;
    uint32 submissionDeadlineSeconds;
    uint16 maxSubmissionPerType;
    uint32 streamWindowSeconds;
    TierConfig[] transferTiers;
    TierConfig[] stakingBoostTiers;
    uint256 minWTokenToSubmit;
    address protocolTreasury;
  }

  /// @notice Project contract addresses.
  struct Project {
    address treasury;
    address governor;
    address staking;
    address stakedToken;
  }

  // ============ Errors ============

  /// @notice Revert if caller is not the token admin.
  error UnauthorizedCaller();

  // ============ Events ============

  /// @notice Emitted when a project is registered.
  /// @param clankerToken Underlying Clanker token address
  /// @param treasury Project treasury address
  /// @param governor Project governor address
  /// @param stakedToken Project staked token address
  event Registered(address indexed clankerToken, address indexed treasury, address governor, address stakedToken);

  /// @notice Emitted when configuration is updated.
  event ConfigUpdated();

  // ============ Functions ============

  /// @notice Register a project and deploy contracts.
  /// @dev Only callable by the Clanker token admin. Always deploys fresh treasury.
  /// @param clankerToken Underlying Clanker token
  /// @return treasury Deployed treasury address
  /// @return governor Deployed governor address
  /// @return staking Deployed staking module address
  /// @return stakedToken Deployed staked token address
  function register(
    address clankerToken
  ) external returns (address treasury, address governor, address staking, address stakedToken);

  /// @notice Simulate registration to predict deployed addresses without authorization checks.
  /// @dev This function does not revert for authorization and does not modify state.
  ///      Uses CREATE2 with token address as salt for deterministic address prediction.
  ///      Addresses are stable and can be predicted at any time regardless of factory state.
  /// @param clankerToken Underlying Clanker token used as basis for CREATE2 salt
  /// @param startNonce Deprecated parameter kept for backwards compatibility, not used
  /// @return treasury Predicted treasury address
  /// @return governor Predicted governor address
  /// @return staking Predicted staking module address
  /// @return stakedToken Predicted staked token address
  function registerDryRun(
    address clankerToken,
    uint256 startNonce
  ) external view returns (address treasury, address governor, address staking, address stakedToken);

  /// @notice Update global protocol configuration.
  /// @param cfg New configuration
  function updateConfig(FactoryConfig calldata cfg) external;

  /// @notice Get the deployed contracts for a given project.
  /// @param clankerToken Token address used as project key
  /// @return treasury Project treasury address
  /// @return governor Project governor address
  /// @return staking Project staking module address
  /// @return stakedToken ERC20 representing staked balances
  function getProjectContracts(
    address clankerToken
  ) external view returns (address treasury, address governor, address staking, address stakedToken);

  // Config getters for periphery contracts
  /// @notice Protocol fee in basis points applied to wrap/unwrap.
  function protocolFeeBps() external view returns (uint16);

  /// @notice Proposal execution deadline (seconds).
  function submissionDeadlineSeconds() external view returns (uint32);

  /// @notice Maximum proposals per type per window (reserved).
  function maxSubmissionPerType() external view returns (uint16);

  /// @notice Minimum wrapper balance required to submit proposals.
  function minWTokenToSubmit() external view returns (uint256);

  /// @notice Protocol treasury address for fee receipts.
  function protocolTreasury() external view returns (address);

  /// @notice Reward streaming window for staking accruals (in seconds).
  function streamWindowSeconds() external view returns (uint32);

  /// @notice Number of transfer tiers.
  function getTransferTierCount() external view returns (uint256);

  /// @notice Transfer tier value by index.
  function getTransferTier(uint256 index) external view returns (uint256);

  /// @notice Number of staking boost tiers.
  function getStakingBoostTierCount() external view returns (uint256);

  /// @notice Staking boost tier value by index.
  function getStakingBoostTier(uint256 index) external view returns (uint256);
}
