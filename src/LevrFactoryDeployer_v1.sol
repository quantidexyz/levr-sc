// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {LevrTreasury_v1} from './LevrTreasury_v1.sol';
import {LevrGovernor_v1} from './LevrGovernor_v1.sol';
import {LevrStaking_v1} from './LevrStaking_v1.sol';
import {LevrStakedToken_v1} from './LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';

/// @title Levr Factory Deployer Logic
/// @notice Standalone contract to reduce LevrFactory_v1 size via delegatecall
/// @dev This contract MUST only be called via delegatecall from the authorized LevrFactory_v1
///      The factory address is set at construction and enforced in deployProject
contract LevrFactoryDeployer_v1 {
    /// @notice The factory address that is authorized to delegatecall this logic
    /// @dev Set once at construction time. During delegatecall, address(this) equals the factory.
    address public immutable authorizedFactory;

    /// @notice Thrown when deployProject is called from an unauthorized context
    error UnauthorizedFactory();

    /// @param factory_ The factory address authorized to use this deployer logic
    constructor(address factory_) {
        require(factory_ != address(0), 'ZERO_FACTORY');
        authorizedFactory = factory_;
    }

    /// @notice Deploy all project contracts
    /// @dev Called via delegatecall from factory, uses factory's storage
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
    ) external returns (ILevrFactory_v1.Project memory project) {
        // When called via delegatecall, address(this) is the caller's address
        // Only the authorized factory can use this deployer logic
        if (address(this) != authorizedFactory) {
            revert UnauthorizedFactory();
        }
        // Use provided treasury or deploy new one
        if (treasury_ != address(0)) {
            project.treasury = treasury_;
        } else {
            project.treasury = address(new LevrTreasury_v1(factory_, trustedForwarder));
        }

        // Use provided staking or deploy new one
        if (staking_ != address(0)) {
            project.staking = staking_;
        } else {
            project.staking = address(new LevrStaking_v1(trustedForwarder));
        }

        // Deploy stakedToken
        uint8 uDec = IERC20Metadata(clankerToken).decimals();
        string memory name_ = string(
            abi.encodePacked('Levr Staked ', IERC20Metadata(clankerToken).name())
        );
        string memory symbol_ = string(
            abi.encodePacked('s', IERC20Metadata(clankerToken).symbol())
        );
        project.stakedToken = address(
            new LevrStakedToken_v1(name_, symbol_, uDec, clankerToken, project.staking)
        );

        // Deploy governor
        project.governor = address(
            new LevrGovernor_v1(
                factory_,
                project.treasury,
                project.staking,
                project.stakedToken,
                clankerToken,
                trustedForwarder
            )
        );

        // Initialize staking
        LevrStaking_v1(project.staking).initialize(
            clankerToken,
            project.stakedToken,
            project.treasury,
            factory_
        );

        // Initialize treasury
        LevrTreasury_v1(project.treasury).initialize(project.governor, clankerToken);

        return project;
    }
}
