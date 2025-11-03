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

    // Governance cycle timing
    struct Cycle {
        uint256 proposalWindowStart;
        uint256 proposalWindowEnd;
        uint256 votingWindowEnd;
        bool executed; // Track if a proposal has been executed for this cycle
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
        // Permissionless cycle recovery if current cycle has ended
        if (_currentCycleId == 0) {
            _startNewCycle();
        } else if (_needsNewCycle()) {
            _checkNoExecutableProposals();
            _startNewCycle();
        } else {
            revert CycleStillActive();
        }
    }

    /// @inheritdoc ILevrGovernor_v1
    function execute(uint256 proposalId) external nonReentrant {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Check voting ended
        if (block.timestamp <= proposal.votingEndsAt) {
            revert VotingNotEnded();
        }

        // Check not already executed
        if (proposal.executed) {
            revert AlreadyExecuted();
        }

        // Defeat if quorum not met (state persists to prevent retry attacks)
        if (!_meetsQuorum(proposalId)) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Defeat if approval not met
        if (!_meetsApproval(proposalId)) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Defeat if treasury lacks sufficient balance
        uint256 treasuryBalance = IERC20(proposal.token).balanceOf(treasury);
        if (treasuryBalance < proposal.amount) {
            proposal.executed = true;
            emit ProposalDefeated(proposalId);
            return;
        }

        // Check this is the winner for the cycle
        uint256 winnerId = _getWinner(proposal.cycleId);
        if (winnerId != proposalId) {
            revert NotWinner();
        }

        // Mark cycle as having executed a proposal
        Cycle storage cycle = _cycles[proposal.cycleId];
        if (cycle.executed) {
            revert AlreadyExecuted();
        }
        cycle.executed = true;

        // Mark executed before external calls (prevents reverting tokens from blocking cycle)
        proposal.executed = true;

        // Execute proposal (try-catch handles reverting tokens gracefully)
        try
            this._executeProposal(
                proposalId,
                proposal.proposalType,
                proposal.token,
                proposal.amount,
                proposal.recipient
            )
        {
            emit ProposalExecuted(proposalId, _msgSender());
        } catch Error(string memory reason) {
            emit ProposalExecutionFailed(proposalId, reason);
        } catch (bytes memory) {
            emit ProposalExecutionFailed(proposalId, 'execution_reverted');
        }

        // Automatically start new cycle after execution attempt (executor pays gas)
        _startNewCycle();
    }

    /// @notice Internal execution helper (external visibility for try-catch pattern)
    /// @dev Only callable by this contract to prevent unauthorized treasury access
    function _executeProposal(
        uint256, // proposalId - unused but kept for future extensibility
        ProposalType proposalType,
        address token,
        uint256 amount,
        address recipient
    ) external {
        // Only callable by this contract (via try-catch)
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

    function _state(uint256 proposalId) internal view returns (ProposalState) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        if (proposal.id == 0) revert InvalidProposalType();
        if (proposal.executed) return ProposalState.Executed;
        if (block.timestamp < proposal.votingStartsAt) return ProposalState.Pending;
        if (block.timestamp <= proposal.votingEndsAt) return ProposalState.Active;

        // After voting: check quorum and approval
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

    /// @dev Start a new governance cycle
    function _startNewCycle() internal {
        uint32 proposalWindow = ILevrFactory_v1(factory).proposalWindowSeconds(underlying);
        uint32 votingWindow = ILevrFactory_v1(factory).votingWindowSeconds(underlying);

        uint256 cycleId = ++_currentCycleId;
        uint256 start = block.timestamp;
        uint256 proposalEnd = start + proposalWindow;
        uint256 voteEnd = proposalEnd + votingWindow;

        // Reset proposal counts (proposals are cycle-scoped)
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

    /// @dev Prevent cycle advancement if executable proposals remain (prevents orphaning)
    function _checkNoExecutableProposals() internal view {
        uint256[] memory proposals = _cycleProposals[_currentCycleId];
        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 pid = proposals[i];
            ILevrGovernor_v1.Proposal storage proposal = _proposals[pid];

            if (proposal.executed) continue;

            if (_state(pid) == ProposalState.Succeeded) {
                revert ExecutableProposalsRemaining();
            }
        }
    }
}
