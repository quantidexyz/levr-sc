// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @title EXTERNAL_AUDIT_0 HIGH-1: Voting Power Precision Loss Tests
/// @notice Tests for [HIGH-1] Voting Power Precision Loss on Large Unstakes
/// @dev Issue: Integer division rounding can cause complete loss of voting power
contract EXTERNAL_AUDIT_0_LevrStakingVotingPowerPrecisionTest is Test {
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    LevrFactory_v1 factory;
    LevrForwarder_v1 forwarder;
    MockERC20 underlying;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address tokenAdmin = address(0x3333);

    function setUp() public {
        // Create factory config
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            maxRewardTokens: 50
        });

        // Deploy forwarder
        forwarder = new LevrForwarder_v1('Levr Forwarder');

        // Deploy factory with correct constructor
        factory = new LevrFactory_v1(
            config,
            address(this),
            address(forwarder),
            address(0),
            address(0)
        );

        // Deploy underlying token
        underlying = new MockERC20('Underlying', 'UND');

        // Create staking and staked token directly
        staking = new LevrStaking_v1(address(forwarder));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(factory),
            address(factory)
        );

        // Mint underlying tokens
        underlying.mint(alice, 1000000 ether);
        underlying.mint(bob, 1000000 ether);
    }

    /// @notice Test basic voting power calculation
    function test_stakingVotingPower_basicCalculation() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);

        uint256 vp = staking.getVotingPower(alice);

        // VP = (1000 * 86400) / (1e18 * 86400) = 1000
        assertEq(vp, 1000, 'VP should be 1000 for 1000 tokens staked 1 day');
    }

    /// @notice Test 50% unstake preserves proportional voting power (should work fine)
    function test_stakingVotingPower_50percentUnstake_precisionPreserved() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Unstake 50%
        staking.unstake(500 ether, alice);

        uint256 vp = staking.getVotingPower(alice);

        // Remaining: 500 tokens × 50 days = 25,000 token-days
        assertEq(vp, 25_000, 'Should preserve exactly 50% of time');
    }

    /// @notice Test 25% unstake preserves proportional voting power
    function test_stakingVotingPower_25percentUnstake_precisionExact() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Unstake 25%
        staking.unstake(250 ether, alice);

        uint256 vp = staking.getVotingPower(alice);

        // Remaining: 750 tokens × 75 days = 56,250 token-days
        assertEq(vp, 56_250, 'Should preserve exact proportional VP');
    }

    /// @notice Test extreme precision loss scenario: 99.9% unstake
    /// @dev This is the critical case from the audit
    function test_stakingVotingPower_99_9percentUnstake_precisionLoss() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 365 days);

        // Unstake 99.9%
        staking.unstake(999 ether, alice);

        uint256 vp = staking.getVotingPower(alice);

        // Expected: 1 token × 365 days = 365 token-days
        // Without fix: rounding to 0
        // With fix: should be > 0

        console.log('VP after 99.9% unstake:', vp);

        // After fix should have SOME voting power (not zero)
        assertGt(vp, 0, 'Voting power should not be completely lost on 99.9% unstake');

        // Should be approximately 365 (within reasonable rounding error)
        // Allow 10% error due to precision
        assertApproxEqRel(vp, 365, 0.1e18, 'VP should be approximately proportional');
    }

    /// @notice Test extreme case: leaving only 1 wei
    function test_stakingVotingPower_1weiRemaining_precisionBoundary() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Leave only 1 wei
        staking.unstake(1000 ether - 1, alice);

        uint256 vp = staking.getVotingPower(alice);

        console.log('VP for 1 wei remaining after 100 days:', vp);

        // Document the behavior - should be > 0 after fix
        // newTime = (100 days * 1 wei) / 1000 ether = rounding issue
        // With minimum time floor, should get at least 1 second
    }

    /// @notice Test multiple partial unstakes to see precision degradation
    function test_stakingVotingPower_multiplePartialUnstakes() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Multiple small unstakes (10 of them)
        for (uint i = 0; i < 10; i++) {
            staking.unstake(90 ether, alice);
            vm.warp(block.timestamp + 1 days);
        }

        uint256 vp = staking.getVotingPower(alice);

        console.log('VP after 10 sequential unstakes:', vp);

        // Remaining: 100 tokens with accumulated time
        assertGt(vp, 0, 'Multiple unstakes should preserve some VP');
    }

    /// @notice Test that normal unstakes (< 99%) don't have precision issues
    function test_stakingVotingPower_normalUnstakes_noPrecisionLoss() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(10000 ether);

        vm.warp(block.timestamp + 100 days);

        uint256 vpBefore = staking.getVotingPower(alice);

        // Unstake 30%
        staking.unstake(3000 ether, alice);

        uint256 vpAfter = staking.getVotingPower(alice);

        // Should have approximately 70% of the previous VP
        uint256 expectedVp = (vpBefore * 70) / 100;
        assertApproxEqRel(
            vpAfter,
            expectedVp,
            0.01e18,
            'Normal unstakes should preserve VP exactly'
        );
    }

    /// @notice Test voting power after various time periods
    function test_stakingVotingPower_acrossDifferentTimePeriods() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Test at 1 day
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.getVotingPower(alice), 1000);

        // Test at 10 days
        vm.warp(block.timestamp + 9 days);
        assertEq(staking.getVotingPower(alice), 10_000);

        // Test at 100 days
        vm.warp(block.timestamp + 90 days);
        assertEq(staking.getVotingPower(alice), 100_000);

        // Test at 365 days
        vm.warp(block.timestamp + 265 days);
        assertEq(staking.getVotingPower(alice), 365_000);
    }

    /// @notice Test voting power reset on full unstake
    function test_stakingVotingPower_fullUnstakeResetsVP() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        assertGt(staking.getVotingPower(alice), 0);

        // Full unstake
        staking.unstake(1000 ether, alice);

        assertEq(staking.getVotingPower(alice), 0, 'VP should be zero after full unstake');
    }

    /// @notice Test re-staking after unstaking
    function test_stakingVotingPower_restakeAfterUnstake() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 2000 ether);

        // First stake
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 100 days);

        uint256 vpBefore = staking.getVotingPower(alice);
        assertGt(vpBefore, 0);

        // Unstake all
        staking.unstake(1000 ether, alice);
        assertEq(staking.getVotingPower(alice), 0);

        // Re-stake (should start from 0)
        staking.stake(1000 ether);
        assertEq(staking.getVotingPower(alice), 0, 'Fresh stake should have 0 VP');

        // Fast forward again
        vm.warp(block.timestamp + 50 days);
        assertEq(staking.getVotingPower(alice), 50_000, 'Should accumulate from fresh start');
    }

    /// @notice Test precision edge case with very small amounts
    function test_stakingVotingPower_verySmallAmounts() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 wei);
        staking.stake(1000 wei);

        vm.warp(block.timestamp + 1 days);

        uint256 vp = staking.getVotingPower(alice);

        // 1000 wei for 1 day
        // VP = (1000 * 86400) / (1e18 * 86400)
        // This will round down to 0 due to the 1e18 normalization
        console.log('VP for 1000 wei staked for 1 day:', vp);
    }

    /// @notice Test precision with maximum amounts
    function test_stakingVotingPower_maximumAmounts() public {
        vm.startPrank(alice);

        // Stake a very large amount
        uint256 largeAmount = 1000000 ether; // 1 million tokens
        underlying.mint(alice, largeAmount);
        underlying.approve(address(staking), largeAmount);
        staking.stake(largeAmount);

        vm.warp(block.timestamp + 1 days);

        uint256 vp = staking.getVotingPower(alice);

        // VP = (1000000 * 86400) / (1e18 * 86400) = 1000000
        assertEq(vp, 1_000_000, 'Large amounts should scale proportionally');
    }

    /// @notice Test voting power consistency across multiple users
    function test_stakingVotingPower_multipleUsersConsistency() public {
        // Both Alice and Bob stake same amount
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        uint256 vpAlice = staking.getVotingPower(alice);
        uint256 vpBob = staking.getVotingPower(bob);

        assertEq(vpAlice, vpBob, 'Same stake amounts should have same VP');

        // Both unstake same percentage
        vm.startPrank(alice);
        staking.unstake(500 ether, alice);

        vm.startPrank(bob);
        staking.unstake(500 ether, bob);

        vpAlice = staking.getVotingPower(alice);
        vpBob = staking.getVotingPower(bob);

        assertEq(vpAlice, vpBob, 'Same unstake percentages should have same VP');
    }

    /// @notice Test the mathematical formula for precision loss
    /// @dev Documents the exact calculation from the audit
    function test_stakingVotingPower_mathematicalAnalysis() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Before unstaking
        // timeAccumulated = 100 days = 8,640,000 seconds
        // _staked[alice] = 1000e18

        // After unstaking 999e18
        // remainingBalance = 1e18
        // originalBalance = 1000e18

        // newTimeAccumulated = (8,640,000 * 1e18) / 1000e18
        //                    = 8,640,000 / 1000
        //                    = 8,640

        // The issue: (timeAccumulated * remainingBalance) / originalBalance
        // becomes: (big_number * small_number) / big_number
        // which can round to 0 if remainingBalance is in wei

        staking.unstake(999 ether, alice);

        uint256 vp = staking.getVotingPower(alice);
        console.log('VP for 1e18 tokens after 100 days unstake:', vp);
    }
}
