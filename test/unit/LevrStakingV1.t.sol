// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {LevrStaking_v1} from "../../src/LevrStaking_v1.sol";
import {LevrStakedToken_v1} from "../../src/LevrStakedToken_v1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC1363} from "../mocks/MockERC1363.sol";

contract LevrStakingV1_UnitTest is Test {
    MockERC20 internal underlying;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);

    function setUp() public {
        underlying = new MockERC20("Token", "TKN");
        // Pass address(0) for forwarder since we're not testing meta-transactions here
        staking = new LevrStaking_v1(address(0));
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

    function test_accrueFromTreasury_pull_flow_streamsOverWindow() public {
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

        // claim rewards after 1 day in a 3 day window
        address[] memory toks = new address[](1);
        toks[0] = address(underlying);
        uint256 beforeBal = underlying.balanceOf(address(this));
        vm.warp(block.timestamp + 1 days);
        staking.claimRewards(toks, address(this));
        uint256 afterBal = underlying.balanceOf(address(this));
        uint256 claimed = afterBal - beforeBal;
        {
            uint256 expected = (2_000 ether) / uint256(3);
            uint256 tol = (expected * 5e15) / 1e18; // 0.5%
            uint256 diff = claimed > expected
                ? claimed - expected
                : expected - claimed;
            assertLe(diff, tol);
        }
        // move to end of window and claim remainder
        beforeBal = underlying.balanceOf(address(this));
        vm.warp(block.timestamp + 3 days);
        staking.claimRewards(toks, address(this));
        afterBal = underlying.balanceOf(address(this));
        claimed = afterBal - beforeBal;
        {
            uint256 expected2 = (2_000 ether * 2) / uint256(3);
            uint256 tol2 = (expected2 * 5e15) / 1e18;
            uint256 diff2 = claimed > expected2
                ? claimed - expected2
                : expected2 - claimed;
            assertLe(diff2, tol2);
        }
    }

    function test_accrueRewards_fromBalance_creditsWithoutPull() public {
        // deposit rewards directly to staking
        underlying.transfer(address(staking), 1_000 ether);
        // account them
        staking.accrueRewards(address(underlying), 1_000 ether);
    }

    function test_multi_user_distribution_proportional_and_reserves_sane()
        public
    {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        underlying.mint(alice, 10_000 ether);
        underlying.mint(bob, 10_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(2_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(6_000 ether);
        vm.stopPrank();

        // fund treasury and pull 8000 tokens -> stream rewards
        underlying.mint(treasury, 8_000 ether);
        vm.prank(treasury);
        underlying.approve(address(staking), type(uint256).max);
        vm.prank(treasury);
        staking.accrueFromTreasury(address(underlying), 8_000 ether, true);

        // expected shares: alice 25%, bob 75% of credited rewards
        address[] memory toks = new address[](1);
        toks[0] = address(underlying);

        // advance half window, ~4000 vested so far
        vm.warp(block.timestamp + 36 hours);
        vm.startPrank(alice);
        uint256 aBefore = underlying.balanceOf(alice);
        staking.claimRewards(toks, alice);
        uint256 aAfter = underlying.balanceOf(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bBefore = underlying.balanceOf(bob);
        staking.claimRewards(toks, bob);
        uint256 bAfter = underlying.balanceOf(bob);
        vm.stopPrank();

        uint256 aClaim = aAfter - aBefore;
        uint256 bClaim = bAfter - bBefore;
        // 4,000 vested so far -> alice 25% (1,000), bob 75% (3,000)
        {
            uint256 expA = 1_000 ether;
            uint256 tolA = (expA * 5e15) / 1e18;
            uint256 diffA = aClaim > expA ? aClaim - expA : expA - aClaim;
            assertLe(diffA, tolA);
            uint256 expB = 3_000 ether;
            uint256 tolB = (expB * 5e15) / 1e18;
            uint256 diffB = bClaim > expB ? bClaim - expB : expB - bClaim;
            assertLe(diffB, tolB);
        }
    }

    function test_erc1363_auto_accrual_on_transfer_received() public {
        // Switch reward token to ERC-1363 mock for this test
        MockERC1363 r = new MockERC1363("R1363", "R1363");
        // Staking auto-registers tokens on first credit, so transferAndCall will trigger credit

        // stake some underlying to create shares
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1_000 ether);

        r.mint(address(this), 5_000 ether);
        r.transferAndCall(address(staking), 5_000 ether, bytes(""));

        address[] memory toks = new address[](1);
        toks[0] = address(r);
        // streaming: advance time then claim ~ 1/3 of 5,000
        uint256 beforeBal = r.balanceOf(address(this));
        vm.warp(block.timestamp + 1 days);
        staking.claimRewards(toks, address(this));
        uint256 afterBal = r.balanceOf(address(this));
        uint256 claimed = afterBal - beforeBal;
        {
            uint256 expected = (5_000 ether) / uint256(3);
            uint256 tol = (expected * 5e15) / 1e18;
            uint256 diff = claimed > expected
                ? claimed - expected
                : expected - claimed;
            assertLe(diff, tol);
        }
    }
}
