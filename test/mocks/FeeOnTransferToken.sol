// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @notice Simple ERC20 that burns a fee on every transfer/transferFrom.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps; // Fee in basis points (100 = 1%)
    address private immutable _admin;

    constructor(string memory name, string memory symbol, uint256 feeBps_) ERC20(name, symbol) {
        feeBps = feeBps_;
        _admin = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function admin() external view returns (address) {
        return _admin;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _applyFee(_msgSender(), amount);
        return super.transfer(to, amount - _fee(amount));
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _applyFee(from, amount);
        _transfer(from, to, amount - _fee(amount));

        uint256 currentAllowance = allowance(from, _msgSender());
        require(currentAllowance >= amount, 'ERC20: insufficient allowance');
        _approve(from, _msgSender(), currentAllowance - amount);
        return true;
    }

    function _applyFee(address from, uint256 amount) internal {
        uint256 fee = _fee(amount);
        if (fee > 0) _burn(from, fee);
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return (amount * feeBps) / 10_000;
    }
}
