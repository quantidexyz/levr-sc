// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title LevrERC20 - Wrapper token for Levr protocol
/// @notice ERC20 token with controlled minting and burning for 1:1 peg to underlying assets
contract LevrERC20 is ERC20, AccessControl, ERC20Permit {
    /// @notice Role for addresses that can mint and burn tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role for addresses that can pause token transfers (if needed)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Whether transfers are paused
    bool public paused;

    /// @notice Underlying token whose metadata is proxied
    address public immutable underlying;

    /// @notice Emitted when token is paused
    event Paused(address account);

    /// @notice Emitted when token is unpaused
    event Unpaused(address account);

    /// @param name Token name
    /// @param symbol Token symbol
    /// @param underlying_ Underlying token to mirror metadata from
    /// @param defaultAdmin Address that gets DEFAULT_ADMIN_ROLE
    /// @param minter Address that gets MINTER_ROLE
    constructor(
        string memory name,
        string memory symbol,
        address underlying_,
        address defaultAdmin,
        address minter
    ) ERC20(name, symbol) ERC20Permit(name) {
        underlying = underlying_;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, minter);
        // Give deployer full operational control by default
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
    }

    /// @notice Mint tokens (only MINTER_ROLE)
    /// @param to Address to mint to
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn tokens from caller's balance (anyone can burn their own tokens)
    /// @param amount Amount to burn
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn tokens from a specific account (only MINTER_ROLE)
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burnFrom(
        address from,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    /// @notice Pause token transfers (only PAUSER_ROLE)
    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause token transfers (only PAUSER_ROLE)
    function unpause() external onlyRole(PAUSER_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Override transfer to check pause status
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (paused && from != address(0)) {
            revert("ERC20Pausable: token transfer while paused");
        }
        super._update(from, to, amount);
    }

    /// @notice Mirror underlying token metadata
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(underlying).decimals();
    }

    function name() public view override returns (string memory) {
        // Keep wrapper prefix while still reflecting underlying name context if needed
        // Returning the ERC20 stored name is typical; to fully proxy, you could concatenate.
        return super.name();
    }

    function symbol() public view override returns (string memory) {
        return super.symbol();
    }
}
