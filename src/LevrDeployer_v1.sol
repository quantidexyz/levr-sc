// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {LevrGovernor_v1} from './LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from './LevrStakedToken_v1.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrDeployer_v1} from './interfaces/ILevrDeployer_v1.sol';

contract LevrDeployer_v1 is ILevrDeployer_v1 {
    address public immutable authorizedFactory;

    modifier onlyAuthorized() {
        if (address(this) != authorizedFactory) revert UnauthorizedFactory();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        authorizedFactory = factory_;
    }

    /// @inheritdoc ILevrDeployer_v1
    function deployProject(
        address clankerToken,
        address treasury_,
        address staking_,
        address factory_,
        address trustedForwarder,
        address[] memory initialWhitelistedTokens
    ) external onlyAuthorized returns (ILevrFactory_v1.Project memory project) {
        project.treasury = treasury_;
        project.staking = staking_;

        IERC20Metadata token = IERC20Metadata(clankerToken);
        project.stakedToken = address(
            new LevrStakedToken_v1(
                string(abi.encodePacked('Levr Staked ', token.name())),
                string(abi.encodePacked('s', token.symbol())),
                token.decimals(),
                clankerToken,
                project.staking
            )
        );

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

        ILevrStaking_v1(project.staking).initialize(
            clankerToken,
            project.stakedToken,
            project.treasury,
            initialWhitelistedTokens
        );

        ILevrTreasury_v1(project.treasury).initialize(project.governor, clankerToken);
    }
}
