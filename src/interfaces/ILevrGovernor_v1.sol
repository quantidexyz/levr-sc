// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Governor v1 Interface
/// @notice Per-project governance for transfers and boosts.
interface ILevrGovernor_v1 {
    /// @notice Revert if caller lacks permission or balance requirements.
    error NotAuthorized();

    /// @notice Revert if amount is zero or exceeds tier limit.
    error InvalidAmount();

    /// @notice Revert if proposal deadline has passed.
    error DeadlinePassed();

    /// @notice Revert if proposal already executed.
    error AlreadyExecuted();

    /// @notice Revert if tier index is out of bounds.
    error TierOutOfBounds();

    /// @notice Proposal type discriminator.
    enum ProposalType {
        Transfer,
        Boost
    }

    /// @notice Proposal state.
    /// @param proposer Address who created the proposal
    /// @param proposalType Type of the proposal
    /// @param receiver Target address (for Transfer)
    /// @param amount Amount associated with the proposal
    /// @param reason Human-readable description
    /// @param tier Tier index for validation
    /// @param deadline Timestamp for execution deadline
    /// @param executed Whether proposal has been executed
    struct Proposal {
        address proposer;
        ProposalType proposalType;
        address receiver;
        uint256 amount;
        string reason;
        uint8 tier;
        uint32 deadline;
        bool executed;
    }

    /// @notice Emitted when a proposal is created.
    /// @param id Unique proposal id
    /// @param proposalType Proposal type
    /// @param proposer Address who created the proposal
    event ProposalCreated(
        uint256 indexed id,
        ProposalType proposalType,
        address indexed proposer
    );

    /// @notice Emitted when a proposal is executed.
    /// @param id Proposal id
    event ProposalExecuted(uint256 indexed id);

    /// @notice Create a transfer proposal.
    /// @param receiver Recipient of funds
    /// @param amount Amount to transfer
    /// @param reason Description of the transfer
    /// @param tier Governance tier to apply
    /// @return proposalId Newly created proposal id
    function proposeTransfer(
        address receiver,
        uint256 amount,
        string calldata reason,
        uint8 tier
    ) external returns (uint256 proposalId);

    /// @notice Create a staking boost proposal.
    /// @param amount Amount to apply
    /// @param tier Governance tier to apply
    /// @return proposalId Newly created proposal id
    function proposeBoost(
        uint256 amount,
        uint8 tier
    ) external returns (uint256 proposalId);

    /// @notice Execute a previously created proposal.
    /// @param proposalId Id of the proposal to execute
    function execute(uint256 proposalId) external;

    /// @notice Read a proposal by id.
    /// @param proposalId Id to fetch
    /// @return Proposal The proposal struct
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory);

    /// @notice Check if a given address can submit proposals.
    /// @param proposer Address to check
    /// @return allowed True iff proposer meets submission requirements
    function canSubmit(address proposer) external view returns (bool allowed);
}
