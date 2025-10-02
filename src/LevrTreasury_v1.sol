// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';

contract LevrTreasury_v1 is ILevrTreasury_v1, ReentrancyGuard {
  using SafeERC20 for IERC20;

  address public underlying;
  address public immutable factory;
  address public governor;

  // no project fees; only protocol fees apply
  // no staking/reward state in treasury in the new model

  constructor(address factory_) {
    if (factory_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
    factory = factory_;
  }

  function initialize(address governor_, address underlying_) external {
    // one-time init by factory
    if (governor != address(0)) revert();
    if (msg.sender != factory) revert();
    if (governor_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
    if (underlying == address(0)) {
      if (underlying_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
      underlying = underlying_;
    }
    governor = governor_;
    emit Initialized(underlying, governor_, address(0));
  }

  modifier onlyGovernor() {
    if (msg.sender != governor) revert ILevrTreasury_v1.OnlyGovernor();
    _;
  }

  // no wrapper in the new model

  // no wrap in the new model

  // no unwrap in the new model

  function transfer(address to, uint256 amount) external onlyGovernor nonReentrant {
    IERC20(underlying).safeTransfer(to, amount);
  }

  /// @inheritdoc ILevrTreasury_v1
  function applyBoost(uint256 amount) external onlyGovernor nonReentrant {
    if (amount == 0) revert ILevrTreasury_v1.InvalidAmount();
    // move underlying from treasury to staking and accrue
    ILevrFactory_v1.Project memory project = ILevrFactory_v1(factory).getProjectContracts(underlying);
    // approve and pull via accrueFromTreasury for atomicity
    IERC20(underlying).approve(project.staking, amount);
    ILevrStaking_v1(project.staking).accrueFromTreasury(underlying, amount, true);
  }

  function getUnderlyingBalance() external view returns (uint256) {
    return IERC20(underlying).balanceOf(address(this));
  }

  function _calculateProtocolFee(uint256 amount) internal view returns (uint256 protocolFee) {
    uint16 protocolFeeBps = ILevrFactory_v1(factory).protocolFeeBps();
    protocolFee = (amount * protocolFeeBps) / 10_000;
  }
}
