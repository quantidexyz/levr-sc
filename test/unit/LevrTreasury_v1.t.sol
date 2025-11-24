// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrTreasury_v1} from '../../src/interfaces/ILevrTreasury_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrTreasury_v1_Test is Test, LevrFactoryDeployHelper {
    LevrTreasury_v1 internal _treasury;
    ERC20_Mock internal _token;
    LevrFactory_v1 internal _factory;
    LevrForwarder_v1 internal _forwarder;
    LevrDeployer_v1 internal _deployer;
    LevrStaking_v1 internal _staking;

    address internal _governor;
    address internal _protocolTreasury = address(0xDEAD);
    address internal _user = address(0xAAAA);

    function setUp() public {
        _token = new ERC20_Mock('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(_protocolTreasury);
        (_factory, _forwarder, _deployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        _factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = _factory.register(address(_token));
        _governor = project.governor;
        _treasury = LevrTreasury_v1(payable(project.treasury));
        _staking = LevrStaking_v1(project.staking);

        _token.mint(address(_treasury), 10_000 ether);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Initialization

    // Included in setup implicitly via factory registration

    ///////////////////////////////////////////////////////////////////////////
    // Test External Functions

    // ========================================================================
    // External - Transfer

    /* Test: transfer */

    function test_Transfer_RevertIf_Unauthorized() public {
        vm.prank(_user);
        vm.expectRevert(ILevrTreasury_v1.OnlyGovernor.selector);
        _treasury.transfer(address(_token), _user, 100 ether);
    }

    function test_Transfer_RevertIf_TokenZero() public {
        vm.prank(_governor);
        vm.expectRevert(ILevrTreasury_v1.ZeroAddress.selector);
        _treasury.transfer(address(0), _user, 100 ether);
    }

    function test_Transfer_RevertIf_RecipientZero() public {
        vm.prank(_governor);
        vm.expectRevert(); // Reverts in ERC20
        _treasury.transfer(address(_token), address(0), 100 ether);
    }

    function test_Transfer_RevertIf_InsufficientBalance() public {
        uint256 balance = _token.balanceOf(address(_treasury));

        vm.prank(_governor);
        vm.expectRevert(); // ERC20 insufficient balance
        _treasury.transfer(address(_token), _user, balance + 1);
    }

    function test_Transfer_Success() public {
        uint256 amount = 100 ether;
        uint256 balBefore = _token.balanceOf(_user);

        vm.prank(_governor);
        _treasury.transfer(address(_token), _user, amount);

        uint256 balAfter = _token.balanceOf(_user);
        assertEq(balAfter - balBefore, amount);
    }

    function test_Transfer_ToStaking_MovesFunds() public {
        uint256 amount = 2_000 ether;

        vm.prank(_governor);
        _treasury.transfer(address(_token), address(_staking), amount);

        assertEq(_token.balanceOf(address(_staking)), amount);
    }

    // ============ Edge Cases ============

    function test_Transfer_MaxAmount() public {
        uint256 balance = _token.balanceOf(address(_treasury));

        vm.prank(_governor);
        _treasury.transfer(address(_token), _user, balance);

        assertEq(_token.balanceOf(_user), balance);
        assertEq(_token.balanceOf(address(_treasury)), 0);
    }

    function test_Transfer_MultipleRecipients() public {
        address u1 = address(0x1);
        address u2 = address(0x2);

        vm.startPrank(_governor);
        _treasury.transfer(address(_token), u1, 100 ether);
        _treasury.transfer(address(_token), u2, 200 ether);
        vm.stopPrank();

        assertEq(_token.balanceOf(u1), 100 ether);
        assertEq(_token.balanceOf(u2), 200 ether);
    }
}
