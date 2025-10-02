// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';

import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {IClankerToken} from './interfaces/external/IClankerToken.sol';

import {LevrTreasury_v1} from './LevrTreasury_v1.sol';
import {LevrGovernor_v1} from './LevrGovernor_v1.sol';
import {LevrStaking_v1} from './LevrStaking_v1.sol';
import {LevrStakedToken_v1} from './LevrStakedToken_v1.sol';

contract LevrFactory_v1 is ILevrFactory_v1, Ownable {
  uint16 public override protocolFeeBps;
  uint32 public override submissionDeadlineSeconds;
  uint32 public override streamWindowSeconds;
  uint16 public override maxSubmissionPerType; // reserved for future rate limits
  uint256 public override minWTokenToSubmit;
  address public override protocolTreasury;
  address public override trustedForwarder; // immutable forwarder deployed in constructor

  mapping(address => ILevrFactory_v1.Project) private _projects; // clankerToken => Project

  // Track prepared contracts by deployer
  mapping(address => ILevrFactory_v1.PreparedContracts) private _preparedContracts; // deployer => PreparedContracts

  constructor(FactoryConfig memory cfg, address owner_) Ownable(owner_) {
    // Deploy OpenZeppelin ERC2771Forwarder
    trustedForwarder = address(new ERC2771Forwarder('LevrForwarder'));
    _applyConfig(cfg);
  }

  /// @inheritdoc ILevrFactory_v1
  function prepareForDeployment() external override returns (address treasury, address staking) {
    // Deploy treasury and staking without salt - each call creates independent contracts
    treasury = address(new LevrTreasury_v1(address(this), trustedForwarder));

    // Deploy staking (will be initialized later during register)
    staking = address(new LevrStaking_v1(trustedForwarder));

    // Store prepared contracts for this deployer (overwrites previous if called again)
    _preparedContracts[msg.sender] = ILevrFactory_v1.PreparedContracts({treasury: treasury, staking: staking});

    emit PreparationComplete(msg.sender, treasury, staking);
  }

  /// @inheritdoc ILevrFactory_v1
  function register(address clankerToken) external override returns (ILevrFactory_v1.Project memory project) {
    Project storage p = _projects[clankerToken];
    require(p.staking == address(0), 'ALREADY_REGISTERED');

    // Only token admin can register
    address tokenAdmin = IClankerToken(clankerToken).admin();
    if (msg.sender != tokenAdmin) {
      revert UnauthorizedCaller();
    }

    // Look up prepared contracts for this caller
    ILevrFactory_v1.PreparedContracts memory prepared = _preparedContracts[msg.sender];

    return _deployProject(clankerToken, prepared.treasury, prepared.staking);
  }

  function _deployProject(
    address clankerToken,
    address treasury_,
    address staking_
  ) internal returns (ILevrFactory_v1.Project memory project) {
    // Use provided treasury or deploy new one
    if (treasury_ != address(0)) {
      project.treasury = treasury_;
    } else {
      project.treasury = address(new LevrTreasury_v1(address(this), trustedForwarder));
    }

    // Use provided staking or deploy new one
    if (staking_ != address(0)) {
      project.staking = staking_;
    } else {
      project.staking = address(new LevrStaking_v1(trustedForwarder));
    }

    // Deploy stakedToken
    uint8 uDec = IERC20Metadata(clankerToken).decimals();
    string memory name_ = string(abi.encodePacked('Levr Staked ', IERC20Metadata(clankerToken).name()));
    string memory symbol_ = string(abi.encodePacked('s', IERC20Metadata(clankerToken).symbol()));
    project.stakedToken = address(new LevrStakedToken_v1(name_, symbol_, uDec, clankerToken, project.staking));

    // Initialize staking
    LevrStaking_v1(project.staking).initialize(clankerToken, project.stakedToken, project.treasury);

    // Deploy governor
    project.governor = address(
      new LevrGovernor_v1(address(this), project.treasury, project.stakedToken, trustedForwarder)
    );

    // Initialize treasury now that governor and underlying are known
    LevrTreasury_v1(project.treasury).initialize(project.governor, clankerToken);

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

  function _applyConfig(FactoryConfig memory cfg) internal {
    protocolFeeBps = cfg.protocolFeeBps;
    submissionDeadlineSeconds = cfg.submissionDeadlineSeconds;
    streamWindowSeconds = cfg.streamWindowSeconds;
    maxSubmissionPerType = cfg.maxSubmissionPerType;
    minWTokenToSubmit = cfg.minWTokenToSubmit;
    protocolTreasury = cfg.protocolTreasury;
    // Note: trustedForwarder is immutable and set in constructor
  }
}
