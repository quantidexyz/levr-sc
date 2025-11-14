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
    // ============ Constants ============

    /// @notice Minimum delay between execution attempts (10 minutes)
    /// @dev Prevents batched failed attempts to prematurely advance cycle
    ///      Gives DAO time to react and fix issues (e.g., send funds to treasury)
    uint32 public constant EXECUTION_ATTEMPT_DELAY = 10 minutes;

    // ============ Immutable Storage ============

    address public immutable factory;

    // ============ Mutable Storage ============

    address public treasury;
    address public staking;
    address public stakedToken;
    address public underlying;
    bool private _initialized;

    uint256 private _proposalCount;
    uint256 private _currentCycleId;

    /// @notice Governance cycle timing and execution status
    /// @dev Each cycle has one proposal window, one voting window, and at most one winning proposal
    struct Cycle {
        uint256 proposalWindowStart;
        uint256 proposalWindowEnd;
        uint256 votingWindowEnd;
        bool executed;
    }

    mapping(uint256 => Cycle) private _cycles;
    mapping(uint256 => ILevrGovernor_v1.Proposal) private _proposals;
    mapping(uint256 => mapping(address => ILevrGovernor_v1.VoteReceipt)) private _voteReceipts;
    mapping(ILevrGovernor_v1.ProposalType => uint256) private _activeProposalCount;
    mapping(uint256 => uint256[]) private _cycleProposals;
    mapping(uint256 => mapping(ILevrGovernor_v1.ProposalType => mapping(address => bool)))
        private _hasProposedInCycle;
    mapping(uint256 => ILevrGovernor_v1.ExecutionAttemptInfo) private _executionAttempts;

    // ============ Constructor ============

    constructor(address trustedForwarder, address factory_) ERC2771ContextBase(trustedForwarder) {
        if (factory_ == address(0)) revert InvalidRecipient();
        factory = factory_;
    }

    /// @notice Initialize the cloned governor
    /// @dev Can only be called once per clone. Only callable by factory to prevent frontrunning.
    function initialize(
        address treasury_,
        address staking_,
        address stakedToken_,
        address underlying_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (_msgSender() != factory) revert ILevrGovernor_v1.OnlyFactory();
        if (treasury_ == address(0)) revert InvalidRecipient();
        if (staking_ == address(0)) revert InvalidRecipient();
        if (stakedToken_ == address(0)) revert InvalidRecipient();
        if (underlying_ == address(0)) revert InvalidRecipient();

        _initialized = true;
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

        // Get balance for quorum
        uint256 voterBalance = IERC20(stakedToken).balanceOf(voter);

        // Prevent flash loan attacks by requiring at least 1 block since last stake
        // Flash loans cannot span multiple blocks, so this protects against manipulation
        uint256 lastStake = ILevrStaking_v1(staking).lastStakeBlock(voter);
        uint256 minBlocksSinceStake = 1;
        if (block.number < lastStake + minBlocksSinceStake) revert StakeActionTooRecent();

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
        if (_needsNewCycle()) {
            // Manual cycle advancement requires 3+ failed execution attempts
            _checkNoExecutableProposals(true);
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

        // Verify proposal is from current cycle
        // Allows retry attempts within the same cycle
        if (proposal.cycleId != _currentCycleId) {
            revert ProposalNotInCurrentCycle();
        }

        // Enforce delay between execution attempts to prevent griefing
        ILevrGovernor_v1.ExecutionAttemptInfo storage attemptInfo = _executionAttempts[proposalId];
        if (attemptInfo.lastAttemptTime > 0) {
            if (block.timestamp < attemptInfo.lastAttemptTime + EXECUTION_ATTEMPT_DELAY) {
                revert ExecutionAttemptTooSoon();
            }
        }

        // Mark as defeated if quorum not met
        if (!_meetsQuorum(proposalId)) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Mark as defeated if approval threshold not met
        if (!_meetsApproval(proposalId)) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Verify this is the winning proposal for the cycle
        uint256 winnerId = _getWinner(proposal.cycleId);
        if (winnerId != proposalId) {
            revert NotWinner();
        }

        // Verify cycle hasn't already executed a proposal
        Cycle storage cycle = _cycles[proposal.cycleId];
        if (cycle.executed) {
            revert AlreadyExecuted();
        }

        // Attempt execution with graceful failure handling
        try
            this._executeProposal(
                proposalId,
                proposal.proposalType,
                proposal.token,
                proposal.amount,
                proposal.recipient
            )
        {
            // Execution succeeded
            proposal.executed = true;
            cycle.executed = true;
            emit ProposalExecuted(proposalId, _msgSender());
        } catch {
            // Execution failed - track attempt and allow retry after delay
            attemptInfo.count++;
            attemptInfo.lastAttemptTime = uint64(block.timestamp);
            emit ProposalExecutionFailed(proposalId, 'execution_failed');
        }
    }

    /// @notice Internal execution helper (external visibility required for try-catch pattern)
    /// @dev Only callable by this contract to prevent unauthorized treasury access
    /// @param proposalType Type of proposal (BoostStakingPool or TransferToAddress)
    /// @param token ERC20 token address
    /// @param amount Amount to transfer
    /// @param recipient Recipient address (for TransferToAddress type)
    function _executeProposal(
        uint256, // proposalId - reserved for future use
        ProposalType proposalType,
        address token,
        uint256 amount,
        address recipient
    ) external {
        // Only callable by this contract
        if (_msgSender() != address(this)) revert ILevrGovernor_v1.InternalOnly();

        if (proposalType == ProposalType.BoostStakingPool) {
            ILevrTreasury_v1(treasury).transfer(token, staking, amount);
            // Accrual is permissionless; swallow errors so boosts can't be blocked
            try ILevrStaking_v1(staking).accrueRewards(token) {} catch {}
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
    function executionAttempts(
        uint256 proposalId
    ) external view returns (ExecutionAttemptInfo memory) {
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

        // Auto-start new cycle if needed
        if (_needsNewCycle()) {
            _checkNoExecutableProposals(false);
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

        // Enforce rate limits
        if (
            _activeProposalCount[proposalType] >=
            ILevrFactory_v1(factory).maxActiveProposals(underlying)
        ) {
            revert MaxProposalsReached();
        }
        if (_hasProposedInCycle[cycleId][proposalType][proposer]) {
            revert AlreadyProposedInCycle();
        }

        // Create proposal with snapshotted configuration
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
    ///      In cycle-based governance, only the winner can succeed
    /// @param proposalId The proposal ID to check
    /// @return The current proposal state
    function _state(uint256 proposalId) internal view returns (ProposalState) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        if (proposal.id == 0) revert InvalidProposalType();

        // Terminal state: Executed (only set on successful execution)
        if (proposal.executed) return ProposalState.Executed;

        // Proposals from previous cycles are expired and cannot be executed
        if (proposal.cycleId < _currentCycleId) {
            return ProposalState.Defeated;
        }

        // Time-based states
        if (block.timestamp < proposal.votingStartsAt) return ProposalState.Pending;
        if (block.timestamp <= proposal.votingEndsAt) return ProposalState.Active;

        // Post-voting states: Check if proposal met voting thresholds
        if (!_meetsQuorum(proposalId) || !_meetsApproval(proposalId)) {
            return ProposalState.Defeated;
        }

        // Only the cycle winner can succeed; non-winners are defeated
        uint256 winnerId = _getWinner(proposal.cycleId);
        if (winnerId != proposalId) {
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

                // Winner determined by approval ratio to prevent strategic voting
                uint256 approvalRatio = (proposal.yesVotes * 10000) / totalVotes;

                if (approvalRatio > bestApprovalRatio) {
                    bestApprovalRatio = approvalRatio;
                    winnerId = pid;
                }
            }
        }

        return winnerId;
    }

    /// @dev Determine if a new cycle should be started
    function _needsNewCycle() internal view returns (bool) {
        if (_currentCycleId == 0) return true;

        Cycle memory cycle = _cycles[_currentCycleId];
        return block.timestamp > cycle.votingWindowEnd;
    }

    /// @notice Starts a new governance cycle
    /// @dev Called automatically when proposing after voting ends, or manually via startNewCycle()
    function _startNewCycle() internal {
        uint32 proposalWindow = ILevrFactory_v1(factory).proposalWindowSeconds(underlying);
        uint32 votingWindow = ILevrFactory_v1(factory).votingWindowSeconds(underlying);

        uint256 cycleId = ++_currentCycleId;
        uint256 start = block.timestamp;
        uint256 proposalEnd = start + proposalWindow;
        uint256 voteEnd = proposalEnd + votingWindow;

        // Reset proposal counts for the new cycle
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

    /// @notice Validates that cycle advancement is safe
    /// @dev Prevents advancing while proposals are active or executable
    /// @param enforceAttempts If true, allow advancement after 3+ failed execution attempts
    function _checkNoExecutableProposals(bool enforceAttempts) internal view {
        uint256[] memory proposals = _cycleProposals[_currentCycleId];

        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 pid = proposals[i];
            ILevrGovernor_v1.Proposal storage proposal = _proposals[pid];

            // Skip already executed proposals
            if (proposal.executed) continue;

            ProposalState currentState = _state(pid);

            // Block if voting is still in progress
            if (currentState == ProposalState.Pending || currentState == ProposalState.Active) {
                revert ExecutableProposalsRemaining();
            }

            // Block if proposal succeeded and hasn't been executed
            if (currentState == ProposalState.Succeeded) {
                if (!enforceAttempts) {
                    // Auto-advancement: must execute winning proposal first
                    revert ExecutableProposalsRemaining();
                } else {
                    // Manual advancement: require 3+ failed attempts
                    if (_executionAttempts[pid].count < 3) {
                        revert ExecutableProposalsRemaining();
                    }
                }
            }
        }
    }
}
