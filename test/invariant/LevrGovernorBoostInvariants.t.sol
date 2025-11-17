// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {CommonBase} from 'forge-std/Base.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';

import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrGovernorBoostInvariants is LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    MockERC20 internal underlying;

    GovernorBoostHandler internal handler;

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(address(0xDEAD));
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);

        // Seed treasury so boosts always have liquidity
        underlying.mint(address(treasury), 1_000_000 ether);

        handler = new GovernorBoostHandler(governor, treasury, staking, underlying, factory);

        targetContract(address(handler));
    }

    function invariant_treasuryNeverDustsAllowance() public view {
        assertEq(
            underlying.allowance(address(treasury), address(staking)),
            0,
            'Treasury must not leave allowance to staking'
        );
    }

    function invariant_boostTransfersConserveUnderlying() public view {
        uint256 treasuryBal = underlying.balanceOf(address(treasury));
        uint256 stakingBal = underlying.balanceOf(address(staking));

        uint256 expectedTreasury = handler.initialTreasuryBalance() +
            handler.totalTreasuryRefills() -
            handler.totalBoostExecuted();
        uint256 expectedStaking = handler.initialStakingBalance() + handler.totalBoostExecuted();

        assertEq(treasuryBal, expectedTreasury, 'Treasury balance mismatch');
        assertEq(stakingBal, expectedStaking, 'Staking balance mismatch');
    }

    function invariant_failedAccrualRewardsRemainOutstanding() public view {
        uint256 outstanding = staking.outstandingRewards(address(underlying));
        assertGe(
            outstanding,
            handler.pendingAccrualFromFailures(),
            'Outstanding rewards must cover failed accrual amounts'
        );
    }
}

contract GovernorBoostHandler is CommonBase, StdUtils {
    LevrGovernor_v1 public immutable governor;
    LevrTreasury_v1 public immutable treasury;
    LevrStaking_v1 public immutable staking;
    MockERC20 public immutable underlying;
    ILevrFactory_v1 public immutable factory;

    address internal immutable proposer = address(0xA11CE);

    uint256 private _totalBoostExecuted;
    uint256 private _totalBoostExecutedWithAccrualFailure;
    uint256 private _totalTreasuryRefills;
    uint256 private _pendingAccrualFromFailures;
    uint256 private _initialTreasuryBalance;
    uint256 private _initialStakingBalance;

    uint32 private immutable proposalWindow;
    uint32 private immutable votingWindow;
    uint16 private immutable maxProposalAmountBps;

    constructor(
        LevrGovernor_v1 governor_,
        LevrTreasury_v1 treasury_,
        LevrStaking_v1 staking_,
        MockERC20 underlying_,
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

        // Give proposer sufficient VP
        underlying_.mint(proposer, 10_000 ether);
        vm.startPrank(proposer);
        underlying_.approve(address(staking_), type(uint256).max);
        staking_.stake(2_000 ether);
        vm.stopPrank();

        // Ensure VP has time to accumulate
        vm.warp(block.timestamp + 10 days);

        _initialTreasuryBalance = underlying_.balanceOf(address(treasury_));
        _initialStakingBalance = underlying_.balanceOf(address(staking_));
    }

    // ========= Handler Actions =========

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

    // ========= Invariant Data =========

    function totalBoostExecuted() external view returns (uint256) {
        return _totalBoostExecuted;
    }

    function totalTreasuryRefills() external view returns (uint256) {
        return _totalTreasuryRefills;
    }

    function totalBoostExecutedWithAccrualFailure() external view returns (uint256) {
        return _totalBoostExecutedWithAccrualFailure;
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

    // ========= Internal Helpers =========

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
