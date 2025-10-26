// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IEmergencyRescue
 * @notice Interface for emergency rescue functionality across all Levr contracts
 * @dev Emergency mode must be enabled at factory level before any rescue operations
 */
interface IEmergencyRescue {
    // ============ Events ============

    event EmergencyModeEnabled(address indexed enabledBy, uint256 timestamp);
    event EmergencyModeDisabled(address indexed disabledBy, uint256 timestamp);
    event EmergencyAdminSet(address indexed oldAdmin, address indexed newAdmin);
    event EmergencyActionProposed(bytes32 indexed actionId, uint256 executeAfter);
    event EmergencyRescueExecuted(
        address indexed token,
        address indexed to,
        uint256 amount,
        string reason
    );
    event EmergencyReserveAdjusted(address indexed token, uint256 oldReserve, uint256 newReserve);
    event EmergencyStreamCleared(address indexed token);
    event EmergencyPaused(address indexed contract_);
    event EmergencyUnpaused(address indexed contract_);

    // ============ Errors ============

    error NotEmergencyMode();
    error NotEmergencyAdmin();
    error NotAuthorized();
    error TimelockNotPassed();
    error ActionNotProposed();
    error CantRescueEscrow();
    error InvariantViolation(string reason);
}
