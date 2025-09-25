// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILevrTreasury_v1} from "./interfaces/ILevrTreasury_v1.sol";
import {ILevrFactory_v1} from "./interfaces/ILevrFactory_v1.sol";

contract LevrTreasury_v1 is ILevrTreasury_v1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable underlying;
    address public immutable factory;
    address public governor;

    // no project fees; only protocol fees apply
    // no staking/reward state in treasury in the new model

    constructor(address underlying_, address factory_) {
        if (underlying_ == address(0) || factory_ == address(0))
            revert ILevrTreasury_v1.ZeroAddress();
        underlying = underlying_;
        factory = factory_;
    }

    function initialize(address governor_, address /* unused */) external {
        // one-time init by factory
        if (governor != address(0)) revert();
        if (msg.sender != factory) revert();
        if (governor_ == address(0)) revert ILevrTreasury_v1.ZeroAddress();
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

    function transfer(address to, uint256 amount) external onlyGovernor {
        IERC20(underlying).safeTransfer(to, amount);
    }

    // boosts moved to staking module

    function getUnderlyingBalance() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    // project fee collection removed

    // staking moved to staking module

    // staking moved to staking module

    // no staking views in treasury

    // no staking views in treasury
    // no staking views in treasury

    // rewards moved to staking module

    // no internal reward logic in treasury

    function _calculateProtocolFee(
        uint256 amount
    ) internal view returns (uint256 protocolFee) {
        uint16 protocolFeeBps = ILevrFactory_v1(factory).protocolFeeBps();
        protocolFee = (amount * protocolFeeBps) / 10_000;
    }
}
