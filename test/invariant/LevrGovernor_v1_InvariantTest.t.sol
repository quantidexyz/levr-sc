// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from 'forge-std/StdInvariant.sol';

import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {LevrGovernor_v1_Handler} from './handlers/LevrGovernor_v1_Handler.sol';

/// @title LevrGovernor_v1 invariants
/// @notice Ensures boost proposals conserve funds and respect liquidity constraints
contract LevrGovernor_v1_InvariantTest is StdInvariant, LevrFactoryDeployHelper {
    LevrFactory_v1 internal _factory;
    LevrGovernor_v1 internal _governor;
    LevrTreasury_v1 internal _treasury;
    LevrStaking_v1 internal _staking;
    ERC20_Mock internal _underlying;

    LevrGovernor_v1_Handler internal _handler;

    function setUp() public {
        _underlying = new ERC20_Mock('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(address(0xDEAD));
        (_factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        _factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = _factory.register(address(_underlying));

        _governor = LevrGovernor_v1(project.governor);
        _treasury = LevrTreasury_v1(payable(project.treasury));
        _staking = LevrStaking_v1(project.staking);

        // Seed treasury so boosts always have liquidity
        _underlying.mint(address(_treasury), 1_000_000 ether);

        _handler = new LevrGovernor_v1_Handler(
            _governor,
            _treasury,
            _staking,
            _underlying,
            _factory
        );

        targetContract(address(_handler));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Invariants

    function invariant_treasuryNeverDustsAllowance() public view {
        assertEq(
            _underlying.allowance(address(_treasury), address(_staking)),
            0,
            'Treasury must not leave allowance to staking'
        );
    }

    function invariant_boostTransfersConserveUnderlying() public view {
        uint256 treasuryBal = _underlying.balanceOf(address(_treasury));
        uint256 stakingBal = _underlying.balanceOf(address(_staking));

        uint256 expectedTreasury = _handler.initialTreasuryBalance() +
            _handler.totalTreasuryRefills() -
            _handler.totalBoostExecuted();
        uint256 expectedStaking = _handler.initialStakingBalance() + _handler.totalBoostExecuted();

        assertEq(treasuryBal, expectedTreasury, 'Treasury balance mismatch');
        assertEq(stakingBal, expectedStaking, 'Staking balance mismatch');
    }

    function invariant_failedAccrualRewardsRemainOutstanding() public view {
        uint256 outstanding = _staking.outstandingRewards(address(_underlying));
        assertGe(
            outstanding,
            _handler.pendingAccrualFromFailures(),
            'Outstanding rewards must cover failed accrual amounts'
        );
    }

    function invariant_executedBoostsBoundedByLiquidity() public view {
        uint256 liquidity = _handler.initialTreasuryBalance() + _handler.totalTreasuryRefills();
        assertLe(_handler.totalBoostExecuted(), liquidity, 'Executed boosts exceed liquidity');
    }

    function invariant_lastExecutionDidNotOverspendSnapshot() public view {
        uint256 latest = _handler.lastExecutedAmount();
        if (latest == 0) return;
        assertLe(
            latest,
            _handler.lastTreasuryBalanceBeforeExecute(),
            'Boost spent more than recorded treasury balance'
        );
    }
}
