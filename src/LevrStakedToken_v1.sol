// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILevrStakedToken_v1} from "./interfaces/ILevrStakedToken_v1.sol";

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
        require(underlying_ != address(0) && staking_ != address(0), "ZERO");
        underlying = underlying_;
        staking = staking_;
        _decimals = decimals_;
    }

    /// @inheritdoc ILevrStakedToken_v1
    function mint(address to, uint256 amount) external override {
        require(msg.sender == staking, "ONLY_STAKING");
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function burn(address from, uint256 amount) external override {
        require(msg.sender == staking, "ONLY_STAKING");
        _burn(from, amount);
        emit Burn(from, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function decimals()
        public
        view
        override(ERC20, ILevrStakedToken_v1)
        returns (uint8)
    {
        return _decimals;
    }
}
