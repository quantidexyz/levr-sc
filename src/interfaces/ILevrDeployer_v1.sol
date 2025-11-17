// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILevrFactory_v1} from './ILevrFactory_v1.sol';

/// @title Levr Deployer v1 Interface
/// @notice Centralized deployment logic for all Levr contracts via delegatecall
/// @dev This contract MUST only be called via delegatecall from the authorized LevrFactory_v1
///      The factory address is set at construction and enforced in all functions
interface ILevrDeployer_v1 {
    /// @notice Thrown when a function is called from an unauthorized context
    error UnauthorizedFactory();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Emitted when treasury and staking clone instances are prepared
    /// @param treasury The cloned treasury address
    /// @param staking The cloned staking address
    event ContractsPrepared(address indexed treasury, address indexed staking);

    /// @notice Emitted when a full project deployment completes
    /// @param clankerToken The underlying token for the project
    /// @param treasury The treasury contract address
    /// @param staking The staking contract address
    /// @param stakedToken The freshly deployed staked token address
    /// @param governor The governor contract address
    event ProjectDeployed(
        address indexed clankerToken,
        address indexed treasury,
        address indexed staking,
        address stakedToken,
        address governor
    );

    /// @notice The factory address that is authorized to delegatecall this logic
    /// @dev Set once at construction time. During delegatecall, address(this) equals the factory.
    /// @return The authorized factory address
    function authorizedFactory() external view returns (address);

    /// @notice Implementation address used for treasury clones
    /// @return The treasury implementation contract address
    function treasuryImplementation() external view returns (address);

    /// @notice Implementation address used for staking clones
    /// @return The staking implementation contract address
    function stakingImplementation() external view returns (address);

    /// @notice Implementation address used for governor clones
    /// @return The governor implementation contract address
    function governorImplementation() external view returns (address);

    /// @notice Prepare treasury and staking contracts (called via delegatecall)
    /// @dev Executed in factory context to reduce factory bytecode size
    ///      Uses minimal proxy clones to reduce deployment gas and bytecode
    /// @return treasury The cloned treasury address
    /// @return staking The cloned staking address
    function prepareContracts() external returns (address treasury, address staking);

    /// @notice Deploy all project contracts (governor and stakedToken)
    /// @dev Called via delegatecall from factory during register()
    ///      During delegatecall, address(this) is the calling contract's address
    ///      This function reverts if address(this) != authorizedFactory
    ///      Governor, treasury, and staking use clones; stakedToken is deployed as new instance
    /// @param clankerToken The underlying Clanker token address
    /// @param treasury_ Pre-deployed treasury address from prepareContracts()
    /// @param staking_ Pre-deployed staking address from prepareContracts()
    /// @param initialWhitelistedTokens Initial whitelist for reward tokens (e.g., WETH - underlying is auto-whitelisted)
    /// @return project The deployed project contract addresses
    function deployProject(
        address clankerToken,
        address treasury_,
        address staking_,
        address[] memory initialWhitelistedTokens
    ) external returns (ILevrFactory_v1.Project memory project);
}
