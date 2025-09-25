// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Factory v1 Interface
/// @notice Global configuration and per-project contract deployment/registry.
interface ILevrFactory_v1 {
    /// @notice Parameters controlling registration.
    struct RegisterParams {
        address treasury;
        bytes extraConfig;
    }

    /// @notice Single numeric tier value.
    struct TierConfig {
        uint256 value;
    }

    /// @notice Global protocol configuration stored in the factory.
    struct FactoryConfig {
        uint16 protocolFeeBps;
        uint16 projectFeeBpsOfProtocolFee;
        uint32 submissionDeadlineSeconds;
        uint16 maxSubmissionPerType;
        TierConfig[] transferTiers;
        TierConfig[] stakingBoostTiers;
        uint256 minWTokenToSubmit;
        address protocolTreasury;
    }

    /// @notice Emitted when a project is registered.
    /// @param clankerToken Underlying Clanker token address
    /// @param treasury Project treasury address
    /// @param governor Project governor address
    /// @param wrapper Project wrapper token address
    event Registered(
        address indexed clankerToken,
        address indexed treasury,
        address governor,
        address wrapper
    );

    /// @notice Emitted when configuration is updated.
    event ConfigUpdated();

    /// @notice Register a project and deploy contracts if needed.
    /// @param clankerToken Underlying token to wrap
    /// @param params Optional registration params
    /// @return governor Deployed or discovered governor
    /// @return wrapper Deployed wrapper token
    function register(
        address clankerToken,
        RegisterParams calldata params
    ) external returns (address governor, address wrapper);

    /// @notice Update global protocol configuration.
    /// @param cfg New configuration
    function updateConfig(FactoryConfig calldata cfg) external;

    /// @notice Get the deployed contracts for a given project.
    /// @param clankerToken Token address used as project key
    /// @return treasury Project treasury address
    /// @return governor Project governor address
    /// @return wrapper Project wrapper token address
    function getProjectContracts(
        address clankerToken
    )
        external
        view
        returns (address treasury, address governor, address wrapper);

    // Config getters for periphery contracts
    /// @notice Protocol fee in basis points applied to wrap/unwrap.
    function protocolFeeBps() external view returns (uint16);

    /// @notice Share of protocol fee going to project treasury (bps of fee).
    function projectFeeBpsOfProtocolFee() external view returns (uint16);

    /// @notice Proposal execution deadline (seconds).
    function submissionDeadlineSeconds() external view returns (uint32);

    /// @notice Maximum proposals per type per window (reserved).
    function maxSubmissionPerType() external view returns (uint16);

    /// @notice Minimum wrapper balance required to submit proposals.
    function minWTokenToSubmit() external view returns (uint256);

    /// @notice Protocol treasury address for fee receipts.
    function protocolTreasury() external view returns (address);

    /// @notice Number of transfer tiers.
    function getTransferTierCount() external view returns (uint256);

    /// @notice Transfer tier value by index.
    function getTransferTier(uint256 index) external view returns (uint256);

    /// @notice Number of staking boost tiers.
    function getStakingBoostTierCount() external view returns (uint256);

    /// @notice Staking boost tier value by index.
    function getStakingBoostTier(uint256 index) external view returns (uint256);
}
