// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';

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
        require(underlying_ != address(0) && staking_ != address(0), 'ZERO');
        underlying = underlying_;
        staking = staking_;
        _decimals = decimals_;
    }

    /// @inheritdoc ILevrStakedToken_v1
    function mint(address to, uint256 amount) external override {
        require(msg.sender == staking, 'ONLY_STAKING');
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function burn(address from, uint256 amount) external override {
        require(msg.sender == staking, 'ONLY_STAKING');
        _burn(from, amount);
        emit Burn(from, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function decimals() public view override(ERC20, ILevrStakedToken_v1) returns (uint8) {
        return _decimals;
    }

    /// @notice Override _update to handle transfers with Balance-Based Design
    /// @dev Called on mint, burn, and transfer operations
    ///      For transfers between users: settles rewards and recalculates VP
    ///      Sender's VP scales with balance (like unstaking)
    ///      Receiver's VP is weighted average (like staking)
    function _update(address from, address to, uint256 value) internal override {
        // Allow minting and burning normally (mint: from=0, burn: to=0)
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // For transfers between users: single callback BEFORE transfer
        // This callback settles rewards with BEFORE-transfer balances and updates VP
        if (staking != address(0)) {
            try ILevrStaking_v1(staking).onTokenTransfer(from, to, value) {} catch {}
        }

        // Execute the transfer via parent
        super._update(from, to, value);
    }
}
