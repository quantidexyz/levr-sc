// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStakedToken_v1} from '../../src/interfaces/ILevrStakedToken_v1.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrStakedTokenV1_Test is Test, LevrFactoryDeployHelper {
    LevrStakedToken_v1 internal sToken;
    address internal staking = address(0xBEEF);
    address internal underlying = address(0xCAFE);

    function setUp() public {
        sToken = createStakedToken('Levr Staked Token', 'sTKN', 18, underlying, staking);
    }

    function test_decimals_matches_init() public view {
        assertEq(sToken.decimals(), 18);
    }

    function test_onlyStakingCanMintBurn() public {
        address user = address(0xA11CE);
        vm.prank(staking);
        sToken.mint(user, 100);
        assertEq(sToken.balanceOf(user), 100);

        vm.prank(user);
        vm.expectRevert(ILevrStakedToken_v1.OnlyStaking.selector);
        sToken.mint(user, 1);

        vm.prank(staking);
        sToken.burn(user, 40);
        assertEq(sToken.balanceOf(user), 60);

        vm.prank(user);
        vm.expectRevert(ILevrStakedToken_v1.OnlyStaking.selector);
        sToken.burn(user, 1);
    }
}
