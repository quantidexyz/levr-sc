// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEmergencyRescue} from './IEmergencyRescue.sol';
import {ILevrFactory_v1} from '../interfaces/ILevrFactory_v1.sol';

/**
 * @title EmergencyRescuable
 * @notice Base contract providing emergency rescue functionality
 * @dev Contracts inherit this to get emergency rescue capabilities
 */
abstract contract EmergencyRescuable is IEmergencyRescue {
    /// @notice Reference to factory for emergency mode check
    function factory() public view virtual returns (address);

    /// @notice Check if emergency mode is enabled
    modifier onlyEmergency() {
        if (!ILevrFactory_v1(factory()).emergencyMode()) {
            revert NotEmergencyMode();
        }
        if (msg.sender != ILevrFactory_v1(factory()).emergencyAdmin()) {
            revert NotEmergencyAdmin();
        }
        _;
    }

    /// @notice Check if caller is emergency admin (without requiring emergency mode)
    modifier onlyEmergencyAdmin() {
        if (msg.sender != ILevrFactory_v1(factory()).emergencyAdmin()) {
            revert NotEmergencyAdmin();
        }
        _;
    }
}
