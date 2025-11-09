// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from './MockERC20.sol';

/**
 * @title Mock Clanker Token
 * @notice Mock token for testing that includes admin() function
 * @dev Extends MockERC20 to provide IClankerToken interface compatibility
 */
contract MockClankerToken is MockERC20 {
    address private _admin;

    constructor(string memory name, string memory symbol, address admin_) MockERC20(name, symbol) {
        _admin = admin_;
        // Mint initial supply to deployer (matching original MockClankerToken behavior)
        _mint(msg.sender, 1_000_000 ether);
    }

    /// @notice Get the admin address (IClankerToken interface)
    function admin() external view override returns (address) {
        return _admin;
    }

    /// @notice Update admin address (optional, for tests that need it)
    function setAdmin(address newAdmin) external {
        _admin = newAdmin;
    }

    /// @notice Get the token (for backward compatibility)
    /// @dev Returns self since this contract IS the token now
    function token() external view returns (MockERC20) {
        return MockERC20(address(this));
    }
}
