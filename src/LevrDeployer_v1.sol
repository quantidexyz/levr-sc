// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrDeployer_v1} from './interfaces/ILevrDeployer_v1.sol';
import {ILevrGovernor_v1} from './interfaces/ILevrGovernor_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';

contract LevrDeployer_v1 is ILevrDeployer_v1 {
    address public immutable authorizedFactory;
    address public immutable treasuryImplementation;
    address public immutable stakingImplementation;
    address public immutable governorImplementation;
    address public immutable stakedTokenImplementation;

    modifier onlyAuthorized() {
        if (address(this) != authorizedFactory) revert UnauthorizedFactory();
        _;
    }

    constructor(
        address factory_,
        address treasuryImplementation_,
        address stakingImplementation_,
        address governorImplementation_,
        address stakedTokenImplementation_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        if (treasuryImplementation_ == address(0)) revert ZeroAddress();
        if (stakingImplementation_ == address(0)) revert ZeroAddress();
        if (governorImplementation_ == address(0)) revert ZeroAddress();
        if (stakedTokenImplementation_ == address(0)) revert ZeroAddress();
        authorizedFactory = factory_;
        treasuryImplementation = treasuryImplementation_;
        stakingImplementation = stakingImplementation_;
        governorImplementation = governorImplementation_;
        stakedTokenImplementation = stakedTokenImplementation_;
    }

    /// @inheritdoc ILevrDeployer_v1
    function prepareContracts()
        external
        onlyAuthorized
        returns (address treasury, address staking)
    {
        treasury = Clones.clone(treasuryImplementation);
        staking = Clones.clone(stakingImplementation);
    }

    /// @inheritdoc ILevrDeployer_v1
    function deployProject(
        address clankerToken,
        address treasury_,
        address staking_,
        address[] memory initialWhitelistedTokens
    ) external onlyAuthorized returns (ILevrFactory_v1.Project memory project) {
        project.treasury = treasury_;
        project.staking = staking_;

        // Clone and initialize stakedToken
        IERC20Metadata token = IERC20Metadata(clankerToken);
        project.stakedToken = Clones.clone(stakedTokenImplementation);
        ILevrStakedToken_v1(project.stakedToken).initialize(
            string(abi.encodePacked('Levr Staked ', token.name())),
            string(abi.encodePacked('s', token.symbol())),
            token.decimals(),
            clankerToken,
            project.staking
        );

        // Clone and initialize governor
        project.governor = Clones.clone(governorImplementation);
        ILevrGovernor_v1(project.governor).initialize(
            project.treasury,
            project.staking,
            project.stakedToken,
            clankerToken
        );

        // Initialize staking (cloned in prepareContracts)
        ILevrStaking_v1(project.staking).initialize(
            clankerToken,
            project.stakedToken,
            project.treasury,
            initialWhitelistedTokens
        );

        // Initialize treasury (cloned in prepareContracts)
        ILevrTreasury_v1(project.treasury).initialize(project.governor, clankerToken);
    }
}
