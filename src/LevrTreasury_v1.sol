// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';

contract LevrTreasury_v1 is ILevrTreasury_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    address public underlying;
    address public immutable factory;
    address public governor;

    constructor(address factory_, address trustedForwarder) ERC2771ContextBase(trustedForwarder) {
        if (factory_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        factory = factory_;
    }

    function initialize(address governor_, address underlying_) external {
        // one-time init by factory
        if (governor != address(0)) revert();
        if (_msgSender() != factory) revert();
        if (governor_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        if (underlying == address(0)) {
            if (underlying_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
            underlying = underlying_;
        }
        governor = governor_;
        emit Initialized(underlying, governor_);
    }

    modifier onlyGovernor() {
        if (_msgSender() != governor) revert ILevrTreasury_v1.OnlyGovernor();
        _;
    }

    function transfer(address to, uint256 amount) external onlyGovernor nonReentrant {
        IERC20(underlying).safeTransfer(to, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function applyBoost(uint256 amount) external onlyGovernor nonReentrant {
        if (amount == 0) revert ILevrTreasury_v1.InvalidAmount();
        // move underlying from treasury to staking and accrue
        ILevrFactory_v1.Project memory project = ILevrFactory_v1(factory).getProjectContracts(
            underlying
        );
        // approve and pull via accrueFromTreasury for atomicity
        IERC20(underlying).approve(project.staking, amount);
        ILevrStaking_v1(project.staking).accrueFromTreasury(underlying, amount, true);

        // HIGH FIX [H-3]: Reset approval to 0 after to prevent unlimited approval vulnerability
        IERC20(underlying).approve(project.staking, 0);
    }

    function getUnderlyingBalance() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @inheritdoc ILevrTreasury_v1
    function staking() external view returns (address) {
        ILevrFactory_v1.Project memory project = ILevrFactory_v1(factory).getProjectContracts(
            underlying
        );
        return project.staking;
    }

    function _calculateProtocolFee(uint256 amount) internal view returns (uint256 protocolFee) {
        uint16 protocolFeeBps = ILevrFactory_v1(factory).protocolFeeBps();
        protocolFee = (amount * protocolFeeBps) / 10_000;
    }
}
