// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract ERC20_Mock is ERC20 {
  address private immutable _admin;

  constructor(string memory name, string memory symbol) ERC20(name, symbol) {
    _admin = msg.sender;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external {
    _burn(from, amount);
  }

  /// @notice Mock admin function to support IClankerToken interface
  function admin() external view virtual returns (address) {
    return _admin;
  }
}
