// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';

/**
 * @title LevrFactory v1 Mock
 * @notice Mock factory contract for testing fee splitter and project interactions
 * @dev Provides mock implementations of factory functions for testing
 */
contract LevrFactory_v1_Mock {
    address public clankerToken;
    address public staking;
    mapping(address => uint32) private _streamWindows;
    uint16 private _protocolFeeBps;
    address private _protocolTreasury;

    /// @notice Set project addresses
    function setProject(address _clankerToken, address _staking, address /* _lpLocker */) external {
        clankerToken = _clankerToken;
        staking = _staking;
    }

    /// @notice Configure protocol fee data for tests
    function setProtocolFee(uint16 feeBps, address treasury) external {
        _protocolFeeBps = feeBps;
        _protocolTreasury = treasury;
    }

    /// @notice Set stream window seconds for a token
    function setStreamWindowSeconds(address token, uint32 window) external {
        _streamWindows[token] = window;
    }

    /// @notice Get stream window seconds for a token
    function streamWindowSeconds(address token) external view returns (uint32) {
        uint32 window = _streamWindows[token];
        return window == 0 ? 7 days : window;
    }

    function protocolFeeBps() external view returns (uint16) {
        return _protocolFeeBps;
    }

    function protocolTreasury() external view returns (address) {
        return _protocolTreasury;
    }

    /// @notice Get project contracts for a token
    function getProject(address) external view returns (ILevrFactory_v1.Project memory) {
        return
            ILevrFactory_v1.Project({
                treasury: address(0),
                governor: address(0),
                staking: staking,
                stakedToken: address(0),
                verified: false
            });
    }
}
