// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrGovernor_v1} from './interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';

/// @title Levr Governor v1
/// @notice Time-weighted voting governance with cycle-based proposal management
/// @dev Key features:
///      - Proposals belong to cycles and expire when cycle advances
///      - Failed executions can be retried immediately (no permanent state corruption)
///      - Successful execution auto-advances to next cycle
///      - Failed execution requires manual cycle advancement after 3 attempts
///      - Prevents EIP-150 gas griefing and malicious token DoS attacks
contract LevrGovernor_v1 is ILevrGovernor_v1, ReentrancyGuard, ERC2771ContextBase {
    // ============ Immutable Storage ============

    address public immutable factory;
    address public immutable treasury;
    address public immutable staking;
    address public immutable stakedToken;
    address public immutable underlying;

    // ============ Mutable Storage ============

    uint256 private _proposalCount;
    uint256 private _currentCycleId;

    /// @notice Governance cycle timing and execution status
    /// @dev Each cycle has one proposal window, one voting window, and one winner max
    struct Cycle {
        uint256 proposalWindowStart; // When proposals can be created
        uint256 proposalWindowEnd; // When proposal window ends (voting begins)
        uint256 votingWindowEnd; // When voting ends (execution can begin)
        bool executed; // True if a winning proposal was successfully executed
    }

    mapping(uint256 => Cycle) private _cycles;
    mapping(uint256 => ILevrGovernor_v1.Proposal) private _proposals;
    mapping(uint256 => mapping(address => ILevrGovernor_v1.VoteReceipt)) private _voteReceipts;

    // Track active proposals per type
    mapping(ILevrGovernor_v1.ProposalType => uint256) private _activeProposalCount;

    // Proposals per cycle for winner determination
    mapping(uint256 => uint256[]) private _cycleProposals;

    // Track if user has proposed a type in a cycle: cycleId => proposalType => user => hasProposed
    mapping(uint256 => mapping(ILevrGovernor_v1.ProposalType => mapping(address => bool)))
        private _hasProposedInCycle;

    // Execution attempt counter per proposal
    // Incremented on each failed execution attempt (catch block)
    // Used to enforce 3-attempt minimum before allowing manual cycle advancement
    // Prevents premature abandonment of legitimate proposals
    mapping(uint256 => uint256) private _executionAttempts;

    // ============ Constructor ============

    constructor(
        address factory_,
        address treasury_,
        address staking_,
        address stakedToken_,
        address underlying_,
        address trustedForwarder
    ) ERC2771ContextBase(trustedForwarder) {
        if (factory_ == address(0)) revert InvalidRecipient();
        if (treasury_ == address(0)) revert InvalidRecipient();
        if (staking_ == address(0)) revert InvalidRecipient();
        if (stakedToken_ == address(0)) revert InvalidRecipient();
        if (underlying_ == address(0)) revert InvalidRecipient();

        factory = factory_;
        treasury = treasury_;
        staking = staking_;
        stakedToken = stakedToken_;
        underlying = underlying_;
    }

    // ============ External Functions ============

    /// @inheritdoc ILevrGovernor_v1
    function proposeBoost(address token, uint256 amount) external returns (uint256 proposalId) {
        if (token == address(0)) revert InvalidRecipient();
        return _propose(ProposalType.BoostStakingPool, token, amount, address(0), '');
    }

    /// @inheritdoc ILevrGovernor_v1
    function proposeTransfer(
        address token,
        address recipient,
        uint256 amount,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (token == address(0)) revert InvalidRecipient();
        if (recipient == address(0)) revert InvalidRecipient();
        return _propose(ProposalType.TransferToAddress, token, amount, recipient, description);
    }

    /// @inheritdoc ILevrGovernor_v1
    function vote(uint256 proposalId, bool support) external {
        address voter = _msgSender();
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Check voting is active
        if (block.timestamp < proposal.votingStartsAt || block.timestamp > proposal.votingEndsAt) {
            revert VotingNotActive();
        }

        // Check user hasn't voted
        if (_voteReceipts[proposalId][voter].hasVoted) {
            revert AlreadyVoted();
        }

        // Get voting power (time-weighted to prevent flash loan attacks)
        uint256 votes = ILevrStaking_v1(staking).getVotingPower(voter);
        if (votes == 0) revert InsufficientVotingPower();

        uint256 voterBalance = IERC20(stakedToken).balanceOf(voter);

        // Two-tier system: VP for approval (merit), balance for quorum (participation)
        if (support) {
            proposal.yesVotes += votes;
        } else {
            proposal.noVotes += votes;
        }
        proposal.totalBalanceVoted += voterBalance;

        _voteReceipts[proposalId][voter] = VoteReceipt({
            hasVoted: true,
            support: support,
            votes: votes
        });

        emit VoteCast(voter, proposalId, support, votes);
    }

    /// @inheritdoc ILevrGovernor_v1
    function startNewCycle() external {
        if (_currentCycleId == 0) {
            // Bootstrap: First cycle initialization (no proposals can exist yet)
            _startNewCycle();
        } else if (_needsNewCycle()) {
            // Normal flow: Current cycle has ended, verify safety then advance
            // Safety check: Ensure no Pending/Active proposals, and Succeeded proposals have 3+ attempts
            _checkNoExecutableProposals();
            _startNewCycle();
        } else {
            revert CycleStillActive();
        }
    }

    /// @inheritdoc ILevrGovernor_v1
    function execute(uint256 proposalId) external nonReentrant {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Verify voting has ended
        if (block.timestamp <= proposal.votingEndsAt) {
            revert VotingNotEnded();
        }

        // Verify proposal is from current cycle (prevents executing old proposals)
        // Note: Allows retry attempts within same cycle (no AlreadyExecuted check)
        if (proposal.cycleId != _currentCycleId) {
            revert ProposalNotInCurrentCycle();
        }

        // Early defeat: Quorum not met (mark as final to prevent retry spam)
        if (!_meetsQuorum(proposalId)) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Early defeat: Approval threshold not met (mark as final)
        if (!_meetsApproval(proposalId)) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Verify this is the winning proposal (highest yes votes for the cycle)
        uint256 winnerId = _getWinner(proposal.cycleId);
        if (winnerId != proposalId) {
            revert NotWinner();
        }

        // Verify cycle hasn't already executed a winning proposal
        Cycle storage cycle = _cycles[proposal.cycleId];
        if (cycle.executed) {
            revert AlreadyExecuted();
        }

        // Attempt execution: Only mark as executed on success
        // On failure: Increment attempt counter, allow retry, don't advance cycle
        try
            this._executeProposal(
                proposalId,
                proposal.proposalType,
                proposal.token,
                proposal.amount,
                proposal.recipient
            )
        {
            // Execution succeeded: Mark as executed and auto-advance cycle
            proposal.executed = true;
            cycle.executed = true;
            emit ProposalExecuted(proposalId, _msgSender());
            _startNewCycle();
        } catch {
            // Execution failed (OOG, token revert, insufficient balance, etc.)
            // Don't mark executed - allows immediate retry within same cycle
            // Track attempt - after 3 failed attempts, community can manually advance cycle
            _executionAttempts[proposalId]++;
            emit ProposalExecutionFailed(proposalId, 'execution_failed');
        }
    }

    /// @notice Internal execution helper (external visibility required for try-catch pattern)
    /// @dev Only callable by this contract to prevent unauthorized treasury access
    /// @dev Called within try-catch in execute() - failures don't revert entire transaction
    /// @param proposalType Type of proposal (BoostStakingPool or TransferToAddress)
    /// @param token ERC20 token address
    /// @param amount Amount to transfer
    /// @param recipient Recipient address (for TransferToAddress type)
    function _executeProposal(
        uint256, // proposalId - unused but kept for future extensibility
        ProposalType proposalType,
        address token,
        uint256 amount,
        address recipient
    ) external {
        // Security: Only callable by this contract (via try-catch in execute)
        if (_msgSender() != address(this)) revert ILevrGovernor_v1.InternalOnly();

        if (proposalType == ProposalType.BoostStakingPool) {
            ILevrTreasury_v1(treasury).applyBoost(token, amount);
        } else if (proposalType == ProposalType.TransferToAddress) {
            ILevrTreasury_v1(treasury).transfer(token, recipient, amount);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc ILevrGovernor_v1
    function state(uint256 proposalId) external view returns (ProposalState) {
        return _state(proposalId);
    }

    /// @inheritdoc ILevrGovernor_v1
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal memory proposal = _proposals[proposalId];
        proposal.state = _state(proposalId);
        proposal.meetsQuorum = _meetsQuorum(proposalId);
        proposal.meetsApproval = _meetsApproval(proposalId);
        return proposal;
    }

    /// @inheritdoc ILevrGovernor_v1
    function getVoteReceipt(
        uint256 proposalId,
        address voter
    ) external view returns (VoteReceipt memory) {
        return _voteReceipts[proposalId][voter];
    }

    /// @inheritdoc ILevrGovernor_v1
    function getProposalsForCycle(uint256 cycleId) external view returns (uint256[] memory) {
        return _cycleProposals[cycleId];
    }

    /// @inheritdoc ILevrGovernor_v1
    function currentCycleId() external view returns (uint256) {
        return _currentCycleId;
    }

    /// @inheritdoc ILevrGovernor_v1
    function executionAttempts(uint256 proposalId) external view returns (uint256) {
        return _executionAttempts[proposalId];
    }

    /// @inheritdoc ILevrGovernor_v1
    function getWinner(uint256 cycleId) external view returns (uint256) {
        return _getWinner(cycleId);
    }

    /// @inheritdoc ILevrGovernor_v1
    function meetsQuorum(uint256 proposalId) external view returns (bool) {
        return _meetsQuorum(proposalId);
    }

    /// @inheritdoc ILevrGovernor_v1
    function meetsApproval(uint256 proposalId) external view returns (bool) {
        return _meetsApproval(proposalId);
    }

    /// @inheritdoc ILevrGovernor_v1
    function activeProposalCount(ProposalType proposalType) external view returns (uint256) {
        return _activeProposalCount[proposalType];
    }

    // ============ Internal Functions ============

    function _propose(
        ProposalType proposalType,
        address token,
        uint256 amount,
        address recipient,
        string memory description
    ) internal returns (uint256 proposalId) {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) revert InvalidRecipient();

        address proposer = _msgSender();

        // Auto-start new cycle if needed (prevents orphaning executable proposals)
        if (_currentCycleId == 0 || _needsNewCycle()) {
            _checkNoExecutableProposals();
            _startNewCycle();
        }

        uint256 cycleId = _currentCycleId;

        // Validate proposal timing
        {
            Cycle memory cycle = _cycles[cycleId];
            if (
                block.timestamp < cycle.proposalWindowStart ||
                block.timestamp > cycle.proposalWindowEnd
            ) {
                revert ProposalWindowClosed();
            }
        }

        // Validate proposer stake
        {
            uint16 minStakeBps = ILevrFactory_v1(factory).minSTokenBpsToSubmit(underlying);
            if (minStakeBps > 0) {
                uint256 totalSupply = IERC20(stakedToken).totalSupply();
                if (
                    IERC20(stakedToken).balanceOf(proposer) < (totalSupply * minStakeBps) / 10_000
                ) {
                    revert InsufficientStake();
                }
            }
        }

        // Validate treasury and proposal limits
        uint256 treasuryBalance;
        {
            treasuryBalance = IERC20(token).balanceOf(treasury);
            if (treasuryBalance < amount) revert InsufficientTreasuryBalance();

            uint16 maxProposalBps = ILevrFactory_v1(factory).maxProposalAmountBps(underlying);
            if (maxProposalBps > 0 && amount > (treasuryBalance * maxProposalBps) / 10_000) {
                revert ProposalAmountExceedsLimit();
            }
        }

        // Rate limiting: max proposals per type, one per user per type per cycle
        if (
            _activeProposalCount[proposalType] >=
            ILevrFactory_v1(factory).maxActiveProposals(underlying)
        ) {
            revert MaxProposalsReached();
        }
        if (_hasProposedInCycle[cycleId][proposalType][proposer]) {
            revert AlreadyProposedInCycle();
        }

        // Create proposal with config snapshots (prevents manipulation)
        proposalId = ++_proposalCount;

        {
            Cycle memory cycle = _cycles[cycleId];
            _proposals[proposalId] = Proposal({
                id: proposalId,
                proposalType: proposalType,
                proposer: proposer,
                token: token,
                amount: amount,
                recipient: recipient,
                description: description,
                createdAt: block.timestamp,
                votingStartsAt: cycle.proposalWindowEnd,
                votingEndsAt: cycle.votingWindowEnd,
                yesVotes: 0,
                noVotes: 0,
                totalBalanceVoted: 0,
                executed: false,
                cycleId: cycleId,
                state: ProposalState.Pending,
                meetsQuorum: false,
                meetsApproval: false,
                totalSupplySnapshot: IERC20(stakedToken).totalSupply(),
                quorumBpsSnapshot: ILevrFactory_v1(factory).quorumBps(underlying),
                approvalBpsSnapshot: ILevrFactory_v1(factory).approvalBps(underlying)
            });
        }

        _activeProposalCount[proposalType]++;
        _cycleProposals[cycleId].push(proposalId);
        _hasProposedInCycle[cycleId][proposalType][proposer] = true;

        emit ProposalCreated(
            proposalId,
            proposer,
            proposalType,
            token,
            amount,
            recipient,
            description
        );
    }

    /// @notice Computes the current state of a proposal
    /// @dev State transitions: Pending → Active → (Succeeded|Defeated) → Executed
    /// @param proposalId The proposal ID to check
    /// @return The current proposal state
    function _state(uint256 proposalId) internal view returns (ProposalState) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        if (proposal.id == 0) revert InvalidProposalType();

        // Terminal state: Executed (only set on successful execution)
        if (proposal.executed) return ProposalState.Executed;

        // Time-based states
        if (block.timestamp < proposal.votingStartsAt) return ProposalState.Pending;
        if (block.timestamp <= proposal.votingEndsAt) return ProposalState.Active;

        // Post-voting states: Check if proposal won (quorum + approval)
        if (!_meetsQuorum(proposalId) || !_meetsApproval(proposalId)) {
            return ProposalState.Defeated;
        }

        return ProposalState.Succeeded;
    }

    function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Use snapshot values (prevents manipulation after proposal creation)
        uint16 quorumBps = proposal.quorumBpsSnapshot;
        if (quorumBps == 0) return true;

        uint256 snapshotSupply = proposal.totalSupplySnapshot;
        if (snapshotSupply == 0) return false;

        // Adaptive quorum: min(snapshot, current) prevents dilution attacks & deadlock
        uint256 currentSupply = IERC20(stakedToken).totalSupply();
        uint256 effectiveSupply = currentSupply < snapshotSupply ? currentSupply : snapshotSupply;

        uint256 percentageQuorum = (effectiveSupply * quorumBps) / 10_000;

        // Enforce minimum absolute quorum (prevents early governance capture)
        uint16 minimumQuorumBps = ILevrFactory_v1(factory).minimumQuorumBps(underlying);
        uint256 minimumAbsoluteQuorum = (snapshotSupply * minimumQuorumBps) / 10_000;

        uint256 requiredQuorum = percentageQuorum > minimumAbsoluteQuorum
            ? percentageQuorum
            : minimumAbsoluteQuorum;

        return proposal.totalBalanceVoted >= requiredQuorum;
    }

    function _meetsApproval(uint256 proposalId) internal view returns (bool) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Use snapshot (prevents config manipulation)
        uint16 approvalBps = proposal.approvalBpsSnapshot;
        if (approvalBps == 0) return true;

        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        if (totalVotes == 0) return false;

        uint256 requiredApproval = (totalVotes * approvalBps) / 10_000;
        return proposal.yesVotes >= requiredApproval;
    }

    function _getWinner(uint256 cycleId) internal view returns (uint256 winnerId) {
        uint256[] memory proposals = _cycleProposals[cycleId];
        uint256 bestApprovalRatio = 0;

        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 pid = proposals[i];
            ILevrGovernor_v1.Proposal storage proposal = _proposals[pid];

            if (_meetsQuorum(pid) && _meetsApproval(pid)) {
                uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
                if (totalVotes == 0) continue;

                // Use approval ratio (not absolute votes) to prevent strategic NO voting
                uint256 approvalRatio = (proposal.yesVotes * 10000) / totalVotes;

                if (approvalRatio > bestApprovalRatio) {
                    bestApprovalRatio = approvalRatio;
                    winnerId = pid;
                }
            }
        }

        return winnerId; // 0 if no winner
    }

    /// @dev Check if a new cycle needs to be started
    function _needsNewCycle() internal view returns (bool) {
        if (_currentCycleId == 0) return true;

        Cycle memory cycle = _cycles[_currentCycleId];

        // New cycle needed if voting window has ended
        return block.timestamp > cycle.votingWindowEnd;
    }

    /// @notice Starts a new governance cycle
    /// @dev Called in three scenarios:
    ///      1. Bootstrap: First cycle initialization (currentCycleId == 0)
    ///      2. Auto-advance: After successful proposal execution
    ///      3. Manual: Via startNewCycle() after failed proposals (3+ attempts)
    function _startNewCycle() internal {
        uint32 proposalWindow = ILevrFactory_v1(factory).proposalWindowSeconds(underlying);
        uint32 votingWindow = ILevrFactory_v1(factory).votingWindowSeconds(underlying);

        uint256 cycleId = ++_currentCycleId;
        uint256 start = block.timestamp;
        uint256 proposalEnd = start + proposalWindow;
        uint256 voteEnd = proposalEnd + votingWindow;

        // Reset proposal counts to 0 (proposals are cycle-scoped)
        _activeProposalCount[ProposalType.BoostStakingPool] = 0;
        _activeProposalCount[ProposalType.TransferToAddress] = 0;

        _cycles[cycleId] = Cycle({
            proposalWindowStart: start,
            proposalWindowEnd: proposalEnd,
            votingWindowEnd: voteEnd,
            executed: false
        });

        emit CycleStarted(cycleId, start, proposalEnd, voteEnd);
    }

    /// @notice Validates that manual cycle advancement is safe
    /// @dev Prevents advancing while proposals are still active or haven't been attempted
    /// @dev State-by-state logic:
    ///      - Executed: Skip (already finalized)
    ///      - Pending/Active: Block (voting in progress)
    ///      - Succeeded with <3 attempts: Block (must retry execution first)
    ///      - Succeeded with >=3 attempts: Allow (community made genuine effort, can abandon)
    ///      - Defeated: Allow (lost vote, nothing to do)
    function _checkNoExecutableProposals() internal view {
        uint256[] memory proposals = _cycleProposals[_currentCycleId];

        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 pid = proposals[i];
            ILevrGovernor_v1.Proposal storage proposal = _proposals[pid];

            // Skip already executed proposals (finalized)
            if (proposal.executed) continue;

            ProposalState currentState = _state(pid);

            // Block if voting is still in progress (Pending: not started, Active: ongoing)
            if (currentState == ProposalState.Pending || currentState == ProposalState.Active) {
                revert ExecutableProposalsRemaining();
            }

            // For winning proposals (Succeeded): Require 3 execution attempts before allowing skip
            // Rationale: Ensures genuine effort to execute before community abandons proposal
            if (currentState == ProposalState.Succeeded) {
                if (_executionAttempts[pid] < 3) {
                    revert ExecutableProposalsRemaining();
                }
                // 3+ attempts made, proposal persistently fails, can skip
            }

            // Defeated proposals: Fall through (lost vote, no action needed)
        }
    }
}
