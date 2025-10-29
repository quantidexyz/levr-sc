// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    /// @notice The factory address that is authorized to delegatecall this logic
    /// @dev Set once at construction time. During delegatecall, address(this) equals the factory.
    /// @return The authorized factory address
    function authorizedFactory() external view returns (address);

    /// @notice Deploy all project contracts (governor and stakedToken, optionally treasury and staking)
    /// @dev Called via delegatecall from factory during register()
    ///      During delegatecall, address(this) is the calling contract's address
    ///      This function reverts if address(this) != authorizedFactory
    /// @param clankerToken The underlying Clanker token address
    /// @param treasury_ Pre-deployed treasury address (or address(0) to deploy new)
    /// @param staking_ Pre-deployed staking address (or address(0) to deploy new)
    /// @param factory_ The factory address (for initialization)
    /// @param trustedForwarder The ERC2771 forwarder address
    /// @return project The deployed project contract addresses
    function deployProject(
        address clankerToken,
        address treasury_,
        address staking_,
        address factory_,
        address trustedForwarder
    ) external returns (ILevrFactory_v1.Project memory project);
}
