// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from 'forge-std/StdInvariant.sol';

import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {LevrStaking_v1_Handler} from './handlers/LevrStaking_v1_Handler.sol';

/// @title LevrStaking_v1 invariants
/// @notice Ensures staking solvency, escrow accounting, and receipt supply parity
contract LevrStaking_v1_InvariantTest is StdInvariant, LevrFactoryDeployHelper {
    LevrFactory_v1 internal _factory;
    LevrStaking_v1 internal _staking;
    LevrStakedToken_v1 internal _stakedToken;
    ERC20_Mock internal _underlying;

    LevrStaking_v1_Handler internal _handler;

    function setUp() public {
        _underlying = new ERC20_Mock('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(address(this));
        (_factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        registerTokenWithMockClanker(address(_underlying));

        _factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = _factory.register(address(_underlying));

        _staking = LevrStaking_v1(project.staking);
        _stakedToken = LevrStakedToken_v1(project.stakedToken);

        _handler = new LevrStaking_v1_Handler(_staking, _stakedToken, _underlying);

        targetContract(address(_handler));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Invariants

    function invariant_totalStakedMatchesReceiptSupply() public view {
        assertEq(
            _staking.totalStaked(),
            _stakedToken.totalSupply(),
            'Receipt supply must mirror total staked'
        );
    }

    function invariant_escrowTracksTotalStaked() public view {
        address underlyingAddr = _staking.underlying();
        assertEq(
            _staking.escrowBalance(underlyingAddr),
            _staking.totalStaked(),
            'Escrow must equal total staked principal'
        );
    }

    function invariant_stakingSolvent() public view {
        uint256 contractBalance = _underlying.balanceOf(address(_staking));
        assertGe(
            contractBalance,
            _staking.totalStaked(),
            'Underlying balance must cover total staked'
        );
    }

    function invariant_ghostMatchesTotalStaked() public view {
        assertEq(
            _handler.ghostTotalStaked(),
            _staking.totalStaked(),
            'Handler accounting must stay synchronized'
        );
    }

    function invariant_stakedTokenBoundToStaking() public view {
        assertEq(_stakedToken.staking(), address(_staking), 'Receipt token staking mismatch');
        assertEq(_stakedToken.underlying(), _staking.underlying(), 'Underlying mismatch');
    }
}
