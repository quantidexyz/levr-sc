// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Fee Splitter Factory v1 Interface
/// @notice Factory for deploying per-project fee splitters for Clanker tokens
/// @dev Each project gets its own dedicated fee splitter to avoid shared token balances
interface ILevrFeeSplitterFactory_v1 {
    // ============ Errors ============

    error ZeroAddress();
    error AlreadyDeployed();

    // ============ Events ============

    /// @notice Emitted when a fee splitter is deployed for a project
    /// @param clankerToken The Clanker token address
    /// @param feeSplitter The deployed fee splitter address
    event FeeSplitterDeployed(address indexed clankerToken, address indexed feeSplitter);

    // ============ Functions ============

    /// @notice Deploy a fee splitter for a Clanker token
    /// @dev Anyone can deploy, but only token admin can configure splits
    /// @param clankerToken The Clanker token address
    /// @return splitter The deployed fee splitter address
    function deploy(address clankerToken) external returns (address splitter);

    /// @notice Deploy a fee splitter with CREATE2 for deterministic address
    /// @dev Anyone can deploy, but only token admin can configure splits
    /// @param clankerToken The Clanker token address
    /// @param salt Salt for CREATE2 deployment
    /// @return splitter The deployed fee splitter address
    function deployDeterministic(
        address clankerToken,
        bytes32 salt
    ) external returns (address splitter);

    /// @notice Get the fee splitter for a Clanker token
    /// @param clankerToken The Clanker token address
    /// @return splitter The fee splitter address (zero if not deployed)
    function getSplitter(address clankerToken) external view returns (address splitter);

    /// @notice Compute the deterministic address for a fee splitter
    /// @param clankerToken The Clanker token address
    /// @param salt Salt for CREATE2 deployment
    /// @return predicted The predicted fee splitter address
    function computeDeterministicAddress(
        address clankerToken,
        bytes32 salt
    ) external view returns (address predicted);

    /// @notice Get the factory address
    /// @return factory The Levr factory address
    function factory() external view returns (address);

    // Note: trustedForwarder() is inherited from ERC2771ContextBase
}
