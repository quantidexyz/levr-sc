// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IClanker} from '../../src/interfaces/external/IClanker.sol';
import {ERC20_Mock} from './ERC20_Mock.sol';

/// @notice Mock Clanker Token that implements both IClankerToken and ERC20
/// @dev Standalone implementation to properly set admin
contract ClankerTokenForTest_Mock is ERC20_Mock {
    address private immutable _tokenAdmin;

    constructor(string memory name, string memory symbol, address admin_) ERC20_Mock(name, symbol) {
        _tokenAdmin = admin_;
        // Mint initial supply to admin
        _mint(admin_, 1_000_000 ether);
    }

    /// @notice Override admin() to return the correct admin
    function admin() external view override returns (address) {
        return _tokenAdmin;
    }
}

/// @notice Mock Clanker Factory for testing
/// @dev Simulates Clanker factory for unit tests
contract ClankerFactory_Mock {
    string public version;
    mapping(address => IClanker.DeploymentInfo) private _deploymentInfo;
    mapping(address => bool) private _isRegistered;
    bool public permissiveMode = true; // Accept any token by default

    constructor() {
        version = 'test';
    }

    /// @notice Enable/disable permissive mode
    /// @dev In permissive mode, any token query returns valid deployment info
    function setPermissiveMode(bool enabled) external {
        permissiveMode = enabled;
    }

    /// @notice Deploy a mock Clanker token
    function deployToken(
        address admin,
        string memory name,
        string memory symbol
    ) external returns (ClankerTokenForTest_Mock) {
        ClankerTokenForTest_Mock token = new ClankerTokenForTest_Mock(name, symbol, admin);

        _deploymentInfo[address(token)] = IClanker.DeploymentInfo({
            token: address(token),
            hook: address(0),
            locker: address(0),
            extensions: new address[](0)
        });
        _isRegistered[address(token)] = true;

        return token;
    }

    /// @notice Register an existing token (for testing with ERC20_Mock)
    /// @dev Allows tests to register tokens that weren't deployed by this factory
    function registerToken(address token) external {
        _deploymentInfo[token] = IClanker.DeploymentInfo({
            token: token,
            hook: address(0),
            locker: address(0),
            extensions: new address[](0)
        });
        _isRegistered[token] = true;
    }

    /// @notice Get deployment info for a token
    /// @dev In permissive mode, returns valid info for any token
    function tokenDeploymentInfo(
        address token
    ) external view returns (IClanker.DeploymentInfo memory) {
        IClanker.DeploymentInfo memory info = _deploymentInfo[token];

        // If token is registered, return stored info
        if (info.token != address(0)) {
            return info;
        }

        // If permissive mode is enabled, accept any token
        if (permissiveMode) {
            return
                IClanker.DeploymentInfo({
                    token: token,
                    hook: address(0),
                    locker: address(0),
                    extensions: new address[](0)
                });
        }

        // Otherwise, revert
        revert('NotFound');
    }

    /// @notice Check if token was deployed by this factory
    function isTokenRegistered(address token) external view returns (bool) {
        return _isRegistered[token];
    }
}
