// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from './MockERC20.sol';

/**
 * @title Mock Clanker Token
 * @notice Mock token wrapper for testing that tracks admin address
 * @dev Wraps MockERC20 to provide IClankerToken interface compatibility
 */
contract MockClankerToken {
    address private _admin;
    MockERC20 public token;

    constructor(string memory name, string memory symbol, address admin_) {
        _admin = admin_;
        token = new MockERC20(name, symbol);
        // Mint initial supply to deployer (matching original MockClankerToken behavior)
        token.mint(msg.sender, 1_000_000 ether);
    }

    /// @notice Get the admin address (IClankerToken interface)
    function admin() external view returns (address) {
        return _admin;
    }

    /// @notice Update admin address (optional, for tests that need it)
    function setAdmin(address newAdmin) external {
        _admin = newAdmin;
    }
}
