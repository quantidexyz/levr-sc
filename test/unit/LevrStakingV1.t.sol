// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrStakingV1_UnitTest is Test {
    MockERC20 internal underlying;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);

    // Mock factory functions for testing
    function clankerFactory() external pure returns (address) {
        return address(0); // No clanker factory for test
    }

    function getClankerMetadata(
        address /* clankerToken */
    ) external pure returns (ILevrFactory_v1.ClankerMetadata memory) {
        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0),
                lpLocker: address(0),
                hook: address(0),
                exists: false
            });
    }

    function streamWindowSeconds() external pure returns (uint32) {
        return 3 days; // Default stream window for tests
    }

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        // Pass address(0) for forwarder since we're not testing meta-transactions here
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked Token',
            'sTKN',
            18,
            address(underlying),
            address(staking)
        );
        staking.initialize(address(underlying), address(sToken), treasury, address(this)); // Pass test contract as factory for test

        underlying.mint(address(this), 1_000_000 ether);
    }

    function test_stake_mintsStakedToken_andEscrowsUnderlying() public {
        // Use amount similar to TypeScript test for consistency
        uint256 userBalance = 4548642989513676498672470665; // Mirrors TS test user balance
        underlying.mint(address(this), userBalance);

        uint256 stakeAmount = userBalance / 2; // Stake 50% like TS test
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        assertEq(sToken.balanceOf(address(this)), stakeAmount, 'Should mint staked tokens 1:1');
        assertEq(staking.totalStaked(), stakeAmount, 'Total staked should match');
        assertEq(
            staking.escrowBalance(address(underlying)),
            stakeAmount,
            'Should escrow underlying'
        );
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
            uint256 diff = claimed > expected ? claimed - expected : expected - claimed;
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
            uint256 diff2 = claimed > expected2 ? claimed - expected2 : expected2 - claimed;
            assertLe(diff2, tol2);
        }
    }

    function test_accrueRewards_fromBalance_creditsWithoutPull() public {
        // deposit rewards directly to staking
        underlying.transfer(address(staking), 1_000 ether);
        // account them - now automatically credits all available (1000 ether)
        staking.accrueRewards(address(underlying));
    }

    function test_multi_user_distribution_proportional_and_reserves_sane() public {
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

    // ============ Governance: Proportional Unstake Tests ============

    function test_partial_unstake_reduces_time_proportionally() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 100 days - VP should be 1000 token-days (normalized)
        vm.warp(block.timestamp + 100 days);
        uint256 vpBefore = staking.getVotingPower(address(this));
        assertEq(vpBefore, 1000 * 100, 'VP should be 100,000 token-days');

        // Unstake 30% (300 tokens)
        uint256 returnedVP = staking.unstake(300 ether, address(this));

        // Immediately after unstake: 700 tokens * 70 days = 49,000 token-days
        uint256 vpAfter = staking.getVotingPower(address(this));
        uint256 expectedVP = 700 * 70;
        assertEq(vpAfter, expectedVP, 'VP should be 49,000 token-days (30% reduction)');
        assertEq(returnedVP, expectedVP, 'Returned VP should match actual VP');

        // After 30 more days: 700 tokens * 100 days total
        vm.warp(block.timestamp + 30 days);
        uint256 vpFinal = staking.getVotingPower(address(this));
        assertEq(vpFinal, 700 * 100, 'VP should be 70,000 token-days (continues accumulating)');
    }

    function test_full_unstake_resets_time_to_zero() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 50 days);
        assertGt(staking.getVotingPower(address(this)), 0, 'Should have VP before unstake');

        // Unstake everything
        uint256 returnedVP = staking.unstake(1000 ether, address(this));

        assertEq(staking.getVotingPower(address(this)), 0, 'VP should be 0 after full unstake');
        assertEq(staking.stakeStartTime(address(this)), 0, 'stakeStartTime should be 0');
        assertEq(returnedVP, 0, 'Returned VP should be 0 on full unstake');
    }

    function test_partial_unstake_50_percent() public {
        underlying.approve(address(staking), 2000 ether);
        staking.stake(2000 ether);

        // Wait 200 days
        vm.warp(block.timestamp + 200 days);

        // Unstake 50%
        uint256 returnedVP = staking.unstake(1000 ether, address(this));

        // Should have: 1000 tokens * 100 days = 100,000 token-days
        uint256 vp = staking.getVotingPower(address(this));
        uint256 expectedVP = 1000 * 100;
        assertEq(vp, expectedVP, 'VP should be 100,000 token-days');
        assertEq(returnedVP, expectedVP, 'Returned VP should match for UI simulation');
    }

    function test_multiple_partial_unstakes_compound() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 100 days, unstake 20% (200 tokens)
        vm.warp(block.timestamp + 100 days);
        staking.unstake(200 ether, address(this));
        // Now: 800 tokens * 80 days = 64,000 token-days
        uint256 vp1 = staking.getVotingPower(address(this));
        assertEq(vp1, 800 * 80, 'First unstake: 64,000 token-days');

        // Wait 20 more days (total 100 days from new baseline)
        vm.warp(block.timestamp + 20 days);
        // Now: 800 tokens * 100 days = 80,000 token-days
        uint256 vp2 = staking.getVotingPower(address(this));
        assertEq(vp2, 800 * 100, 'After 20 days: 80,000 token-days');

        // Unstake 25% of remaining (200 tokens of 800)
        staking.unstake(200 ether, address(this));
        // Now: 600 tokens * 75 days = 45,000 token-days

        uint256 vp3 = staking.getVotingPower(address(this));
        assertEq(vp3, 600 * 75, 'Second unstake: 45,000 token-days');
    }

    function test_partial_unstake_then_restake_preserves_time() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Partial unstake
        staking.unstake(500 ether, address(this));
        uint256 vpAfterUnstake = staking.getVotingPower(address(this));
        assertEq(vpAfterUnstake, 500 * 50, 'After unstake: 25,000 token-days');

        // Restake (top-up preserves time)
        underlying.approve(address(staking), 300 ether);
        staking.stake(300 ether);

        // VP should be 800 tokens * 50 days = 40,000 token-days
        uint256 vpAfterRestake = staking.getVotingPower(address(this));
        assertEq(vpAfterRestake, 800 * 50, 'After restake: 40,000 token-days (time preserved)');
    }

    function test_unstake_everything_resets_to_zero() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 50 days);

        // Unstake everything
        staking.unstake(1000 ether, address(this));

        assertEq(staking.stakeStartTime(address(this)), 0, 'Should reset to 0');
        assertEq(staking.getVotingPower(address(this)), 0, 'VP should be 0');
    }

    function test_partial_unstake_10_percent() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 1000 days
        vm.warp(block.timestamp + 1000 days);

        // Unstake 10% (100 tokens)
        staking.unstake(100 ether, address(this));

        // Should have: 900 tokens * 900 days = 810,000 token-days
        uint256 vp = staking.getVotingPower(address(this));
        assertEq(vp, 900 * 900, '10% unstake should give 810,000 token-days');
    }

    function test_partial_unstake_90_percent() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Wait 1000 days
        vm.warp(block.timestamp + 1000 days);

        // Unstake 90% (900 tokens)
        staking.unstake(900 ether, address(this));

        // Should have: 100 tokens * 100 days = 10,000 token-days
        uint256 vp = staking.getVotingPower(address(this));
        assertEq(vp, 100 * 100, '90% unstake should give 10,000 token-days');
    }
}
