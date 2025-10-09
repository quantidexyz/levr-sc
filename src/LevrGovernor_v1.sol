// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    // VP snapshots per proposal
    mapping(uint256 => mapping(address => uint256)) private _vpSnapshot;

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
    function proposeBoost(uint256 amount) external returns (uint256 proposalId) {
        return _propose(ProposalType.BoostStakingPool, amount, address(0), '');
    }

    /// @inheritdoc ILevrGovernor_v1
    function proposeTransfer(
        address recipient,
        uint256 amount,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (recipient == address(0)) revert InvalidRecipient();
        return _propose(ProposalType.TransferToAddress, amount, recipient, description);
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

        // Calculate user's VP at proposal creation time (snapshot)
        uint256 votes = _calculateVPAtSnapshot(proposalId, voter);

        // HIGH FIX [H-2]: Prevent 0 VP votes
        if (votes == 0) revert InsufficientVotingPower();

        // Get user's balance for quorum tracking
        uint256 voterBalance = IERC20(stakedToken).balanceOf(voter);

        // Store in snapshot mapping for later queries
        if (_vpSnapshot[proposalId][voter] == 0) {
            _vpSnapshot[proposalId][voter] = votes;
        }

        // Record vote (VP for yes/no tallying)
        if (support) {
            proposal.yesVotes += votes;
        } else {
            proposal.noVotes += votes;
        }

        // Track balance participation for quorum
        proposal.totalBalanceVoted += voterBalance;

        _voteReceipts[proposalId][voter] = VoteReceipt({
            hasVoted: true,
            support: support,
            votes: votes
        });

        emit VoteCast(voter, proposalId, support, votes);
    }

    /// @inheritdoc ILevrGovernor_v1
    function execute(uint256 proposalId) external nonReentrant {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Check voting ended
        if (block.timestamp <= proposal.votingEndsAt) {
            revert VotingNotActive();
        }

        // Check not already executed
        if (proposal.executed) {
            revert AlreadyExecuted();
        }

        // Check quorum
        if (!_meetsQuorum(proposalId)) {
            proposal.executed = true; // Mark as processed
            emit ProposalDefeated(proposalId);
            _activeProposalCount[proposal.proposalType]--;
            revert ProposalNotSucceeded();
        }

        // Check approval
        if (!_meetsApproval(proposalId)) {
            proposal.executed = true; // Mark as processed
            emit ProposalDefeated(proposalId);
            _activeProposalCount[proposal.proposalType]--;
            revert ProposalNotSucceeded();
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

        // Execute the proposal
        proposal.executed = true;
        _activeProposalCount[proposal.proposalType]--;

        if (proposal.proposalType == ProposalType.BoostStakingPool) {
            ILevrTreasury_v1(treasury).applyBoost(proposal.amount);
        } else if (proposal.proposalType == ProposalType.TransferToAddress) {
            ILevrTreasury_v1(treasury).transfer(proposal.recipient, proposal.amount);
        }

        emit ProposalExecuted(proposalId, _msgSender());

        // Automatically start new cycle after successful execution (executor pays gas)
        _startNewCycle();
    }

    // ============ View Functions ============

    /// @inheritdoc ILevrGovernor_v1
    function state(uint256 proposalId) external view returns (ProposalState) {
        return _state(proposalId);
    }

    /// @inheritdoc ILevrGovernor_v1
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
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
    function getVotingPowerSnapshot(
        uint256 proposalId,
        address user
    ) external view returns (uint256) {
        // If already calculated and stored, return it
        uint256 stored = _vpSnapshot[proposalId][user];
        if (stored > 0) return stored;

        // Otherwise calculate on-demand
        return _calculateVPAtSnapshot(proposalId, user);
    }

    /// @inheritdoc ILevrGovernor_v1
    function activeProposalCount(ProposalType proposalType) external view returns (uint256) {
        return _activeProposalCount[proposalType];
    }

    // ============ Internal Functions ============

    function _propose(
        ProposalType proposalType,
        uint256 amount,
        address recipient,
        string memory description
    ) internal returns (uint256 proposalId) {
        if (amount == 0) revert InvalidAmount();

        address proposer = _msgSender();

        // Auto-start new cycle if none exists or current cycle has ended
        if (_currentCycleId == 0 || _needsNewCycle()) {
            _startNewCycle();
        }

        uint256 cycleId = _currentCycleId;
        Cycle memory cycle = _cycles[cycleId];

        // Check proposal window is open (should always be true after auto-start)
        if (
            block.timestamp < cycle.proposalWindowStart || block.timestamp > cycle.proposalWindowEnd
        ) {
            revert ProposalWindowClosed();
        }

        // Check minimum stake requirement
        uint16 minStakeBps = ILevrFactory_v1(factory).minSTokenBpsToSubmit();
        if (minStakeBps > 0) {
            uint256 totalSupply = IERC20(stakedToken).totalSupply();
            uint256 minStake = (totalSupply * minStakeBps) / 10_000;
            uint256 proposerBalance = IERC20(stakedToken).balanceOf(proposer);
            if (proposerBalance < minStake) {
                revert InsufficientStake();
            }
        }

        // Check max active proposals per type
        uint16 maxActive = ILevrFactory_v1(factory).maxActiveProposals();
        if (_activeProposalCount[proposalType] >= maxActive) {
            revert MaxProposalsReached();
        }

        // Check user hasn't already proposed this type in this cycle
        if (_hasProposedInCycle[cycleId][proposalType][proposer]) {
            revert AlreadyProposedInCycle();
        }

        // Create proposal
        proposalId = ++_proposalCount;

        _proposals[proposalId] = Proposal({
            id: proposalId,
            proposalType: proposalType,
            proposer: proposer,
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
            cycleId: cycleId
        });

        _activeProposalCount[proposalType]++;
        _cycleProposals[cycleId].push(proposalId);

        // Mark that user has proposed this type in this cycle
        _hasProposedInCycle[cycleId][proposalType][proposer] = true;

        emit ProposalCreated(proposalId, proposer, proposalType, amount, recipient, description);
    }

    function _calculateVPAtSnapshot(
        uint256 proposalId,
        address user
    ) internal view returns (uint256) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // Get user's staked balance (current balance)
        uint256 balance = IERC20(stakedToken).balanceOf(user);
        if (balance == 0) return 0;

        // Get user's stakeStartTime
        uint256 startTime = ILevrStaking_v1(staking).stakeStartTime(user);

        // HIGH FIX [H-2]: If user staked after proposal was created, they have 0 VP for this proposal
        // Changed from >= to > for correct timing
        if (startTime == 0 || startTime > proposal.createdAt) {
            return 0;
        }

        // Calculate VP: balance × time_staked_at_proposal_creation
        uint256 timeStaked = proposal.createdAt - startTime;
        return balance * timeStaked;
    }

    function _state(uint256 proposalId) internal view returns (ProposalState) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        if (proposal.id == 0) revert InvalidProposalType(); // Proposal doesn't exist

        if (proposal.executed) return ProposalState.Executed;

        if (block.timestamp < proposal.votingStartsAt) return ProposalState.Pending;

        if (block.timestamp <= proposal.votingEndsAt) return ProposalState.Active;

        // After voting ends
        if (!_meetsQuorum(proposalId) || !_meetsApproval(proposalId)) {
            return ProposalState.Defeated;
        }

        return ProposalState.Succeeded;
    }

    function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];
        uint16 quorumBps = ILevrFactory_v1(factory).quorumBps();

        // If quorum is 0, no participation requirement
        if (quorumBps == 0) return true;

        // Quorum is based on participation rate: balance that voted / total supply
        // Not based on VP (which includes time weighting)
        uint256 totalSupply = IERC20(stakedToken).totalSupply();
        if (totalSupply == 0) return false;

        uint256 requiredQuorum = (totalSupply * quorumBps) / 10_000;

        return proposal.totalBalanceVoted >= requiredQuorum;
    }

    function _meetsApproval(uint256 proposalId) internal view returns (bool) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];
        uint16 approvalBps = ILevrFactory_v1(factory).approvalBps();

        // If approval is 0, no approval requirement
        if (approvalBps == 0) return true;

        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        if (totalVotes == 0) return false;

        uint256 requiredApproval = (totalVotes * approvalBps) / 10_000;

        return proposal.yesVotes >= requiredApproval;
    }

    function _getWinner(uint256 cycleId) internal view returns (uint256 winnerId) {
        uint256[] memory proposals = _cycleProposals[cycleId];
        uint256 maxYesVotes = 0;

        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 pid = proposals[i];
            ILevrGovernor_v1.Proposal storage proposal = _proposals[pid];

            // Check if proposal meets quorum and approval
            if (_meetsQuorum(pid) && _meetsApproval(pid)) {
                if (proposal.yesVotes > maxYesVotes) {
                    maxYesVotes = proposal.yesVotes;
                    winnerId = pid;
                }
            }
        }

        return winnerId; // Returns 0 if no winner
    }

    /// @dev Check if a new cycle needs to be started
    function _needsNewCycle() internal view returns (bool) {
        if (_currentCycleId == 0) return true;

        Cycle memory cycle = _cycles[_currentCycleId];

        // New cycle needed if voting window has ended
        return block.timestamp > cycle.votingWindowEnd;
    }

    /// @dev Internal function to start a new governance cycle
    function _startNewCycle() internal {
        // Get config from factory
        uint32 proposalWindow = ILevrFactory_v1(factory).proposalWindowSeconds();
        uint32 votingWindow = ILevrFactory_v1(factory).votingWindowSeconds();

        uint256 cycleId = ++_currentCycleId;
        uint256 start = block.timestamp;
        uint256 proposalEnd = start + proposalWindow;
        uint256 voteEnd = proposalEnd + votingWindow;

        _cycles[cycleId] = Cycle({
            proposalWindowStart: start,
            proposalWindowEnd: proposalEnd,
            votingWindowEnd: voteEnd,
            executed: false
        });

        emit CycleStarted(cycleId, start, proposalEnd, voteEnd);
    }
}
