// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Levr Governor v1 Interface
/// @notice Time-weighted voting governance for Levr projects
/// @dev Voting power = staked amount × time staked (resets on unstake)
interface ILevrGovernor_v1 {
    // ============ Enums ============

    /// @notice Type of proposal
    enum ProposalType {
        BoostStakingPool, // Transfer tokens from Treasury to Staking contract
        TransferToAddress // Transfer tokens from Treasury to arbitrary address
    }

    /// @notice State of a proposal
    enum ProposalState {
        Pending, // Created, voting not started
        Active, // Voting in progress
        Succeeded, // Eligible for execution
        Defeated, // Quorum or approval not met
        Executed // Winner executed on-chain
    }

    // ============ Structs ============

    /// @notice Proposal details
    struct Proposal {
        uint256 id; // Proposal ID
        ProposalType proposalType; // Type of proposal
        address proposer; // Address that created the proposal
        address token; // TOKEN AGNOSTIC: ERC20 token address (underlying, WETH, or any ERC20)
        uint256 amount; // Amount of tokens to transfer
        address recipient; // Recipient address (for TransferToAddress type)
        string description; // Proposal description (for TransferToAddress type)
        uint256 createdAt; // Timestamp when proposal was created
        uint256 votingStartsAt; // Timestamp when voting starts
        uint256 votingEndsAt; // Timestamp when voting ends
        uint256 yesVotes; // Total yes votes (VP)
        uint256 noVotes; // Total no votes (VP)
        uint256 totalBalanceVoted; // Total sToken balance that voted (for quorum)
        bool executed; // Whether proposal has been executed
        uint256 cycleId; // Governance cycle ID
        ProposalState state; // Current state of the proposal (computed)
        bool meetsQuorum; // Whether proposal meets quorum threshold (computed)
        bool meetsApproval; // Whether proposal meets approval threshold (computed)
        uint256 totalSupplySnapshot; // FIX [NEW-C-1, NEW-C-2]: Snapshot of sToken supply at proposal creation
        uint16 quorumBpsSnapshot; // FIX [NEW-C-3]: Snapshot of quorum threshold at proposal creation
        uint16 approvalBpsSnapshot; // FIX [NEW-C-3]: Snapshot of approval threshold at proposal creation
    }

    /// @notice Vote receipt for a user on a proposal
    struct VoteReceipt {
        bool hasVoted; // Whether user has voted
        bool support; // True = yes, false = no
        uint256 votes; // Voting power used
    }

    // ============ Errors ============

    /// @notice Proposal window is not open
    error ProposalWindowClosed();

    /// @notice Insufficient staked token balance to propose
    error InsufficientStake();

    /// @notice Maximum active proposals per type reached
    error MaxProposalsReached();

    /// @notice User has already proposed this type in the current cycle
    error AlreadyProposedInCycle();

    /// @notice User has already voted on this proposal
    error AlreadyVoted();

    /// @notice Voting is not active for this proposal
    error VotingNotActive();

    /// @notice Proposal has not succeeded
    error ProposalNotSucceeded();

    /// @notice Proposal is not the winner for this cycle
    error NotWinner();

    /// @notice Proposal has already been executed
    error AlreadyExecuted();

    /// @notice Caller is not authorized
    error NotAuthorized();

    /// @notice Invalid proposal type
    error InvalidProposalType();

    /// @notice Invalid amount (zero or exceeds treasury balance)
    error InvalidAmount();

    /// @notice Invalid recipient address
    error InvalidRecipient();

    /// @notice No active governance cycle
    error NoActiveCycle();

    /// @notice Insufficient voting power to vote
    error InsufficientVotingPower();

    /// @notice Cycle is still active, cannot start new one
    error CycleStillActive();

    /// @notice Cannot start new cycle while executable proposals exist in current cycle
    error ExecutableProposalsRemaining();

    /// @notice Treasury has insufficient balance for proposal amount
    error InsufficientTreasuryBalance();

    /// @notice Proposal amount exceeds maximum allowed percentage of treasury balance
    error ProposalAmountExceedsLimit();

    // ============ Events ============

    /// @notice Emitted when a new proposal is created
    /// @param proposalId The ID of the proposal
    /// @param proposer Address that created the proposal
    /// @param proposalType Type of proposal
    /// @param token ERC20 token address (underlying, WETH, or any ERC20)
    /// @param amount Amount of tokens
    /// @param recipient Recipient address (for TransferToAddress)
    /// @param description Proposal description
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType proposalType,
        address indexed token,
        uint256 amount,
        address recipient,
        string description
    );

    /// @notice Emitted when a vote is cast
    /// @param voter Address that voted
    /// @param proposalId The ID of the proposal
    /// @param support True for yes, false for no
    /// @param votes Voting power used
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 votes);

    /// @notice Emitted when a proposal is executed
    /// @param proposalId The ID of the proposal
    /// @param executor Address that executed the proposal
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    /// @notice Emitted when a proposal is defeated
    /// @param proposalId The ID of the proposal
    event ProposalDefeated(uint256 indexed proposalId);

    /// @notice Emitted when a proposal execution fails (token revert, etc)
    /// @param proposalId The ID of the proposal
    /// @param reason The failure reason
    event ProposalExecutionFailed(uint256 indexed proposalId, string reason);

    /// @notice Emitted when a new governance cycle starts
    /// @param cycleId The ID of the new cycle
    /// @param proposalWindowStart Timestamp when proposal window starts
    /// @param proposalWindowEnd Timestamp when proposal window ends
    /// @param votingWindowEnd Timestamp when voting window ends
    event CycleStarted(
        uint256 indexed cycleId,
        uint256 proposalWindowStart,
        uint256 proposalWindowEnd,
        uint256 votingWindowEnd
    );

    // ============ Functions ============

    /// @notice Create a proposal to boost the staking pool
    /// @dev Requires minimum staked balance (minSTokenBpsToSubmit)
    ///      Max active proposals per type not exceeded
    ///      Automatically starts new cycle if none exists or current ended
    /// @param token ERC20 token address (underlying, WETH, or any ERC20)
    /// @param amount Amount of tokens to transfer from treasury to staking
    /// @return proposalId The ID of the created proposal
    function proposeBoost(address token, uint256 amount) external returns (uint256 proposalId);

    /// @notice Create a proposal to transfer tokens to an address
    /// @dev Requires minimum staked balance (minSTokenBpsToSubmit)
    ///      Max active proposals per type not exceeded
    ///      Automatically starts new cycle if none exists or current ended
    /// @param token ERC20 token address (underlying, WETH, or any ERC20)
    /// @param recipient Address to receive tokens
    /// @param amount Amount of tokens to transfer
    /// @param description Proposal description
    /// @return proposalId The ID of the created proposal
    function proposeTransfer(
        address token,
        address recipient,
        uint256 amount,
        string calldata description
    ) external returns (uint256 proposalId);

    /// @notice Vote on a proposal
    /// @dev Voting must be active
    ///      User must not have already voted
    ///      Uses VP from snapshot at proposal creation
    /// @param proposalId The ID of the proposal
    /// @param support True for yes, false for no
    function vote(uint256 proposalId, bool support) external;

    /// @notice Execute a proposal
    /// @dev Voting must be ended
    ///      Proposal must meet quorum and approval thresholds
    ///      Proposal must be the winner (highest yes votes) for its cycle
    ///      Calls treasury to perform the action
    ///      Automatically starts new cycle after execution
    /// @param proposalId The ID of the proposal to execute
    function execute(uint256 proposalId) external;

    /// @notice Start a new governance cycle
    /// @dev Can only be called if no active cycle exists or current cycle has ended
    ///      Useful for recovering from failed cycles where no proposals were executed
    ///      Anyone can call this function to restart governance
    function startNewCycle() external;

    /// @notice Get the current state of a proposal
    /// @param proposalId The ID of the proposal
    /// @return The current state
    function state(uint256 proposalId) external view returns (ProposalState);

    /// @notice Get proposal details
    /// @param proposalId The ID of the proposal
    /// @return proposal The proposal struct
    function getProposal(uint256 proposalId) external view returns (Proposal memory proposal);

    /// @notice Get vote receipt for a user on a proposal
    /// @param proposalId The ID of the proposal
    /// @param voter The voter address
    /// @return receipt The vote receipt
    function getVoteReceipt(
        uint256 proposalId,
        address voter
    ) external view returns (VoteReceipt memory receipt);

    /// @notice Get all proposal IDs for a cycle
    /// @param cycleId The cycle ID
    /// @return proposalIds Array of proposal IDs
    function getProposalsForCycle(
        uint256 cycleId
    ) external view returns (uint256[] memory proposalIds);

    /// @notice Get the current active cycle ID
    /// @return cycleId The current cycle ID (0 if no active cycle)
    function currentCycleId() external view returns (uint256 cycleId);

    /// @notice Get the winning proposal for a cycle
    /// @dev Returns the proposal with highest yes votes that met quorum + approval
    /// @param cycleId The cycle ID
    /// @return proposalId The winning proposal ID (0 if no winner)
    function getWinner(uint256 cycleId) external view returns (uint256 proposalId);

    /// @notice Check if a proposal meets quorum
    /// @param proposalId The ID of the proposal
    /// @return True if quorum is met
    function meetsQuorum(uint256 proposalId) external view returns (bool);

    /// @notice Check if a proposal meets approval threshold
    /// @param proposalId The ID of the proposal
    /// @return True if approval threshold is met
    function meetsApproval(uint256 proposalId) external view returns (bool);

    /// @notice Get the number of active proposals for a type
    /// @param proposalType The proposal type
    /// @return count The number of active proposals
    function activeProposalCount(ProposalType proposalType) external view returns (uint256 count);

    /// @notice Get the factory address
    /// @return The factory address (config source)
    function factory() external view returns (address);

    /// @notice Get the treasury address
    /// @return The treasury address (execution target)
    function treasury() external view returns (address);

    /// @notice Get the staking contract address
    /// @return The staking contract address (for VP queries)
    function staking() external view returns (address);

    /// @notice Get the staked token address
    /// @return The staked token address (for balance checks)
    function stakedToken() external view returns (address);
}
