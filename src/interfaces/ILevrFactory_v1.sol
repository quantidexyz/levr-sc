// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Factory v1 Interface
/// @notice Global configuration and per-project contract deployment/registry.
interface ILevrFactory_v1 {
    // ============ Structs ============

    /// @notice Global protocol configuration stored in the factory.
    struct FactoryConfig {
        uint16 protocolFeeBps;
        uint32 streamWindowSeconds;
        address protocolTreasury;
        // Governance parameters
        uint32 proposalWindowSeconds; // Duration of proposal submission window
        uint32 votingWindowSeconds; // Duration of voting window after proposals close
        uint16 maxActiveProposals; // Maximum concurrent active proposals per type
        uint16 quorumBps; // Minimum participation threshold (e.g., 7000 = 70%)
        uint16 approvalBps; // Minimum yes-vote threshold (e.g., 5100 = 51%)
        uint16 minSTokenBpsToSubmit; // Min % of sToken supply to submit (e.g., 100 = 1%)
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

    /// @notice Clanker integration metadata for a token.
    struct ClankerMetadata {
        address feeLocker;
        address lpLocker;
        address hook;
        bool exists;
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
    event Registered(
        address indexed clankerToken,
        address indexed treasury,
        address governor,
        address stakedToken
    );

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
    function getProjectContracts(
        address clankerToken
    ) external view returns (Project memory project);

    /// @notice Get Clanker integration metadata for a token.
    /// @param clankerToken The clanker token address
    /// @return metadata The clanker integration addresses and status
    function getClankerMetadata(
        address clankerToken
    ) external view returns (ClankerMetadata memory metadata);

    // Config getters for periphery contracts
    /// @notice Protocol fee in basis points.
    function protocolFeeBps() external view returns (uint16);

    /// @notice Protocol treasury address for fee receipts.
    function protocolTreasury() external view returns (address);

    /// @notice Reward streaming window for staking accruals (in seconds).
    function streamWindowSeconds() external view returns (uint32);

    /// @notice Clanker factory address.
    function clankerFactory() external view returns (address);

    /// @notice Trusted forwarder for ERC2771 meta-transactions.
    function trustedForwarder() external view returns (address);

    // Governance config getters
    /// @notice Duration of proposal submission window (in seconds).
    function proposalWindowSeconds() external view returns (uint32);

    /// @notice Duration of voting window after proposals close (in seconds).
    function votingWindowSeconds() external view returns (uint32);

    /// @notice Maximum concurrent active proposals per type.
    function maxActiveProposals() external view returns (uint16);

    /// @notice Minimum participation threshold in basis points (e.g., 7000 = 70%).
    function quorumBps() external view returns (uint16);

    /// @notice Minimum yes-vote threshold in basis points (e.g., 5100 = 51%).
    function approvalBps() external view returns (uint16);

    /// @notice Minimum % of sToken supply to submit proposals (basis points, e.g., 100 = 1%).
    function minSTokenBpsToSubmit() external view returns (uint16);
}
