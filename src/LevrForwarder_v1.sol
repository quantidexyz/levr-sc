// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
import {ERC2771Context} from '@openzeppelin/contracts/metatx/ERC2771Context.sol';
import {Context} from '@openzeppelin/contracts/utils/Context.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ILevrForwarder_v1} from './interfaces/ILevrForwarder_v1.sol';

/**
 * @title LevrForwarder_v1
 * @notice Meta-transaction forwarder with multicall support for Levr Protocol
 * @dev Extends OpenZeppelin's ERC2771Forwarder and adds executeMulticall functionality
 *      Also adds executeTransaction functionality for direct contract calls
 *      Protected against reentrancy and validates ETH amounts
 */
contract LevrForwarder_v1 is ILevrForwarder_v1, ERC2771Forwarder, ReentrancyGuard {
    address public immutable deployer;

    constructor(string memory name) ERC2771Forwarder(name) {
        deployer = msg.sender;
    }

    /// @inheritdoc ILevrForwarder_v1
    function executeMulticall(
        SingleCall[] calldata calls
    ) external payable nonReentrant returns (Result[] memory results) {
        uint256 length = calls.length;
        results = new Result[](length);

        // Validate ETH sent matches sum of call values
        uint256 totalValue = 0;
        for (uint256 i = 0; i < length; i++) {
            totalValue += calls[i].value;
        }
        if (msg.value != totalValue) revert ValueMismatch(msg.value, totalValue);

        SingleCall calldata calli;
        bytes memory data;
        bool success;
        bytes memory returnData;

        // Execute each call in sequence
        for (uint256 i = 0; i < length; i++) {
            calli = calls[i];

            // Self-calls: executeTransaction only (prevents recursion)
            if (calli.target == address(this)) {
                bytes4 selector = bytes4(calli.callData);
                if (selector != this.executeTransaction.selector) {
                    revert ForbiddenSelectorOnSelf(selector);
                }
                (success, returnData) = calli.target.call{value: calli.value}(calli.callData);
            } else {
                // External calls: append sender for ERC2771Context
                if (!_isTrustedByTarget(calli.target)) {
                    revert ERC2771UntrustfulTarget(calli.target, address(this));
                }

                data = abi.encodePacked(calli.callData, msg.sender);
                (success, returnData) = calli.target.call{value: calli.value}(data);
            }

            if (!success && !calli.allowFailure) {
                revert CallFailed(calli);
            }

            // Store result
            results[i] = Result(success, returnData);
        }
    }

    /// @inheritdoc ILevrForwarder_v1
    function executeTransaction(
        address target,
        bytes calldata data
    ) external payable returns (bool success, bytes memory returnData) {
        // Only callable via executeMulticall (prevents impersonation)
        if (msg.sender != address(this)) revert OnlyMulticallCanExecuteTransaction();

        // Prevent calling trusted targets via executeTransaction to avoid ERC2771 spoofing
        if (_isTrustedByTarget(target)) {
            revert TargetTrustsForwarder(target);
        }

        (success, returnData) = target.call{value: msg.value}(data);
    }

    /// @inheritdoc ILevrForwarder_v1
    function createDigest(
        ERC2771Forwarder.ForwardRequestData memory req
    ) external view returns (bytes32 digest) {
        return _hashTypedDataV4(_getStructHash(req));
    }

    /// @inheritdoc ILevrForwarder_v1
    function withdrawTrappedETH() external nonReentrant {
        // Only deployer can withdraw trapped ETH
        if (msg.sender != deployer) revert OnlyDeployer();

        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHToWithdraw();

        // Send ETH to deployer
        (bool success, ) = payable(deployer).call{value: balance}('');
        if (!success) revert ETHTransferFailed();
    }

    /// @inheritdoc ILevrForwarder_v1
    function withdrawTrappedTokens(address token, uint256 amount) external nonReentrant {
        // Only deployer can withdraw trapped tokens
        if (msg.sender != deployer) revert OnlyDeployer();

        // Send tokens to deployer
        bool success = IERC20(token).transfer(deployer, amount);
        if (!success) revert TokenTransferFailed();
    }

    // ============ Internal Functions ============

    /// @notice Check if a target contract trusts this forwarder
    /// @param target The contract to check
    /// @return Whether the target trusts this forwarder
    /// @dev Override the internal function from ERC2771Forwarder to make it accessible
    function _isTrustedByTarget(address target) internal view override returns (bool) {
        return super._isTrustedByTarget(target);
    }

    /// @notice Get the struct hash for EIP-712 signing
    /// @param req The forward request data
    /// @return The keccak256 hash of the encoded request
    function _getStructHash(
        ERC2771Forwarder.ForwardRequestData memory req
    ) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _FORWARD_REQUEST_TYPEHASH,
                    req.from,
                    req.to,
                    req.value,
                    req.gas,
                    nonces(req.from),
                    req.deadline,
                    keccak256(req.data)
                )
            );
    }
}
