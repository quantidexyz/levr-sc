// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ILevrERC20} from "./interfaces/ILevrERC20.sol";

contract LevrERC20 is ERC20, ILevrERC20 {
    address public immutable treasury;
    address private immutable _underlying;
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address underlying_,
        address treasury_
    ) ERC20(name_, symbol_) {
        require(underlying_ != address(0), "UNDERLYING_ZERO");
        require(treasury_ != address(0), "TREASURY_ZERO");
        _underlying = underlying_;
        treasury = treasury_;
        _decimals = decimals_;
    }

    /// @inheritdoc ILevrERC20
    function mint(address to, uint256 amount) external override {
        require(msg.sender == treasury, "ONLY_TREASURY");
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @inheritdoc ILevrERC20
    function burn(address from, uint256 amount) external override {
        require(msg.sender == treasury, "ONLY_TREASURY");
        _burn(from, amount);
        emit Burn(from, amount);
    }

    /// @inheritdoc ILevrERC20
    function decimals()
        public
        view
        override(ERC20, ILevrERC20)
        returns (uint8)
    {
        return _decimals;
    }

    /// @inheritdoc ILevrERC20
    function underlying() external view override returns (address) {
        return _underlying;
    }
}
