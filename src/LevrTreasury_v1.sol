// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILevrERC20} from "./interfaces/ILevrERC20.sol";
import {ILevrTreasury_v1} from "./interfaces/ILevrTreasury_v1.sol";
import {ILevrFactory_v1} from "./interfaces/ILevrFactory_v1.sol";

contract LevrTreasury_v1 is ILevrTreasury_v1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable underlying;
    address public immutable factory;
    address public governor;
    address public wrapper;

    uint256 private collectedFees;

    constructor(address underlying_, address factory_) {
        if (underlying_ == address(0) || factory_ == address(0))
            revert ILevrTreasury_v1.ZeroAddress();
        underlying = underlying_;
        factory = factory_;
    }

    function initialize(address governor_, address wrapper_) external {
        // one-time init by factory
        if (governor != address(0)) revert();
        if (msg.sender != factory) revert();
        if (governor_ == address(0) || wrapper_ == address(0))
            revert ILevrTreasury_v1.ZeroAddress();
        governor = governor_;
        wrapper = wrapper_;
        emit Initialized(underlying, governor_, wrapper_);
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert ILevrTreasury_v1.OnlyGovernor();
        _;
    }

    modifier onlyWrapper() {
        if (msg.sender != wrapper) revert ILevrTreasury_v1.OnlyWrapper();
        _;
    }

    /// @inheritdoc ILevrTreasury_v1
    function wrap(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 minted) {
        require(to != address(0), "TO_ZERO");
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

        (uint256 protocolFee, uint256 projectFee) = _calculateFees(amount);
        uint256 totalFee = protocolFee;
        if (projectFee > 0) {
            collectedFees += projectFee;
        }

        address protocolTreasury_ = ILevrFactory_v1(factory).protocolTreasury();
        if (protocolFee > 0 && protocolTreasury_ != address(0)) {
            IERC20(underlying).safeTransfer(
                protocolTreasury_,
                protocolFee - projectFee
            );
        }

        minted = amount - totalFee;
        ILevrERC20(wrapper).mint(to, minted);

        emit Wrapped(msg.sender, to, amount, minted, totalFee);
    }

    /// @inheritdoc ILevrTreasury_v1
    function unwrap(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 returned) {
        require(to != address(0), "TO_ZERO");
        ILevrERC20(wrapper).burn(msg.sender, amount);

        (uint256 protocolFee, uint256 projectFee) = _calculateFees(amount);
        uint256 totalFee = protocolFee;
        if (projectFee > 0) {
            collectedFees += projectFee;
        }

        address protocolTreasury_ = ILevrFactory_v1(factory).protocolTreasury();
        if (protocolFee > 0 && protocolTreasury_ != address(0)) {
            IERC20(underlying).safeTransfer(
                protocolTreasury_,
                protocolFee - projectFee
            );
        }

        returned = amount - totalFee;
        IERC20(underlying).safeTransfer(to, returned);

        emit Unwrapped(msg.sender, to, amount, returned, totalFee);
    }

    /// @inheritdoc ILevrTreasury_v1
    function transfer(address to, uint256 amount) external onlyGovernor {
        IERC20(underlying).safeTransfer(to, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function applyBoost(uint256 /* amount */) external onlyGovernor {
        // placeholder for future logic, effect tracked via events/governance in v1
    }

    /// @inheritdoc ILevrTreasury_v1
    function collectFees() external onlyGovernor {
        uint256 fees = collectedFees;
        if (fees == 0) return;
        collectedFees = 0;
        IERC20(underlying).safeTransfer(governor, fees);
        emit FeesCollected(fees);
    }

    /// @inheritdoc ILevrTreasury_v1
    function getUnderlyingBalance() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @inheritdoc ILevrTreasury_v1
    function getCollectedFees() external view returns (uint256) {
        return collectedFees;
    }

    function _calculateFees(
        uint256 amount
    ) internal view returns (uint256 protocolFee, uint256 projectFee) {
        uint16 protocolFeeBps = ILevrFactory_v1(factory).protocolFeeBps();
        uint16 projectShareBps = ILevrFactory_v1(factory)
            .projectFeeBpsOfProtocolFee();
        protocolFee = (amount * protocolFeeBps) / 10_000;
        projectFee = (protocolFee * projectShareBps) / 10_000;
    }
}
