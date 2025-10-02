// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrGovernor_v1} from './interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from './interfaces/ILevrFactory_v1.sol';
import {ILevrTreasury_v1} from './interfaces/ILevrTreasury_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';

contract LevrGovernor_v1 is ILevrGovernor_v1, ERC2771ContextBase {
  address public immutable factory;
  address public immutable treasury;
  address public immutable stakedToken;

  uint256 public nextProposalId = 1;
  mapping(uint256 => Proposal) private _proposals;

  // rolling submission counters per type per 7-day window (week index)
  // proposalType: 0 => Transfer, 1 => Boost (matches enum ordering)
  mapping(uint8 => mapping(uint64 => uint16)) private _submissionsPerWeek;

  constructor(
    address factory_,
    address treasury_,
    address stakedToken_,
    address trustedForwarder
  ) ERC2771ContextBase(trustedForwarder) {
    require(factory_ != address(0) && treasury_ != address(0) && stakedToken_ != address(0), 'ZERO');
    factory = factory_;
    treasury = treasury_;
    stakedToken = stakedToken_;
  }

  /// @inheritdoc ILevrGovernor_v1
  function proposeTransfer(
    address receiver,
    uint256 amount,
    string calldata reason
  ) external returns (uint256 proposalId) {
    address proposer = _msgSender();
    _requireCanSubmit(proposer);
    if (amount == 0) revert InvalidAmount();
    _enforceAndBumpRateLimit(uint8(ProposalType.Transfer));
    proposalId = _createProposal(proposer, ProposalType.Transfer, receiver, amount, reason);
  }

  /// @inheritdoc ILevrGovernor_v1
  function proposeBoost(uint256 amount) external returns (uint256 proposalId) {
    address proposer = _msgSender();
    _requireCanSubmit(proposer);
    if (amount == 0) revert InvalidAmount();
    _enforceAndBumpRateLimit(uint8(ProposalType.Boost));
    proposalId = _createProposal(proposer, ProposalType.Boost, address(0), amount, '');
  }

  /// @inheritdoc ILevrGovernor_v1
  function execute(uint256 proposalId) external {
    Proposal storage p = _proposals[proposalId];
    if (p.deadline == 0) revert NotAuthorized();
    if (block.timestamp > p.deadline) revert DeadlinePassed();
    if (p.executed) revert AlreadyExecuted();
    p.executed = true;

    if (p.proposalType == ProposalType.Transfer) {
      ILevrTreasury_v1(treasury).transfer(p.receiver, p.amount);
    } else {
      ILevrTreasury_v1(treasury).applyBoost(p.amount);
    }
    emit ProposalExecuted(proposalId);
  }

  /// @inheritdoc ILevrGovernor_v1
  function getProposal(uint256 proposalId) external view returns (Proposal memory) {
    return _proposals[proposalId];
  }

  /// @inheritdoc ILevrGovernor_v1
  function canSubmit(address proposer) external view returns (bool) {
    return _hasMinBalance(proposer);
  }

  function _requireCanSubmit(address proposer) internal view {
    if (!_hasMinBalance(proposer)) revert NotAuthorized();
  }

  function _createProposal(
    address proposer,
    ProposalType proposalType,
    address receiver,
    uint256 amount,
    string memory reason
  ) internal returns (uint256 proposalId) {
    uint32 deadline = uint32(block.timestamp + ILevrFactory_v1(factory).submissionDeadlineSeconds());
    proposalId = nextProposalId++;
    _proposals[proposalId] = Proposal({
      proposer: proposer,
      proposalType: proposalType,
      receiver: receiver,
      amount: amount,
      reason: reason,
      deadline: deadline,
      executed: false
    });
    emit ProposalCreated(proposalId, proposalType, proposer);
  }

  function _hasMinBalance(address proposer) internal view returns (bool) {
    uint256 minBal = ILevrFactory_v1(factory).minWTokenToSubmit();
    return ILevrStakedToken_v1(stakedToken).balanceOf(proposer) >= minBal;
  }

  function _enforceAndBumpRateLimit(uint8 pType) internal {
    uint16 maxSubmissions = ILevrFactory_v1(factory).maxSubmissionPerType();
    if (maxSubmissions == 0) return; // unlimited
    uint64 week = _currentWeekIndex();
    uint16 used = _submissionsPerWeek[pType][week];
    if (used >= maxSubmissions) revert RateLimitExceeded();
    _submissionsPerWeek[pType][week] = used + 1;
  }

  function _currentWeekIndex() internal view returns (uint64) {
    // 7-day rolling windows
    return uint64(block.timestamp / 604800);
  }
}
