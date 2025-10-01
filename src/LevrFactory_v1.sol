// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
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

  uint256[] private _transferTiers;
  uint256[] private _stakingBoostTiers;

  mapping(address => ILevrFactory_v1.Project) private _projects; // clankerToken => Project

  constructor(FactoryConfig memory cfg, address owner_) Ownable(owner_) {
    _applyConfig(cfg);
  }

  /// @inheritdoc ILevrFactory_v1
  function register(
    address clankerToken
  ) external override returns (address treasury, address governor, address staking, address stakedToken) {
    Project storage p = _projects[clankerToken];
    require(p.staking == address(0), 'ALREADY_REGISTERED');

    // Only token admin can register
    address tokenAdmin = IClankerToken(clankerToken).admin();
    if (msg.sender != tokenAdmin) {
      revert UnauthorizedCaller();
    }

    return _deployProject(clankerToken, msg.sender);
  }

  /// @inheritdoc ILevrFactory_v1
  function registerDryRun(
    address clankerToken
  ) external view override returns (address treasury, address governor, address staking, address stakedToken) {
    // Query token metadata for accurate address prediction
    uint8 uDec = IERC20Metadata(clankerToken).decimals();
    string memory tokenName = IERC20Metadata(clankerToken).name();
    string memory tokenSymbol = IERC20Metadata(clankerToken).symbol();
    address tokenAdmin = IClankerToken(clankerToken).admin();

    // Compute predicted addresses using CREATE2 with clankerToken as salt
    // These addresses are deterministic and can be predicted at any time
    bytes32 salt = bytes32(uint256(uint160(clankerToken)));

    // Treasury uses actual tokenAdmin (will be msg.sender in actual register call)
    // Note: This means prediction is only accurate if called by the tokenAdmin
    treasury = _computeCreate2Address(salt, type(LevrTreasury_v1).creationCode, abi.encode(address(this), tokenAdmin));

    staking = _computeCreate2Address(salt, type(LevrStaking_v1).creationCode, bytes(''));

    // For stakedToken, use actual metadata
    string memory name_ = string(abi.encodePacked('Levr Staked ', tokenName));
    string memory symbol_ = string(abi.encodePacked('s', tokenSymbol));
    bytes32 stakedTokenSalt = keccak256(abi.encodePacked(salt, 'stakedToken'));
    stakedToken = _computeCreate2Address(
      stakedTokenSalt,
      type(LevrStakedToken_v1).creationCode,
      abi.encode(name_, symbol_, uDec, clankerToken, staking)
    );

    // Governor uses another sub-salt
    bytes32 governorSalt = keccak256(abi.encodePacked(salt, 'governor'));
    governor = _computeCreate2Address(
      governorSalt,
      type(LevrGovernor_v1).creationCode,
      abi.encode(address(this), treasury, stakedToken)
    );
  }

  function _deployProject(
    address clankerToken,
    address tokenAdmin
  ) internal returns (address treasury, address governor, address staking, address stakedToken) {
    bytes32 salt = bytes32(uint256(uint160(clankerToken)));

    // Deploy treasury with CREATE2
    treasury = address(new LevrTreasury_v1{salt: salt}(address(this), tokenAdmin));

    // Deploy staking with CREATE2
    staking = address(new LevrStaking_v1{salt: salt}());

    // Deploy stakedToken with CREATE2 using sub-salt
    uint8 uDec = IERC20Metadata(clankerToken).decimals();
    string memory name_ = string(abi.encodePacked('Levr Staked ', IERC20Metadata(clankerToken).name()));
    string memory symbol_ = string(abi.encodePacked('s', IERC20Metadata(clankerToken).symbol()));
    bytes32 stakedTokenSalt = keccak256(abi.encodePacked(salt, 'stakedToken'));
    stakedToken = address(new LevrStakedToken_v1{salt: stakedTokenSalt}(name_, symbol_, uDec, clankerToken, staking));

    // Initialize staking
    LevrStaking_v1(staking).initialize(clankerToken, stakedToken, treasury);

    // Deploy governor with CREATE2 using sub-salt
    bytes32 governorSalt = keccak256(abi.encodePacked(salt, 'governor'));
    governor = address(new LevrGovernor_v1{salt: governorSalt}(address(this), treasury, stakedToken));

    // Initialize treasury now that governor and underlying are known
    LevrTreasury_v1(treasury).initialize(governor, clankerToken);

    Project storage p = _projects[clankerToken];
    p.treasury = treasury;
    p.governor = governor;
    p.staking = staking;
    p.stakedToken = stakedToken;

    emit Registered(clankerToken, treasury, governor, stakedToken);
  }

  function _computeCreate2Address(
    bytes32 salt,
    bytes memory bytecode,
    bytes memory constructorArgs
  ) internal view returns (address) {
    bytes32 bytecodeHash = keccak256(abi.encodePacked(bytecode, constructorArgs));
    bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash));
    return address(uint160(uint256(hash)));
  }

  /// @inheritdoc ILevrFactory_v1
  function updateConfig(FactoryConfig calldata cfg) external override onlyOwner {
    _applyConfig(cfg);
    emit ConfigUpdated();
  }

  /// @inheritdoc ILevrFactory_v1
  function getProjectContracts(
    address clankerToken
  ) external view override returns (address treasury, address governor, address staking, address stakedToken) {
    Project storage p = _projects[clankerToken];
    return (p.treasury, p.governor, p.staking, p.stakedToken);
  }

  /// @inheritdoc ILevrFactory_v1
  function getTransferTierCount() external view override returns (uint256) {
    return _transferTiers.length;
  }

  /// @inheritdoc ILevrFactory_v1
  function getTransferTier(uint256 index) external view override returns (uint256) {
    return _transferTiers[index];
  }

  /// @inheritdoc ILevrFactory_v1
  function getStakingBoostTierCount() external view override returns (uint256) {
    return _stakingBoostTiers.length;
  }

  /// @inheritdoc ILevrFactory_v1
  function getStakingBoostTier(uint256 index) external view override returns (uint256) {
    return _stakingBoostTiers[index];
  }

  function _applyConfig(FactoryConfig memory cfg) internal {
    protocolFeeBps = cfg.protocolFeeBps;
    submissionDeadlineSeconds = cfg.submissionDeadlineSeconds;
    streamWindowSeconds = cfg.streamWindowSeconds;
    maxSubmissionPerType = cfg.maxSubmissionPerType;
    minWTokenToSubmit = cfg.minWTokenToSubmit;
    protocolTreasury = cfg.protocolTreasury;

    delete _transferTiers;
    delete _stakingBoostTiers;
    uint256 i;
    for (i = 0; i < cfg.transferTiers.length; i++) {
      _transferTiers.push(cfg.transferTiers[i].value);
    }
    for (i = 0; i < cfg.stakingBoostTiers.length; i++) {
      _stakingBoostTiers.push(cfg.stakingBoostTiers[i].value);
    }
  }
}
