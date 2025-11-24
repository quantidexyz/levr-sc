// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStakedToken_v1} from '../../src/interfaces/ILevrStakedToken_v1.sol';

contract LevrStakedToken_v1_Test is Test {
    LevrStakedToken_v1 internal _stakedToken;
    address internal _staking = makeAddr('staking');
    address internal _underlying = makeAddr('underlying');
    address internal _alice = makeAddr('alice');
    address internal _bob = makeAddr('bob');

    function setUp() public {
        _stakedToken = new LevrStakedToken_v1(
            'Levr Staked Token',
            'sLEV',
            18,
            _underlying,
            _staking
        );
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Initialization

    /* Test: constructor */
    function test_Constructor_SetsImmutableState() public view {
        assertEq(_stakedToken.underlying(), _underlying);
        assertEq(_stakedToken.staking(), _staking);
    }

    function test_Constructor_RevertIf_UnderlyingZero() public {
        vm.expectRevert(ILevrStakedToken_v1.ZeroAddress.selector);
        new LevrStakedToken_v1('Levr', 'sLEV', 18, address(0), _staking);
    }

    function test_Constructor_RevertIf_StakingZero() public {
        vm.expectRevert(ILevrStakedToken_v1.ZeroAddress.selector);
        new LevrStakedToken_v1('Levr', 'sLEV', 18, _underlying, address(0));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test External Functions

    // ========================================================================
    // External - View Functions

    /* Test: decimals */
    function test_Decimals_ReturnsConfiguredValue() public view {
        assertEq(_stakedToken.decimals(), 18);
    }

    // ========================================================================
    // External - Mutating Functions

    /* Test: mint */
    function test_Mint_RevertIf_CallerNotStaking() public {
        vm.expectRevert(ILevrStakedToken_v1.OnlyStaking.selector);
        _stakedToken.mint(_alice, 1 ether);
    }

    function test_Mint_Success_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ILevrStakedToken_v1.Mint(_alice, 100 ether);

        vm.prank(_staking);
        _stakedToken.mint(_alice, 100 ether);

        assertEq(_stakedToken.balanceOf(_alice), 100 ether);
        assertEq(_stakedToken.totalSupply(), 100 ether);
    }

    /* Test: burn */
    function test_Burn_RevertIf_CallerNotStaking() public {
        vm.prank(_staking);
        _stakedToken.mint(_alice, 50 ether);

        vm.expectRevert(ILevrStakedToken_v1.OnlyStaking.selector);
        _stakedToken.burn(_alice, 10 ether);
    }

    function test_Burn_Success_UpdatesSupply() public {
        vm.prank(_staking);
        _stakedToken.mint(_alice, 80 ether);

        vm.expectEmit(true, false, false, true);
        emit ILevrStakedToken_v1.Burn(_alice, 20 ether);

        vm.prank(_staking);
        _stakedToken.burn(_alice, 20 ether);

        assertEq(_stakedToken.balanceOf(_alice), 60 ether);
        assertEq(_stakedToken.totalSupply(), 60 ether);
    }

    /* Test: transfer (non-transferable) */

    function test_Approve_AllowsAllowanceUpdates() public {
        vm.prank(_alice);
        _stakedToken.approve(_bob, 100 ether);
        assertEq(_stakedToken.allowance(_alice, _bob), 100 ether);

        vm.prank(_alice);
        _stakedToken.approve(_bob, 50 ether);
        assertEq(_stakedToken.allowance(_alice, _bob), 50 ether);
    }
    function test_Transfer_RevertIf_Attempted() public {
        vm.prank(_staking);
        _stakedToken.mint(_alice, 10 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrStakedToken_v1.CannotModifyUnderlying.selector);
        _stakedToken.transfer(_bob, 1 ether);
    }

    function test_TransferFrom_RevertEvenWithAllowance() public {
        vm.prank(_staking);
        _stakedToken.mint(_alice, 20 ether);

        vm.prank(_alice);
        _stakedToken.approve(_bob, 5 ether);

        vm.prank(_bob);
        vm.expectRevert(ILevrStakedToken_v1.CannotModifyUnderlying.selector);
        _stakedToken.transferFrom(_alice, _bob, 1 ether);

        assertEq(_stakedToken.allowance(_alice, _bob), 5 ether, 'Allowance unchanged');
    }

    function test_SelfTransfer_Revert() public {
        vm.prank(_staking);
        _stakedToken.mint(_alice, 5 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrStakedToken_v1.CannotModifyUnderlying.selector);
        _stakedToken.transfer(_alice, 1 ether);
    }
}
