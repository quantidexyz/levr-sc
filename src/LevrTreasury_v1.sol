// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';

contract LevrTreasury_v1 is ILevrTreasury_v1, ReentrancyGuard, ERC2771ContextBase {
    using SafeERC20 for IERC20;

    /// @notice Factory contract that deployed this treasury (immutable)
    address public immutable factory;

    /// @notice Underlying token managed by this treasury
    address public underlying;

    /// @notice Governor contract authorized to control treasury actions
    address public governor;

    constructor(address factory_, address trustedForwarder) ERC2771ContextBase(trustedForwarder) {
        if (factory_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        factory = factory_;
    }

    /// @inheritdoc ILevrTreasury_v1
    function initialize(address governor_, address underlying_) external override {
        if (governor != address(0)) revert ILevrTreasury_v1.AlreadyInitialized();
        if (_msgSender() != factory) revert ILevrTreasury_v1.OnlyFactory();
        if (governor_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        if (underlying_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();

        underlying = underlying_;
        governor = governor_;
        emit Initialized(underlying, governor_);
    }

    modifier onlyGovernor() {
        if (_msgSender() != governor) revert ILevrTreasury_v1.OnlyGovernor();
        _;
    }

    /// @inheritdoc ILevrTreasury_v1
    function transfer(
        address token,
        address to,
        uint256 amount
    ) external override nonReentrant onlyGovernor {
        if (token == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TransferExecuted(token, to, amount);
    }
}
