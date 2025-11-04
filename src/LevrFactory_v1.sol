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

import {LevrTreasury_v1} from './LevrTreasury_v1.sol';
import {LevrStaking_v1} from './LevrStaking_v1.sol';

contract LevrFactory_v1 is ILevrFactory_v1, Ownable, ReentrancyGuard, ERC2771Context {
    uint16 private _protocolFeeBps;
    uint32 private _streamWindowSeconds;
    address private _protocolTreasury;
    address public immutable levrDeployer; // LevrDeployer_v1 for delegatecall

    // Governance parameters
    uint32 private _proposalWindowSeconds;
    uint32 private _votingWindowSeconds;
    uint16 private _maxActiveProposals;
    uint16 private _quorumBps;
    uint16 private _approvalBps;
    uint16 private _minSTokenBpsToSubmit;
    uint16 private _maxProposalAmountBps;
    uint16 private _minimumQuorumBps;

    mapping(address => ILevrFactory_v1.Project) private _projects; // clankerToken => Project
    address[] private _projectTokens; // Array of all registered project tokens

    // Track prepared contracts by deployer
    mapping(address => ILevrFactory_v1.PreparedContracts) private _preparedContracts; // deployer => PreparedContracts

    // FIX [C-1]: Trusted Clanker factories for validation (supports multiple versions)
    address[] private _trustedClankerFactories;
    mapping(address => bool) private _isTrustedClankerFactory;

    // Verified projects config overrides
    mapping(address => ILevrFactory_v1.FactoryConfig) private _projectOverrideConfig; // clankerToken => override config

    // Initial whitelist for new projects (e.g., WETH - underlying is auto-whitelisted separately)
    address[] private _initialWhitelistedTokens;

    constructor(
        FactoryConfig memory cfg,
        address owner_,
        address trustedForwarder_,
        address levrDeployer_,
        address[] memory initialWhitelistedTokens_
    ) Ownable(owner_) ERC2771Context(trustedForwarder_) {
        _updateConfig(cfg, address(0), true);
        levrDeployer = levrDeployer_;

        // Store initial whitelist (will be passed to new projects)
        for (uint256 i = 0; i < initialWhitelistedTokens_.length; i++) {
            if (initialWhitelistedTokens_[i] == address(0)) revert ZeroAddress();
            _initialWhitelistedTokens.push(initialWhitelistedTokens_[i]);
        }
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
        if (_projects[clankerToken].staking != address(0)) revert AlreadyRegistered();

        address caller = _msgSender();
        if (IClankerToken(clankerToken).admin() != caller) revert UnauthorizedCaller();
        if (_trustedClankerFactories.length == 0) revert NoTrustedFactories();

        // Validate token from trusted Clanker factory
        bool validFactory;

        for (uint256 i; i < _trustedClankerFactories.length; ++i) {
            address factory = _trustedClankerFactories[i];

            try IClanker(factory).tokenDeploymentInfo(clankerToken) returns (
                IClanker.DeploymentInfo memory info
            ) {
                if (info.token == clankerToken) {
                    validFactory = true;
                    break;
                }
            } catch {}
        }

        if (!validFactory) revert TokenNotTrusted();

        // Look up and delete prepared contracts
        ILevrFactory_v1.PreparedContracts memory prepared = _preparedContracts[caller];
        delete _preparedContracts[caller];

        // Deploy via delegatecall
        (bool success, bytes memory returnData) = levrDeployer.delegatecall(
            abi.encodeWithSignature(
                'deployProject(address,address,address,address,address,address[])',
                clankerToken,
                prepared.treasury,
                prepared.staking,
                address(this),
                trustedForwarder(),
                _initialWhitelistedTokens
            )
        );
        if (!success) revert DeployFailed();

        project = abi.decode(returnData, (ILevrFactory_v1.Project));
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
        _updateConfig(cfg, address(0), true);
        emit ConfigUpdated();
    }

    /// @inheritdoc ILevrFactory_v1
    function verifyProject(address clankerToken) external override onlyOwner {
        Project storage p = _projects[clankerToken];
        if (p.staking == address(0)) revert ProjectNotFound();
        if (p.verified) revert AlreadyVerified();

        p.verified = true;
        _projectOverrideConfig[clankerToken] = _getCurrentFactoryConfig();

        emit ProjectVerified(clankerToken);
    }

    /// @inheritdoc ILevrFactory_v1
    function unverifyProject(address clankerToken) external override onlyOwner {
        Project storage p = _projects[clankerToken];
        if (p.staking == address(0)) revert ProjectNotFound();
        if (!p.verified) revert ProjectNotVerified();

        p.verified = false;
        delete _projectOverrideConfig[clankerToken];

        emit ProjectUnverified(clankerToken);
    }

    /// @inheritdoc ILevrFactory_v1
    function updateProjectConfig(
        address clankerToken,
        ProjectConfig calldata cfg
    ) external override {
        Project storage p = _projects[clankerToken];
        if (p.staking == address(0)) revert ProjectNotFound();
        if (!p.verified) revert ProjectNotVerified();
        if (IClankerToken(clankerToken).admin() != _msgSender()) revert UnauthorizedCaller();

        // Update project config (preserve protocol-level fields)
        _updateConfig(
            FactoryConfig(
                _protocolFeeBps,
                cfg.streamWindowSeconds,
                _protocolTreasury,
                cfg.proposalWindowSeconds,
                cfg.votingWindowSeconds,
                cfg.maxActiveProposals,
                cfg.quorumBps,
                cfg.approvalBps,
                cfg.minSTokenBpsToSubmit,
                cfg.maxProposalAmountBps,
                cfg.minimumQuorumBps
            ),
            clankerToken,
            false
        );

        emit ProjectConfigUpdated(clankerToken);
    }

    /// @inheritdoc ILevrFactory_v1
    function addTrustedClankerFactory(address factory) external override onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (_isTrustedClankerFactory[factory]) revert AlreadyTrusted();

        _trustedClankerFactories.push(factory);
        _isTrustedClankerFactory[factory] = true;

        emit TrustedClankerFactoryAdded(factory);
    }

    /// @inheritdoc ILevrFactory_v1
    function removeTrustedClankerFactory(address factory) external override onlyOwner {
        if (!_isTrustedClankerFactory[factory]) revert NotTrusted();

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
    function updateInitialWhitelist(address[] calldata tokens) external override onlyOwner {
        // Clear existing whitelist
        delete _initialWhitelistedTokens;

        // Set new whitelist
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            _initialWhitelistedTokens.push(tokens[i]);
        }

        emit InitialWhitelistUpdated(tokens);
    }

    /// @inheritdoc ILevrFactory_v1
    function getInitialWhitelist() external view override returns (address[] memory) {
        return _initialWhitelistedTokens;
    }

    /// @inheritdoc ILevrFactory_v1
    function getProjectContracts(
        address clankerToken
    ) external view override returns (ILevrFactory_v1.Project memory project) {
        return _projects[clankerToken];
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
        if (offset >= total) return (new ILevrFactory_v1.ProjectInfo[](0), total);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 length = end - offset;

        projects = new ILevrFactory_v1.ProjectInfo[](length);
        for (uint256 i = 0; i < length; i++) {
            address token = _projectTokens[offset + i];
            projects[i] = ILevrFactory_v1.ProjectInfo(token, _projects[token]);
        }
    }

    // Config getters - optional clankerToken parameter for project-specific config
    /// @inheritdoc ILevrFactory_v1
    function protocolFeeBps() external view override returns (uint16) {
        return _protocolFeeBps;
    }

    /// @inheritdoc ILevrFactory_v1
    function protocolTreasury() external view override returns (address) {
        return _protocolTreasury;
    }

    /// @inheritdoc ILevrFactory_v1
    function streamWindowSeconds(address c) external view override returns (uint32) {
        return
            _isVerified(c) ? _projectOverrideConfig[c].streamWindowSeconds : _streamWindowSeconds;
    }

    /// @inheritdoc ILevrFactory_v1
    function proposalWindowSeconds(address c) external view override returns (uint32) {
        return
            _isVerified(c)
                ? _projectOverrideConfig[c].proposalWindowSeconds
                : _proposalWindowSeconds;
    }

    /// @inheritdoc ILevrFactory_v1
    function votingWindowSeconds(address c) external view override returns (uint32) {
        return
            _isVerified(c) ? _projectOverrideConfig[c].votingWindowSeconds : _votingWindowSeconds;
    }

    /// @inheritdoc ILevrFactory_v1
    function maxActiveProposals(address c) external view override returns (uint16) {
        return _isVerified(c) ? _projectOverrideConfig[c].maxActiveProposals : _maxActiveProposals;
    }

    /// @inheritdoc ILevrFactory_v1
    function quorumBps(address c) external view override returns (uint16) {
        return _isVerified(c) ? _projectOverrideConfig[c].quorumBps : _quorumBps;
    }

    /// @inheritdoc ILevrFactory_v1
    function approvalBps(address c) external view override returns (uint16) {
        return _isVerified(c) ? _projectOverrideConfig[c].approvalBps : _approvalBps;
    }

    /// @inheritdoc ILevrFactory_v1
    function minSTokenBpsToSubmit(address c) external view override returns (uint16) {
        return
            _isVerified(c) ? _projectOverrideConfig[c].minSTokenBpsToSubmit : _minSTokenBpsToSubmit;
    }

    /// @inheritdoc ILevrFactory_v1
    function maxProposalAmountBps(address c) external view override returns (uint16) {
        return
            _isVerified(c) ? _projectOverrideConfig[c].maxProposalAmountBps : _maxProposalAmountBps;
    }

    /// @inheritdoc ILevrFactory_v1
    function minimumQuorumBps(address c) external view override returns (uint16) {
        return _isVerified(c) ? _projectOverrideConfig[c].minimumQuorumBps : _minimumQuorumBps;
    }

    /// @dev Check if project is verified
    function _isVerified(address c) private view returns (bool) {
        return c != address(0) && _projects[c].verified;
    }

    /// @dev Get current factory config as a struct
    function _getCurrentFactoryConfig() private view returns (FactoryConfig memory) {
        return
            FactoryConfig(
                _protocolFeeBps,
                _streamWindowSeconds,
                _protocolTreasury,
                _proposalWindowSeconds,
                _votingWindowSeconds,
                _maxActiveProposals,
                _quorumBps,
                _approvalBps,
                _minSTokenBpsToSubmit,
                _maxProposalAmountBps,
                _minimumQuorumBps
            );
    }

    /// @dev Unified config update function for both factory and project configs
    /// @param cfg Configuration to apply
    /// @param clankerToken Project token (address(0) for factory config)
    /// @param validateProtocolFee Whether to validate protocol fee (true for factory, false for project)
    function _updateConfig(
        FactoryConfig memory cfg,
        address clankerToken,
        bool validateProtocolFee
    ) private {
        // Validate config parameters
        _validateConfig(cfg, validateProtocolFee);

        // Get target config storage
        if (clankerToken == address(0)) {
            // Update factory default config (state variables)
            _protocolFeeBps = cfg.protocolFeeBps;
            _streamWindowSeconds = cfg.streamWindowSeconds;
            _protocolTreasury = cfg.protocolTreasury;
            _proposalWindowSeconds = cfg.proposalWindowSeconds;
            _votingWindowSeconds = cfg.votingWindowSeconds;
            _maxActiveProposals = cfg.maxActiveProposals;
            _quorumBps = cfg.quorumBps;
            _approvalBps = cfg.approvalBps;
            _minSTokenBpsToSubmit = cfg.minSTokenBpsToSubmit;
            _maxProposalAmountBps = cfg.maxProposalAmountBps;
            _minimumQuorumBps = cfg.minimumQuorumBps;
        } else {
            // Update project override config (mapping)
            _projectOverrideConfig[clankerToken] = cfg;
        }
    }

    /// @dev Validate config parameters
    function _validateConfig(FactoryConfig memory cfg, bool validateProtocolFee) private pure {
        // BPS values must be ? 100% (10000 basis points)
        if (
            cfg.quorumBps > 10000 ||
            cfg.approvalBps > 10000 ||
            cfg.minSTokenBpsToSubmit > 10000 ||
            cfg.maxProposalAmountBps > 10000 ||
            cfg.minimumQuorumBps > 10000
        ) revert InvalidConfig();

        if (validateProtocolFee && cfg.protocolFeeBps > 10000) revert InvalidConfig();

        // Prevent zero values that disable functionality
        if (
            cfg.maxActiveProposals == 0 ||
            cfg.proposalWindowSeconds == 0 ||
            cfg.votingWindowSeconds == 0 ||
            cfg.streamWindowSeconds == 0
        ) revert InvalidConfig();
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
