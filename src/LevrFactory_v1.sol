// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ERC2771Context} from '@openzeppelin/contracts/metatx/ERC2771Context.sol';
import {Context} from '@openzeppelin/contracts/utils/Context.sol';

import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {IClankerToken} from './interfaces/external/IClankerToken.sol';
import {IClanker} from './interfaces/external/IClanker.sol';
import {IClankerLpLockerFeeConversion} from './interfaces/external/IClankerLpLockerFeeConversion.sol';

import {LevrTreasury_v1} from './LevrTreasury_v1.sol';
import {LevrStaking_v1} from './LevrStaking_v1.sol';

contract LevrFactory_v1 is ILevrFactory_v1, Ownable, ReentrancyGuard, ERC2771Context {
    uint16 public override protocolFeeBps;
    uint32 public override streamWindowSeconds;
    address public override protocolTreasury;
    address public immutable clankerFactory;
    address public immutable deployerDelegate; // LevrFactoryDeployer_v1 for delegatecall

    // Governance parameters
    uint32 public override proposalWindowSeconds;
    uint32 public override votingWindowSeconds;
    uint16 public override maxActiveProposals;
    uint16 public override quorumBps;
    uint16 public override approvalBps;
    uint16 public override minSTokenBpsToSubmit;

    mapping(address => ILevrFactory_v1.Project) private _projects; // clankerToken => Project

    // Track prepared contracts by deployer
    mapping(address => ILevrFactory_v1.PreparedContracts) private _preparedContracts; // deployer => PreparedContracts

    constructor(
        FactoryConfig memory cfg,
        address owner_,
        address trustedForwarder_,
        address clankerFactory_,
        address deployerDelegate_
    ) Ownable(owner_) ERC2771Context(trustedForwarder_) {
        _applyConfig(cfg);
        clankerFactory = clankerFactory_;
        deployerDelegate = deployerDelegate_;
    }

    /// @inheritdoc ILevrFactory_v1
    function prepareForDeployment() external override returns (address treasury, address staking) {
        address deployer = _msgSender();

        // Deploy directly (simple enough to keep in factory)
        treasury = address(new LevrTreasury_v1(address(this), trustedForwarder()));
        staking = address(new LevrStaking_v1(trustedForwarder()));

        // Store prepared contracts for this deployer
        _preparedContracts[deployer] = ILevrFactory_v1.PreparedContracts({
            treasury: treasury,
            staking: staking
        });

        emit PreparationComplete(deployer, treasury, staking);
    }

    /// @inheritdoc ILevrFactory_v1
    function register(
        address clankerToken
    ) external override returns (ILevrFactory_v1.Project memory project) {
        Project storage p = _projects[clankerToken];
        require(p.staking == address(0), 'ALREADY_REGISTERED');

        address caller = _msgSender();

        // Only token admin can register
        address tokenAdmin = IClankerToken(clankerToken).admin();
        if (caller != tokenAdmin) {
            revert UnauthorizedCaller();
        }

        // Look up prepared contracts for this caller
        ILevrFactory_v1.PreparedContracts memory prepared = _preparedContracts[caller];

        return _deployProject(clankerToken, prepared.treasury, prepared.staking);
    }

    function _deployProject(
        address clankerToken,
        address treasury_,
        address staking_
    ) internal returns (ILevrFactory_v1.Project memory project) {
        // Deploy all contracts via delegatecall to deployer logic
        bytes memory data = abi.encodeWithSignature(
            'deployProject(address,address,address,address,address)',
            clankerToken,
            treasury_,
            staking_,
            address(this),
            trustedForwarder()
        );

        (bool success, bytes memory returnData) = deployerDelegate.delegatecall(data);
        require(success, 'DEPLOY_FAILED');

        project = abi.decode(returnData, (ILevrFactory_v1.Project));

        // Store in registry
        _projects[clankerToken] = project;

        emit Registered(clankerToken, project.treasury, project.governor, project.stakedToken);
    }

    /// @inheritdoc ILevrFactory_v1
    function updateConfig(FactoryConfig calldata cfg) external override onlyOwner {
        _applyConfig(cfg);
        emit ConfigUpdated();
    }

    /// @inheritdoc ILevrFactory_v1
    function getProjectContracts(
        address clankerToken
    ) external view override returns (ILevrFactory_v1.Project memory project) {
        return _projects[clankerToken];
    }

    /// @inheritdoc ILevrFactory_v1
    function getClankerMetadata(
        address clankerToken
    ) external view override returns (ILevrFactory_v1.ClankerMetadata memory metadata) {
        if (clankerFactory == address(0)) {
            return
                ILevrFactory_v1.ClankerMetadata({
                    feeLocker: address(0),
                    lpLocker: address(0),
                    hook: address(0),
                    exists: false
                });
        }

        try IClanker(clankerFactory).tokenDeploymentInfo(clankerToken) returns (
            IClanker.DeploymentInfo memory info
        ) {
            if (info.token == clankerToken) {
                address feeLocker = address(0);

                // Try to get fee locker from LP locker
                if (info.locker != address(0)) {
                    try IClankerLpLockerFeeConversion(info.locker).feeLocker() returns (
                        address _feeLocker
                    ) {
                        feeLocker = _feeLocker;
                    } catch {
                        // Fee locker not available
                    }
                }

                return
                    ILevrFactory_v1.ClankerMetadata({
                        feeLocker: feeLocker,
                        lpLocker: info.locker,
                        hook: info.hook,
                        exists: true
                    });
            }
        } catch {
            // Factory doesn't know this token
        }

        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0),
                lpLocker: address(0),
                hook: address(0),
                exists: false
            });
    }

    function _applyConfig(FactoryConfig memory cfg) internal {
        require(cfg.streamWindowSeconds >= 1 days, 'STREAM_WINDOW_TOO_SHORT');
        protocolFeeBps = cfg.protocolFeeBps;
        streamWindowSeconds = cfg.streamWindowSeconds;
        protocolTreasury = cfg.protocolTreasury;
        proposalWindowSeconds = cfg.proposalWindowSeconds;
        votingWindowSeconds = cfg.votingWindowSeconds;
        maxActiveProposals = cfg.maxActiveProposals;
        quorumBps = cfg.quorumBps;
        approvalBps = cfg.approvalBps;
        minSTokenBpsToSubmit = cfg.minSTokenBpsToSubmit;
    }

    /// @dev Override trustedForwarder to satisfy both ILevrFactory_v1 and ERC2771Context
    function trustedForwarder()
        public
        view
        override(ERC2771Context, ILevrFactory_v1)
        returns (address)
    {
        return ERC2771Context.trustedForwarder();
    }

    /// @dev Override required for multiple inheritance (Ownable and ReentrancyGuard use Context)
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @dev Override required for multiple inheritance
    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @dev Override required for multiple inheritance
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
