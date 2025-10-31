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
        if (token == address(0)) revert InvalidRecipient(); // Reusing error for zero address
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

        // Get user's current voting power from staking contract
        // VP = balance × time staked (naturally protects against last-minute gaming)
        uint256 votes = ILevrStaking_v1(staking).getVotingPower(voter);

        // Prevent 0 VP votes
        if (votes == 0) revert InsufficientVotingPower();

        // Get user's balance for quorum tracking
        uint256 voterBalance = IERC20(stakedToken).balanceOf(voter);

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
    function startNewCycle() external {
        // Allow anyone to start a new cycle if current one has ended
        // This helps recover from failed cycles where no proposals were executed
        if (_currentCycleId == 0) {
            _startNewCycle();
        } else if (_needsNewCycle()) {
            // Check for orphan proposals before advancing cycle
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
            // FIX [NEW-C-4]: Only decrement if count > 0 to prevent underflow
            // (can be 0 if new cycle already started and reset the count)
            if (_activeProposalCount[proposal.proposalType] > 0) {
                _activeProposalCount[proposal.proposalType]--;
            }
            revert ProposalNotSucceeded();
        }

        // Check approval
        if (!_meetsApproval(proposalId)) {
            proposal.executed = true; // Mark as processed
            emit ProposalDefeated(proposalId);
            // FIX [NEW-C-4]: Only decrement if count > 0 to prevent underflow
            if (_activeProposalCount[proposal.proposalType] > 0) {
                _activeProposalCount[proposal.proposalType]--;
            }
            revert ProposalNotSucceeded();
        }

        // TOKEN AGNOSTIC: Check treasury has sufficient balance for proposal token and amount
        uint256 treasuryBalance = IERC20(proposal.token).balanceOf(treasury);
        if (treasuryBalance < proposal.amount) {
            proposal.executed = true; // Mark as processed to avoid retries
            emit ProposalDefeated(proposalId);
            // FIX [NEW-C-4]: Only decrement if count > 0 to prevent underflow
            if (_activeProposalCount[proposal.proposalType] > 0) {
                _activeProposalCount[proposal.proposalType]--;
            }
            revert InsufficientTreasuryBalance();
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

        // FIX [TOKEN-AGNOSTIC-DOS]: Mark executed BEFORE attempting execution
        // to prevent reverting tokens (pausable, blocklist, fee-on-transfer) from blocking cycle
        proposal.executed = true;
        // FIX [NEW-C-4]: Only decrement if count > 0 to prevent underflow
        if (_activeProposalCount[proposal.proposalType] > 0) {
            _activeProposalCount[proposal.proposalType]--;
        }

        // TOKEN AGNOSTIC: Execute with proposal.token
        // Wrapped in try-catch to handle reverting tokens without blocking governance
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

    /// @notice Internal execution helper callable via try-catch
    /// @dev External but only callable by this contract (checked in try-catch pattern)
    function _executeProposal(
        uint256, // proposalId - unused but kept for future extensibility
        ProposalType proposalType,
        address token,
        uint256 amount,
        address recipient
    ) external {
        // Only callable by this contract (via try-catch)
        require(_msgSender() == address(this), 'INTERNAL_ONLY');

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
        if (token == address(0)) revert InvalidRecipient(); // Token must be valid

        address proposer = _msgSender();

        // Auto-start new cycle if none exists or current cycle has ended
        if (_currentCycleId == 0 || _needsNewCycle()) {
            // Check for orphan proposals before advancing cycle
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
            uint16 minStakeBps = ILevrFactory_v1(factory).minSTokenBpsToSubmit();
            if (minStakeBps > 0) {
                uint256 totalSupply = IERC20(stakedToken).totalSupply();
                if (
                    IERC20(stakedToken).balanceOf(proposer) < (totalSupply * minStakeBps) / 10_000
                ) {
                    revert InsufficientStake();
                }
            }
        }

        // Validate treasury balance and proposal amount
        uint256 treasuryBalance;
        {
            treasuryBalance = IERC20(token).balanceOf(treasury);
            if (treasuryBalance < amount) {
                revert InsufficientTreasuryBalance();
            }

            uint16 maxProposalBps = ILevrFactory_v1(factory).maxProposalAmountBps();
            if (maxProposalBps > 0 && amount > (treasuryBalance * maxProposalBps) / 10_000) {
                revert ProposalAmountExceedsLimit();
            }
        }

        // Check max active proposals per type
        if (_activeProposalCount[proposalType] >= ILevrFactory_v1(factory).maxActiveProposals()) {
            revert MaxProposalsReached();
        }

        // Check user hasn't already proposed this type in this cycle
        if (_hasProposedInCycle[cycleId][proposalType][proposer]) {
            revert AlreadyProposedInCycle();
        }

        // Create proposal with snapshots
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
                quorumBpsSnapshot: ILevrFactory_v1(factory).quorumBps(),
                approvalBpsSnapshot: ILevrFactory_v1(factory).approvalBps()
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

        // FIX [NEW-C-1, NEW-C-2]: Use snapshot instead of current quorum threshold
        // Prevents manipulation via config changes after proposal creation
        uint16 quorumBps = proposal.quorumBpsSnapshot;

        // If quorum is 0, no participation requirement
        if (quorumBps == 0) return true;

        // FIX [NEW-C-1, NEW-C-2]: Use snapshot instead of current total supply
        // Prevents manipulation via staking/unstaking after voting ends
        // Quorum uses staked token balance (not VP) to measure participation rate.
        // This two-tier system ensures:
        // 1. Quorum: Democratic participation (all stakers equal)
        // 2. Approval: Time-weighted influence (VP rewards long-term commitment)
        uint256 snapshotSupply = proposal.totalSupplySnapshot;
        if (snapshotSupply == 0) return false;

        // ADAPTIVE QUORUM: Use lower of snapshot vs current supply
        // - If supply increased → use snapshot (anti-dilution protection)
        // - If supply decreased → use current (anti-deadlock protection)
        uint256 currentSupply = IERC20(stakedToken).totalSupply();
        uint256 effectiveSupply = currentSupply < snapshotSupply ? currentSupply : snapshotSupply;

        // Calculate percentage-based quorum from effective supply
        uint256 percentageQuorum = (effectiveSupply * quorumBps) / 10_000;

        // MINIMUM ABSOLUTE QUORUM: Prevent early governance capture
        // Use SNAPSHOT supply for minimum (not current) to avoid breaking anti-dilution
        // When supply increases: snapshot is used for both percentage and minimum
        // When supply decreases: current is used for percentage, snapshot for minimum
        uint16 minimumQuorumBps = ILevrFactory_v1(factory).minimumQuorumBps();
        uint256 minimumAbsoluteQuorum = (snapshotSupply * minimumQuorumBps) / 10_000;

        // Use whichever is higher: percentage quorum or minimum absolute quorum
        uint256 requiredQuorum = percentageQuorum > minimumAbsoluteQuorum
            ? percentageQuorum
            : minimumAbsoluteQuorum;

        return proposal.totalBalanceVoted >= requiredQuorum;
    }

    function _meetsApproval(uint256 proposalId) internal view returns (bool) {
        ILevrGovernor_v1.Proposal storage proposal = _proposals[proposalId];

        // FIX [NEW-C-3]: Use snapshot instead of current approval threshold
        // Prevents manipulation via config changes after proposal creation
        uint16 approvalBps = proposal.approvalBpsSnapshot;

        // If approval is 0, no approval requirement
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

            // Check if proposal meets quorum and approval
            if (_meetsQuorum(pid) && _meetsApproval(pid)) {
                // FIX [H-2]: Use approval ratio (YES / TOTAL) instead of absolute YES votes
                // This prevents strategic NO voting from manipulating the winner
                uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
                if (totalVotes == 0) continue; // Skip if no votes (shouldn't happen if quorum met)

                // Calculate approval ratio: (yesVotes * 10000) / totalVotes
                // Using 10000 multiplier for precision
                uint256 approvalRatio = (proposal.yesVotes * 10000) / totalVotes;

                if (approvalRatio > bestApprovalRatio) {
                    bestApprovalRatio = approvalRatio;
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

        // FIX [NEW-C-4]: Reset active proposal counts when starting new cycle
        // Proposals are scoped to cycles, so counts should reset each cycle
        // This prevents permanent gridlock from defeated proposals consuming slots
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

    /// @dev Check if there are any executable (Succeeded) proposals in the current cycle
    /// @notice Reverts if found to prevent orphaning proposals when advancing cycles
    function _checkNoExecutableProposals() internal view {
        uint256[] memory proposals = _cycleProposals[_currentCycleId];
        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 pid = proposals[i];
            ILevrGovernor_v1.Proposal storage proposal = _proposals[pid];

            // Skip already executed proposals
            if (proposal.executed) continue;

            // If proposal is in Succeeded state, it can be executed
            // Prevent cycle advancement to avoid orphaning it
            if (_state(pid) == ProposalState.Succeeded) {
                revert ExecutableProposalsRemaining();
            }
        }
    }
}
