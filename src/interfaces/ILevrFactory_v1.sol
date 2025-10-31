// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
        uint16 maxProposalAmountBps; // Max proposal amount as % of treasury (e.g., 500 = 5%)
        uint16 minimumQuorumBps; // Minimum quorum as % of current supply (e.g., 1000 = 10%) - prevents early capture
        // Staking parameters
        uint16 maxRewardTokens; // Max non-whitelisted reward tokens (e.g., 10)
    }

    /// @notice Project-specific configuration (subset of FactoryConfig, excludes protocolFeeBps).
    struct ProjectConfig {
        uint32 streamWindowSeconds;
        // Governance parameters
        uint32 proposalWindowSeconds;
        uint32 votingWindowSeconds;
        uint16 maxActiveProposals;
        uint16 quorumBps;
        uint16 approvalBps;
        uint16 minSTokenBpsToSubmit;
        uint16 maxProposalAmountBps;
        uint16 minimumQuorumBps;
        // Staking parameters
        uint16 maxRewardTokens;
    }

    /// @notice Project contract addresses.
    struct Project {
        address treasury;
        address governor;
        address staking;
        address stakedToken;
        bool verified; // Whether project can override factory config
    }

    /// @notice Project information including token address.
    struct ProjectInfo {
        address clankerToken; // The project token address
        Project project; // The project contract addresses
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

    /// @notice Revert if project does not exist.
    error ProjectNotFound();

    /// @notice Revert if project is not verified.
    error ProjectNotVerified();

    // ============ Events ============

    /// @notice Emitted when a trusted Clanker factory is added.
    /// @param factory Address of the Clanker factory added
    event TrustedClankerFactoryAdded(address indexed factory);

    /// @notice Emitted when a trusted Clanker factory is removed.
    /// @param factory Address of the Clanker factory removed
    event TrustedClankerFactoryRemoved(address indexed factory);

    /// @notice Emitted when treasury and staking are prepared for deployment.
    /// @param deployer Address that deployed the contracts
    /// @param treasury Deployed treasury address
    /// @param staking Deployed staking address
    event PreparationComplete(address indexed deployer, address indexed treasury, address staking);

    /// @notice Emitted when a project is registered.
    /// @param clankerToken Underlying Clanker token address
    /// @param treasury Project treasury address
    /// @param governor Project governor address
    /// @param staking Project staking address
    /// @param stakedToken Project staked token address
    event Registered(
        address indexed clankerToken,
        address indexed treasury,
        address governor,
        address staking,
        address stakedToken
    );

    /// @notice Emitted when configuration is updated.
    event ConfigUpdated();

    /// @notice Emitted when a project is verified.
    /// @param clankerToken Address of the verified project token
    event ProjectVerified(address indexed clankerToken);

    /// @notice Emitted when a project is unverified.
    /// @param clankerToken Address of the unverified project token
    event ProjectUnverified(address indexed clankerToken);

    /// @notice Emitted when a verified project's configuration is updated.
    /// @param clankerToken Address of the project token
    event ProjectConfigUpdated(address indexed clankerToken);

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

    /// @notice Verify a project, allowing it to override factory configuration.
    /// @dev Only callable by owner. Initializes project config with current factory config.
    /// @param clankerToken Token address of the project to verify
    function verifyProject(address clankerToken) external;

    /// @notice Unverify a project, removing its config override ability.
    /// @dev Only callable by owner. Clears project override config.
    /// @param clankerToken Token address of the project to unverify
    function unverifyProject(address clankerToken) external;

    /// @notice Update configuration for a verified project.
    /// @dev Only callable by token admin of a verified project.
    ///      Cannot override protocolFeeBps (protocol revenue protection).
    ///      Same validation rules as factory config apply.
    /// @param clankerToken Token address of the project
    /// @param cfg New project configuration
    function updateProjectConfig(address clankerToken, ProjectConfig calldata cfg) external;

    /// @notice Add a trusted Clanker factory for token validation.
    /// @dev Only callable by owner. Supports multiple factory versions.
    /// @param factory Address of the Clanker factory to trust
    function addTrustedClankerFactory(address factory) external;

    /// @notice Remove a trusted Clanker factory.
    /// @dev Only callable by owner.
    /// @param factory Address of the Clanker factory to remove
    function removeTrustedClankerFactory(address factory) external;

    /// @notice Get all trusted Clanker factories.
    /// @return Array of trusted Clanker factory addresses
    function getTrustedClankerFactories() external view returns (address[] memory);

    /// @notice Check if a factory is trusted.
    /// @param factory Address to check
    /// @return True if factory is trusted, false otherwise
    function isTrustedClankerFactory(address factory) external view returns (bool);

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

    /// @notice Get paginated list of registered projects.
    /// @param offset Starting index for pagination
    /// @param limit Maximum number of projects to return
    /// @return projects Array of project information
    /// @return total Total number of registered projects
    function getProjects(
        uint256 offset,
        uint256 limit
    ) external view returns (ProjectInfo[] memory projects, uint256 total);

    // Config getters for periphery contracts
    // NOTE: Optional clankerToken parameter - if provided and project is verified, returns project config

    /// @notice Protocol fee in basis points.
    function protocolFeeBps() external view returns (uint16);

    /// @notice Protocol treasury address for fee receipts.
    function protocolTreasury() external view returns (address);

    /// @notice Reward streaming window for staking accruals (in seconds).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Streaming window (project override if verified, otherwise default)
    function streamWindowSeconds(address clankerToken) external view returns (uint32);

    /// @notice Trusted forwarder for ERC2771 meta-transactions.
    function trustedForwarder() external view returns (address);

    // Governance config getters
    /// @notice Duration of proposal submission window (in seconds).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Proposal window (project override if verified, otherwise default)
    function proposalWindowSeconds(address clankerToken) external view returns (uint32);

    /// @notice Duration of voting window after proposals close (in seconds).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Voting window (project override if verified, otherwise default)
    function votingWindowSeconds(address clankerToken) external view returns (uint32);

    /// @notice Maximum concurrent active proposals per type.
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Max active proposals (project override if verified, otherwise default)
    function maxActiveProposals(address clankerToken) external view returns (uint16);

    /// @notice Minimum participation threshold in basis points (e.g., 7000 = 70%).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Quorum BPS (project override if verified, otherwise default)
    function quorumBps(address clankerToken) external view returns (uint16);

    /// @notice Minimum yes-vote threshold in basis points (e.g., 5100 = 51%).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Approval BPS (project override if verified, otherwise default)
    function approvalBps(address clankerToken) external view returns (uint16);

    /// @notice Minimum % of sToken supply to submit proposals (basis points, e.g., 100 = 1%).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Min stake BPS (project override if verified, otherwise default)
    function minSTokenBpsToSubmit(address clankerToken) external view returns (uint16);

    /// @notice Maximum proposal amount as % of treasury (basis points, e.g., 500 = 5%).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Max proposal amount BPS (project override if verified, otherwise default)
    function maxProposalAmountBps(address clankerToken) external view returns (uint16);

    /// @notice Minimum quorum as % of current supply (basis points, e.g., 1000 = 10%).
    /// @dev Used with adaptive quorum to prevent early governance capture
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Minimum quorum BPS (project override if verified, otherwise default)
    function minimumQuorumBps(address clankerToken) external view returns (uint16);

    // Staking config getters
    /// @notice Maximum number of non-whitelisted reward tokens (e.g., 10).
    /// @param clankerToken Optional project token address (0x0 = default config)
    /// @return Max reward tokens (project override if verified, otherwise default)
    function maxRewardTokens(address clankerToken) external view returns (uint16);
}
