// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';

contract LevrStakedToken_v1 is ERC20, ILevrStakedToken_v1 {
    address public immutable override underlying;
    address public immutable override staking;
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address underlying_,
        address staking_
    ) ERC20(name_, symbol_) {
        if (underlying_ == address(0) || staking_ == address(0)) revert ZeroAddress();

        underlying = underlying_;
        staking = staking_;
        _decimals = decimals_;
    }

    /// @inheritdoc ILevrStakedToken_v1
    function mint(address to, uint256 amount) external override {
        if (msg.sender != staking) revert OnlyStaking();
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function burn(address from, uint256 amount) external override {
        if (msg.sender != staking) revert OnlyStaking();
        _burn(from, amount);
        emit Burn(from, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function decimals() public view override(ERC20, ILevrStakedToken_v1) returns (uint8) {
        return _decimals;
    }

    /// @notice Block transfers (staked tokens are non-transferable positions)
    /// @dev Allows mint/burn only - transfers would break VP and reward accounting
    function _update(address from, address to, uint256 value) internal override {
        if (!(from == address(0) || to == address(0))) revert CannotModifyUnderlying();
        super._update(from, to, value);
    }
}
