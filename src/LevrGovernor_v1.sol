// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ILevrGovernor_v1} from "./interfaces/ILevrGovernor_v1.sol";
import {ILevrFactory_v1} from "./interfaces/ILevrFactory_v1.sol";
import {ILevrTreasury_v1} from "./interfaces/ILevrTreasury_v1.sol";
import {ILevrERC20} from "./interfaces/ILevrERC20.sol";

contract LevrGovernor_v1 is ILevrGovernor_v1 {
    address public immutable factory;
    address public immutable treasury;
    address public immutable wrapper;

    uint256 public nextProposalId = 1;
    mapping(uint256 => Proposal) private _proposals;

    constructor(address factory_, address treasury_, address wrapper_) {
        require(
            factory_ != address(0) &&
                treasury_ != address(0) &&
                wrapper_ != address(0),
            "ZERO"
        );
        factory = factory_;
        treasury = treasury_;
        wrapper = wrapper_;
    }

    /// @inheritdoc ILevrGovernor_v1
    function proposeTransfer(
        address receiver,
        uint256 amount,
        string calldata reason,
        uint8 tier
    ) external returns (uint256 proposalId) {
        _requireCanSubmit(msg.sender);
        _validateTierAmount(true, tier, amount);
        proposalId = _createProposal(
            msg.sender,
            ProposalType.Transfer,
            receiver,
            amount,
            reason,
            tier
        );
    }

    /// @inheritdoc ILevrGovernor_v1
    function proposeBoost(
        uint256 amount,
        uint8 tier
    ) external returns (uint256 proposalId) {
        _requireCanSubmit(msg.sender);
        _validateTierAmount(false, tier, amount);
        proposalId = _createProposal(
            msg.sender,
            ProposalType.Boost,
            address(0),
            amount,
            "",
            tier
        );
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
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory) {
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
        string memory reason,
        uint8 tier
    ) internal returns (uint256 proposalId) {
        uint32 deadline = uint32(
            block.timestamp +
                ILevrFactory_v1(factory).submissionDeadlineSeconds()
        );
        proposalId = nextProposalId++;
        _proposals[proposalId] = Proposal({
            proposer: proposer,
            proposalType: proposalType,
            receiver: receiver,
            amount: amount,
            reason: reason,
            tier: tier,
            deadline: deadline,
            executed: false
        });
        emit ProposalCreated(proposalId, proposalType, proposer);
    }

    function _hasMinBalance(address proposer) internal view returns (bool) {
        uint256 minBal = ILevrFactory_v1(factory).minWTokenToSubmit();
        return ILevrERC20(wrapper).balanceOf(proposer) >= minBal;
    }

    function _validateTierAmount(
        bool isTransfer,
        uint8 tier,
        uint256 amount
    ) internal view {
        if (amount == 0) revert InvalidAmount();
        uint256 count = isTransfer
            ? ILevrFactory_v1(factory).getTransferTierCount()
            : ILevrFactory_v1(factory).getStakingBoostTierCount();
        if (tier >= count) revert TierOutOfBounds();
        uint256 limit = isTransfer
            ? ILevrFactory_v1(factory).getTransferTier(tier)
            : ILevrFactory_v1(factory).getStakingBoostTier(tier);
        if (amount > limit) revert InvalidAmount();
    }
}
