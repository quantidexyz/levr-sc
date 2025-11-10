// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';

contract LevrStakedToken_v1 is ERC20, ILevrStakedToken_v1 {
    address public override underlying;
    address public override staking;
    uint8 private _decimalsValue;
    bool private _initialized;
    string private _tokenName;
    string private _tokenSymbol;
    address private immutable _deployer;

    constructor(address deployer_) ERC20('', '') {
        _deployer = deployer_;
    }

    /// @inheritdoc ILevrStakedToken_v1
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address underlying_,
        address staking_
    ) external {
        if (_initialized) revert ILevrStakedToken_v1.AlreadyInitialized();
        if (msg.sender != _deployer) revert ILevrStakedToken_v1.OnlyFactory();
        if (underlying_ == address(0) || staking_ == address(0))
            revert ILevrStakedToken_v1.ZeroAddress();

        _initialized = true;
        underlying = underlying_;
        staking = staking_;
        _decimalsValue = decimals_;
        _tokenName = name_;
        _tokenSymbol = symbol_;
    }

    /// @notice Override name to return initialized value
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @notice Override symbol to return initialized value
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @inheritdoc ILevrStakedToken_v1
    function mint(address to, uint256 amount) external override {
        if (msg.sender != staking) revert ILevrStakedToken_v1.OnlyFactory();
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function burn(address from, uint256 amount) external override {
        if (msg.sender != staking) revert ILevrStakedToken_v1.OnlyFactory();
        _burn(from, amount);
        emit Burn(from, amount);
    }

    /// @inheritdoc ILevrStakedToken_v1
    function decimals() public view override(ERC20, ILevrStakedToken_v1) returns (uint8) {
        return _decimalsValue;
    }

    /// @notice Block transfers (staked tokens are non-transferable positions)
    /// @dev Allows mint/burn only - transfers would break VP and reward accounting
    function _update(address from, address to, uint256 value) internal override {
        if (!(from == address(0) || to == address(0)))
            revert ILevrStakedToken_v1.CannotModifyUnderlying();
        super._update(from, to, value);
    }
}
