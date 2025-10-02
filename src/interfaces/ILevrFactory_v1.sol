// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Factory v1 Interface
/// @notice Global configuration and per-project contract deployment/registry.
interface ILevrFactory_v1 {
  // ============ Structs ============

  /// @notice Global protocol configuration stored in the factory.
  struct FactoryConfig {
    uint16 protocolFeeBps;
    uint32 submissionDeadlineSeconds;
    uint16 maxSubmissionPerType;
    uint32 streamWindowSeconds;
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

  /// @notice Prepared contracts for a deployer (before registration).
  struct PreparedContracts {
    address treasury;
    address staking;
  }

  // ============ Errors ============

  /// @notice Revert if caller is not the token admin.
  error UnauthorizedCaller();

  // ============ Events ============

  /// @notice Emitted when treasury and staking are prepared for deployment.
  /// @param deployer Address that deployed the contracts
  /// @param treasury Deployed treasury address
  /// @param staking Deployed staking address
  event PreparationComplete(address indexed deployer, address indexed treasury, address staking);

  /// @notice Emitted when a project is registered.
  /// @param clankerToken Underlying Clanker token address
  /// @param treasury Project treasury address
  /// @param governor Project governor address
  /// @param stakedToken Project staked token address
  event Registered(address indexed clankerToken, address indexed treasury, address governor, address stakedToken);

  /// @notice Emitted when configuration is updated.
  event ConfigUpdated();

  // ============ Functions ============

  /// @notice Prepare for deployment by deploying treasury and staking modules.
  /// @dev Deploys treasury and staking contracts.
  ///      Call this BEFORE deploying Clanker token to get the treasury address.
  ///      The returned treasury address should be used as the fee/airdrop recipient in Clanker deployment.
  ///      Treasury operations are controlled by the governor (deployed during register).
  /// @return treasury Deployed treasury address
  /// @return staking Deployed staking module address
  function prepareForDeployment() external returns (address treasury, address staking);

  /// @notice Register a project and deploy contracts.
  /// @dev Only callable by the Clanker token admin.
  ///      Uses treasury/staking from prepareForDeployment() if called by same address.
  ///      Otherwise deploys fresh contracts.
  ///      Treasury control is always via the deployed governor.
  /// @param clankerToken Underlying Clanker token
  /// @return project Project contract addresses
  function register(address clankerToken) external returns (Project memory project);

  /// @notice Update global protocol configuration.
  /// @param cfg New configuration
  function updateConfig(FactoryConfig calldata cfg) external;

  /// @notice Get the deployed contracts for a given project.
  /// @param clankerToken Token address used as project key
  /// @return project Project contract addresses
  function getProjectContracts(address clankerToken) external view returns (Project memory project);

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

  /// @notice Trusted forwarder for ERC2771 meta-transactions.
  function trustedForwarder() external view returns (address);
}
