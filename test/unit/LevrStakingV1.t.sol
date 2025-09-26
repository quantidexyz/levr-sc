// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {LevrStaking_v1} from "../../src/LevrStaking_v1.sol";
import {LevrStakedToken_v1} from "../../src/LevrStakedToken_v1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LevrStakingV1_UnitTest is Test {
    MockERC20 internal underlying;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);

    function setUp() public {
        underlying = new MockERC20("Token", "TKN");
        staking = new LevrStaking_v1();
        sToken = new LevrStakedToken_v1(
            "Staked Token",
            "sTKN",
            18,
            address(underlying),
            address(staking)
        );
        staking.initialize(address(underlying), address(sToken), treasury);

        underlying.mint(address(this), 1_000_000 ether);
    }

    function test_stake_mintsStakedToken_andEscrowsUnderlying() public {
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(1_000 ether);
        assertEq(sToken.balanceOf(address(this)), 1_000 ether);
        assertEq(staking.totalStaked(), 1_000 ether);
        assertEq(staking.escrowBalance(address(underlying)), 1_000 ether);
    }

    function test_unstake_burns_andReturnsUnderlying() public {
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(1_000 ether);

        staking.unstake(400 ether, address(this));
        assertEq(sToken.balanceOf(address(this)), 600 ether);
        assertEq(staking.totalStaked(), 600 ether);
    }

    function test_accrueFromTreasury_pull_flow_creditsRewards_andStreamResets()
        public
    {
        // fund treasury with reward token
        underlying.mint(treasury, 10_000 ether);
        vm.prank(treasury);
        underlying.approve(address(staking), 10_000 ether);

        // stake to create shares
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(1_000 ether);

        // pull from treasury and credit
        vm.prank(treasury);
        staking.accrueFromTreasury(address(underlying), 2_000 ether, true);

        // claim rewards
        address[] memory toks = new address[](1);
        toks[0] = address(underlying);
        uint256 beforeBal = underlying.balanceOf(address(this));
        staking.claimRewards(toks, address(this));
        uint256 afterBal = underlying.balanceOf(address(this));
        assertGt(afterBal, beforeBal, "no rewards claimed");
    }

    function test_accrueRewards_fromBalance_creditsWithoutPull() public {
        // deposit rewards directly to staking
        underlying.transfer(address(staking), 1_000 ether);
        // account them
        staking.accrueRewards(address(underlying), 1_000 ether);
    }
}
