// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    address public immutable levrDeployer; // LevrDeployer_v1 for delegatecall

    // Governance parameters
    uint32 public override proposalWindowSeconds;
    uint32 public override votingWindowSeconds;
    uint16 public override maxActiveProposals;
    uint16 public override quorumBps;
    uint16 public override approvalBps;
    uint16 public override minSTokenBpsToSubmit;
    uint16 public override maxProposalAmountBps;
    uint16 public override minimumQuorumBps;

    // Staking parameters
    uint16 public override maxRewardTokens;

    mapping(address => ILevrFactory_v1.Project) private _projects; // clankerToken => Project
    address[] private _projectTokens; // Array of all registered project tokens

    // Track prepared contracts by deployer
    mapping(address => ILevrFactory_v1.PreparedContracts) private _preparedContracts; // deployer => PreparedContracts

    // FIX [C-1]: Trusted Clanker factories for validation (supports multiple versions)
    address[] private _trustedClankerFactories;
    mapping(address => bool) private _isTrustedClankerFactory;

    constructor(
        FactoryConfig memory cfg,
        address owner_,
        address trustedForwarder_,
        address clankerFactory_,
        address levrDeployer_
    ) Ownable(owner_) ERC2771Context(trustedForwarder_) {
        _applyConfig(cfg);
        clankerFactory = clankerFactory_;
        levrDeployer = levrDeployer_;
    }

    /// @inheritdoc ILevrFactory_v1
    function prepareForDeployment() external override returns (address treasury, address staking) {
        address deployer = _msgSender();

        treasury = address(new LevrTreasury_v1(address(this), trustedForwarder()));
        staking = address(new LevrStaking_v1(trustedForwarder()));

        _preparedContracts[deployer] = ILevrFactory_v1.PreparedContracts({
            treasury: treasury,
            staking: staking
        });

        emit PreparationComplete(deployer, treasury, staking);
    }

    /// @inheritdoc ILevrFactory_v1
    function register(
        address clankerToken
    ) external override nonReentrant returns (ILevrFactory_v1.Project memory project) {
        Project storage p = _projects[clankerToken];
        require(p.staking == address(0), 'ALREADY_REGISTERED');

        address caller = _msgSender();

        // Only token admin can register
        address tokenAdmin = IClankerToken(clankerToken).admin();
        if (caller != tokenAdmin) {
            revert UnauthorizedCaller();
        }

        // FIX [C-1]: Validate token is from a trusted Clanker factory
        if (_trustedClankerFactories.length > 0) {
            bool validFactory = false;

            // Check each trusted factory
            for (uint256 i = 0; i < _trustedClankerFactories.length; i++) {
                address factory = _trustedClankerFactories[i];

                // Call factory to verify this token was deployed by it
                try IClanker(factory).tokenDeploymentInfo(clankerToken) returns (
                    IClanker.DeploymentInfo memory info
                ) {
                    // If call succeeds and token matches, this is valid
                    if (info.token == clankerToken) {
                        validFactory = true;
                        break;
                    }
                } catch {
                    // Factory doesn't know this token, try next factory
                    continue;
                }
            }

            require(validFactory, 'TOKEN_NOT_FROM_TRUSTED_FACTORY');
        }

        // Look up prepared contracts for this caller
        ILevrFactory_v1.PreparedContracts memory prepared = _preparedContracts[caller];

        // Delete prepared contracts to prevent reuse across multiple registrations
        delete _preparedContracts[caller];

        // Deploy all contracts via delegatecall to deployer logic
        bytes memory data = abi.encodeWithSignature(
            'deployProject(address,address,address,address,address)',
            clankerToken,
            prepared.treasury,
            prepared.staking,
            address(this),
            trustedForwarder()
        );

        (bool success, bytes memory returnData) = levrDeployer.delegatecall(data);
        require(success, 'DEPLOY_FAILED');

        project = abi.decode(returnData, (ILevrFactory_v1.Project));

        // Store in registry
        _projects[clankerToken] = project;
        _projectTokens.push(clankerToken);

        emit Registered(
            clankerToken,
            project.treasury,
            project.governor,
            project.staking,
            project.stakedToken
        );
    }

    /// @inheritdoc ILevrFactory_v1
    function updateConfig(FactoryConfig calldata cfg) external override onlyOwner {
        _applyConfig(cfg);
        emit ConfigUpdated();
    }

    /// @inheritdoc ILevrFactory_v1
    function addTrustedClankerFactory(address factory) external override onlyOwner {
        require(factory != address(0), 'ZERO_ADDRESS');
        require(!_isTrustedClankerFactory[factory], 'ALREADY_TRUSTED');

        _trustedClankerFactories.push(factory);
        _isTrustedClankerFactory[factory] = true;

        emit TrustedClankerFactoryAdded(factory);
    }

    /// @inheritdoc ILevrFactory_v1
    function removeTrustedClankerFactory(address factory) external override onlyOwner {
        require(_isTrustedClankerFactory[factory], 'NOT_TRUSTED');

        _isTrustedClankerFactory[factory] = false;

        // Remove from array (swap with last element)
        uint256 length = _trustedClankerFactories.length;
        for (uint256 i = 0; i < length; i++) {
            if (_trustedClankerFactories[i] == factory) {
                _trustedClankerFactories[i] = _trustedClankerFactories[length - 1];
                _trustedClankerFactories.pop();
                break;
            }
        }

        emit TrustedClankerFactoryRemoved(factory);
    }

    /// @inheritdoc ILevrFactory_v1
    function getTrustedClankerFactories() external view override returns (address[] memory) {
        return _trustedClankerFactories;
    }

    /// @inheritdoc ILevrFactory_v1
    function isTrustedClankerFactory(address factory) external view override returns (bool) {
        return _isTrustedClankerFactory[factory];
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

    /// @inheritdoc ILevrFactory_v1
    function getProjects(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total)
    {
        total = _projectTokens.length;

        // Handle bounds
        if (offset >= total) {
            return (new ILevrFactory_v1.ProjectInfo[](0), total);
        }

        // Calculate actual length
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        uint256 length = end - offset;

        // Build result array
        projects = new ILevrFactory_v1.ProjectInfo[](length);
        for (uint256 i = 0; i < length; i++) {
            address token = _projectTokens[offset + i];
            projects[i] = ILevrFactory_v1.ProjectInfo({
                clankerToken: token,
                project: _projects[token]
            });
        }

        return (projects, total);
    }

    function _applyConfig(FactoryConfig memory cfg) internal {
        // FIX [CONFIG-GRIDLOCK]: Validate BPS values are <= 100% (10000 basis points)
        // Prevents permanent gridlocks from impossible quorum/approval requirements
        require(cfg.quorumBps <= 10000, 'INVALID_QUORUM_BPS');
        require(cfg.approvalBps <= 10000, 'INVALID_APPROVAL_BPS');
        require(cfg.minSTokenBpsToSubmit <= 10000, 'INVALID_MIN_STAKE_BPS');
        require(cfg.maxProposalAmountBps <= 10000, 'INVALID_MAX_PROPOSAL_BPS');
        require(cfg.protocolFeeBps <= 10000, 'INVALID_PROTOCOL_FEE_BPS');
        require(cfg.minimumQuorumBps <= 10000, 'INVALID_MINIMUM_QUORUM_BPS');

        // FIX [CONFIG-GRIDLOCK]: Prevent zero values that freeze functionality
        require(cfg.maxActiveProposals > 0, 'MAX_ACTIVE_PROPOSALS_ZERO');
        require(cfg.maxRewardTokens > 0, 'MAX_REWARD_TOKENS_ZERO');
        require(cfg.proposalWindowSeconds > 0, 'PROPOSAL_WINDOW_ZERO');
        require(cfg.votingWindowSeconds > 0, 'VOTING_WINDOW_ZERO');

        // Existing validation
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
        maxProposalAmountBps = cfg.maxProposalAmountBps;
        minimumQuorumBps = cfg.minimumQuorumBps;
        maxRewardTokens = cfg.maxRewardTokens;
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
