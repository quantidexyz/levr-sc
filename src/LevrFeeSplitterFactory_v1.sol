// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LevrFeeSplitter_v1} from './LevrFeeSplitter_v1.sol';
import {ILevrFeeSplitterFactory_v1} from './interfaces/ILevrFeeSplitterFactory_v1.sol';
import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ERC2771Context} from '@openzeppelin/contracts/metatx/ERC2771Context.sol';

/**
 * @title LevrFeeSplitterFactory_v1
 * @notice Factory for deploying per-project fee splitters for Clanker tokens
 * @dev Each project gets its own dedicated fee splitter instance to avoid token mixing
 *      This is deployed separately from the factory and is completely optional
 *      Supports meta-transactions via ERC2771 for gasless deployment and multicall
 */
contract LevrFeeSplitterFactory_v1 is ILevrFeeSplitterFactory_v1, ERC2771ContextBase {
    // ============ State Variables ============

    /// @notice The Levr factory address
    address public immutable factory;

    /// @notice Mapping of clanker token to its deployed fee splitter
    mapping(address => address) public splitters;

    // ============ Constructor ============

    /**
     * @notice Deploy the fee splitter factory
     * @param factory_ The Levr factory address
     * @param trustedForwarder_ The ERC2771 forwarder for meta-transactions
     */
    constructor(address factory_, address trustedForwarder_) ERC2771ContextBase(trustedForwarder_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    // ============ Deployment Functions ============

    /// @inheritdoc ILevrFeeSplitterFactory_v1
    function deploy(address clankerToken) external returns (address splitter) {
        if (clankerToken == address(0)) revert ZeroAddress();
        if (splitters[clankerToken] != address(0)) revert AlreadyDeployed();

        // Deploy new fee splitter for this project
        splitter = address(new LevrFeeSplitter_v1(clankerToken, factory, trustedForwarder()));

        // Store mapping
        splitters[clankerToken] = splitter;

        emit FeeSplitterDeployed(clankerToken, splitter);
    }

    /// @inheritdoc ILevrFeeSplitterFactory_v1
    function deployDeterministic(
        address clankerToken,
        bytes32 salt
    ) external returns (address splitter) {
        if (clankerToken == address(0)) revert ZeroAddress();
        if (splitters[clankerToken] != address(0)) revert AlreadyDeployed();

        // Deploy with CREATE2 for deterministic address
        splitter = address(
            new LevrFeeSplitter_v1{salt: salt}(clankerToken, factory, trustedForwarder())
        );

        // Store mapping
        splitters[clankerToken] = splitter;

        emit FeeSplitterDeployed(clankerToken, splitter);
    }

    /// @inheritdoc ILevrFeeSplitterFactory_v1
    function getSplitter(address clankerToken) external view returns (address) {
        return splitters[clankerToken];
    }

    /// @notice Get the trusted forwarder address
    /// @return The ERC2771 forwarder address
    function trustedForwarder() public view virtual override(ERC2771Context) returns (address) {
        return ERC2771Context.trustedForwarder();
    }

    /// @inheritdoc ILevrFeeSplitterFactory_v1
    function computeDeterministicAddress(
        address clankerToken,
        bytes32 salt
    ) external view returns (address) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(LevrFeeSplitter_v1).creationCode,
                abi.encode(clankerToken, factory, trustedForwarder())
            )
        );

        return
            address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash))
                    )
                )
            );
    }
}
