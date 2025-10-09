// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';

/// @title Levr Forwarder v1 Interface
/// @notice Meta-transaction forwarder with multicall support for Levr Protocol
interface ILevrForwarder_v1 {
    // ============ Structs ============

    /// @notice Struct for a single call in a multicall sequence
    /// @param target Target contract to call
    /// @param allowFailure Whether the call is allowed to fail
    /// @param value Amount of ETH to send with the call
    /// @param callData Encoded function call data
    struct SingleCall {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    /// @notice Result of a single call in multicall
    /// @param success Whether the call succeeded
    /// @param returnData Return data from the call
    struct Result {
        bool success;
        bytes returnData;
    }

    // ============ Errors ============

    /// @notice Call failed and was not allowed to fail
    /// @param call The call that failed
    error CallFailed(SingleCall call);

    /// @notice Attempted to call a forbidden function selector on the forwarder itself
    /// @param selector The forbidden function selector
    error ForbiddenSelectorOnSelf(bytes4 selector);

    /// @notice Attempted to call executeTransaction directly instead of via executeMulticall
    /// @dev executeTransaction can only be called from the forwarder itself (via multicall)
    ///      to prevent address impersonation attacks on ERC2771Context contracts
    error OnlyMulticallCanExecuteTransaction();

    /// @notice msg.value does not match the sum of all call values
    /// @param provided The msg.value provided
    /// @param required The total value required by all calls
    error ValueMismatch(uint256 provided, uint256 required);

    /// @notice No ETH available to withdraw
    error NoETHToWithdraw();

    /// @notice ETH transfer failed
    error ETHTransferFailed();

    /// @notice Caller is not the deployer
    error OnlyDeployer();

    // ============ Functions ============

    /// @notice Execute multiple calls in a single transaction (ERC2771 mode)
    /// @dev Each call is executed with the caller's address appended (ERC2771)
    ///      Only calls to contracts that trust this forwarder will succeed
    ///      msg.value MUST exactly match sum of all call values (ValueMismatch otherwise)
    ///      Protected by nonReentrant modifier to prevent reentrancy attacks
    /// @param calls Array of calls to execute
    /// @return results Array of results for each call
    function executeMulticall(
        SingleCall[] calldata calls
    ) external payable returns (Result[] memory results);

    /// @notice Execute a single transaction to any external contract
    /// @dev SECURITY: Can only be called via executeMulticall (msg.sender == address(this))
    ///      Executes call FROM the forwarder without appending sender (non-ERC2771)
    ///      Useful for calling external contracts that don't use ERC2771 in multicall sequences
    ///      Does NOT require target to trust this forwarder
    ///      Direct calls will revert with OnlyMulticallCanExecuteTransaction
    /// @param target The contract to call
    /// @param data The calldata to send
    /// @return success Whether the call succeeded
    /// @return returnData The return data from the call
    function executeTransaction(
        address target,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData);

    /// @notice Create a digest for signing a forward request
    /// @param req The forward request data
    /// @return digest The EIP-712 digest to sign
    function createDigest(
        ERC2771Forwarder.ForwardRequestData memory req
    ) external view returns (bytes32 digest);

    /// @notice Withdraw any ETH accidentally trapped in the forwarder
    /// @dev Only deployer can call this function - forwarder should never hold ETH
    ///      Protected by nonReentrant modifier
    ///      Reverts with OnlyDeployer if caller is not deployer
    ///      Reverts with NoETHToWithdraw if balance is zero
    ///      Reverts with ETHTransferFailed if transfer fails
    function withdrawTrappedETH() external;

    /// @notice Get the address of the forwarder deployer
    /// @return The deployer address (immutable, set at construction)
    function deployer() external view returns (address);
}
