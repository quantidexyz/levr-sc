// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20_Mock} from './ERC20_Mock.sol';

/**
 * @title Clanker Token Mock
 * @notice Mock token for testing that includes admin() function
 * @dev Extends ERC20_Mock to provide IClankerToken interface compatibility
 */
contract ClankerToken_Mock is ERC20_Mock {
    address private _admin;

    constructor(string memory name, string memory symbol, address admin_) ERC20_Mock(name, symbol) {
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
    function token() external view returns (ERC20_Mock) {
        return ERC20_Mock(address(this));
    }
}
