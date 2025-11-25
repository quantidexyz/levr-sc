// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from 'forge-std/Base.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';

import {LevrGovernor_v1} from '../../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../../src/interfaces/ILevrStaking_v1.sol';
import {ERC20_Mock} from '../../mocks/ERC20_Mock.sol';

/// @title LevrGovernor_v1 handler
/// @notice Stateful harness that exercises governor boost proposals for invariants
/// @dev Exposes ghost variables for invariant assertions via view getters
contract LevrGovernor_v1_Handler is CommonBase, StdUtils {
    LevrGovernor_v1 public immutable governor;
    LevrTreasury_v1 public immutable treasury;
    LevrStaking_v1 public immutable staking;
    ERC20_Mock public immutable underlying;
    ILevrFactory_v1 public immutable factory;

    address internal immutable proposer = address(0xA11CE);

    uint256 private _totalBoostExecuted;
    uint256 private _totalBoostExecutedWithAccrualFailure;
    uint256 private _totalTreasuryRefills;
    uint256 private _pendingAccrualFromFailures;
    uint256 private _initialTreasuryBalance;
    uint256 private _initialStakingBalance;
    uint256 private _lastTreasuryBalanceBeforeExecute;
    uint256 private _lastExecutedAmount;

    uint32 private immutable proposalWindow;
    uint32 private immutable votingWindow;
    uint16 private immutable maxProposalAmountBps;

    constructor(
        LevrGovernor_v1 governor_,
        LevrTreasury_v1 treasury_,
        LevrStaking_v1 staking_,
        ERC20_Mock underlying_,
        ILevrFactory_v1 factory_
    ) {
        governor = governor_;
        treasury = treasury_;
        staking = staking_;
        underlying = underlying_;
        factory = factory_;

        proposalWindow = factory_.proposalWindowSeconds(address(underlying_));
        votingWindow = factory_.votingWindowSeconds(address(underlying_));
        maxProposalAmountBps = factory_.maxProposalAmountBps(address(underlying_));

        // Seed proposer with voting power
        underlying_.mint(proposer, 10_000 ether);
        vm.startPrank(proposer);
        underlying_.approve(address(staking_), type(uint256).max);
        staking_.stake(2_000 ether);
        vm.stopPrank();

        // Allow VP accumulation
        vm.warp(block.timestamp + 10 days);

        _initialTreasuryBalance = underlying_.balanceOf(address(treasury_));
        _initialStakingBalance = underlying_.balanceOf(address(staking_));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Handler Actions

    function executeBoost(uint256 rawAmount) external {
        _executeBoost(rawAmount, false);
    }

    function executeBoostWithAccrualFailure(uint256 rawAmount) external {
        _executeBoost(rawAmount, true);
    }

    function refillTreasury(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1 ether, 100_000 ether);
        underlying.mint(address(treasury), amount);
        _totalTreasuryRefills += amount;
    }

    function settleOutstandingRewards() external {
        if (_pendingAccrualFromFailures == 0) return;
        staking.accrueRewards(address(underlying));
        _pendingAccrualFromFailures = 0;
    }

    function advanceTime(uint256 secondsForward) external {
        uint256 delta = bound(secondsForward, 1, 30 days);
        vm.warp(block.timestamp + delta);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Ghost Variable Getters

    function totalBoostExecuted() external view returns (uint256) {
        return _totalBoostExecuted;
    }

    function totalBoostExecutedWithAccrualFailure() external view returns (uint256) {
        return _totalBoostExecutedWithAccrualFailure;
    }

    function totalTreasuryRefills() external view returns (uint256) {
        return _totalTreasuryRefills;
    }

    function pendingAccrualFromFailures() external view returns (uint256) {
        return _pendingAccrualFromFailures;
    }

    function initialTreasuryBalance() external view returns (uint256) {
        return _initialTreasuryBalance;
    }

    function initialStakingBalance() external view returns (uint256) {
        return _initialStakingBalance;
    }

    function lastTreasuryBalanceBeforeExecute() external view returns (uint256) {
        return _lastTreasuryBalanceBeforeExecute;
    }

    function lastExecutedAmount() external view returns (uint256) {
        return _lastExecutedAmount;
    }

    ///////////////////////////////////////////////////////////////////////////
    // Internal helpers

    function _executeBoost(uint256 rawAmount, bool forceAccrualFailure) internal {
        uint256 treasuryBal = underlying.balanceOf(address(treasury));
        if (treasuryBal == 0) return;

        uint256 maxAmount = (treasuryBal * maxProposalAmountBps) / 10_000;
        if (maxAmount == 0) return;

        uint256 amount = bound(rawAmount, 1e15, maxAmount);

        vm.startPrank(proposer);
        uint256 pid = governor.proposeBoost(address(underlying), amount);
        vm.stopPrank();

        _advanceToVoting();

        vm.prank(proposer);
        governor.vote(pid, true);

        _advanceToExecution();

        if (forceAccrualFailure) {
            vm.mockCallRevert(
                address(staking),
                abi.encodeWithSelector(ILevrStaking_v1.accrueRewards.selector, address(underlying)),
                'ACCRUE_FAIL'
            );
        }

        _lastTreasuryBalanceBeforeExecute = treasuryBal;
        _lastExecutedAmount = amount;
        governor.execute(pid);

        vm.clearMockedCalls();

        _totalBoostExecuted += amount;
        if (forceAccrualFailure) {
            _totalBoostExecutedWithAccrualFailure += amount;
            _pendingAccrualFromFailures += amount;
        } else if (_pendingAccrualFromFailures != 0) {
            _pendingAccrualFromFailures = 0;
        }
    }

    function _advanceToVoting() internal {
        vm.warp(block.timestamp + proposalWindow + 1);
        vm.roll(block.number + 1);
    }

    function _advanceToExecution() internal {
        vm.warp(block.timestamp + votingWindow + 1);
    }
}
