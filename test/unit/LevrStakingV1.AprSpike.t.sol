// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract LevrStakingV1AprSpikeTest is Test {
    // ---
    // CONSTANTS

    uint256 constant INITIAL_STAKE = 10_000_000 * 1e18; // 10M tokens
    uint256 constant WETH_REWARD_BALANCE = 1 * 1e18; // 1 WETH already in pool
    uint256 constant OUTSTANDING_TOKEN_REWARDS = 1000 * 1e18; // 1000 tokens
    uint256 constant OUTSTANDING_WETH_REWARDS = 0.01 * 1e18; // 0.01 WETH

    // ---
    // VARIABLES

    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;

    address alice = address(0xA11CE);
    address treasury = address(0x1234);

    function setUp() public {
        // Deploy factory with 3-day stream window
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
            maxProposalAmountBps: 500
        });

        factory = new LevrFactory_v1(
            config,
            address(this),
            address(0),
            address(0), // clankerFactory
            address(0) // levrDeployer
        );

        // Deploy tokens
        underlying = new MockERC20('Underlying Token', 'UND');
        weth = new MockERC20('Wrapped ETH', 'WETH');

        // Deploy staking and staked token
        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking only (stakedToken is immutable)
        // Must call from factory address
        vm.prank(address(factory));
        staking.initialize(address(underlying), address(stakedToken), treasury, address(factory));

        // Setup alice with initial stake
        underlying.mint(alice, INITIAL_STAKE);
        vm.startPrank(alice);
        underlying.approve(address(staking), INITIAL_STAKE);
        staking.stake(INITIAL_STAKE);
        vm.stopPrank();

        // Add WETH as reward token with some existing balance
        weth.mint(address(staking), WETH_REWARD_BALANCE);
    }

    function test_apr_spike_reproduction() public {
        console2.log('=== INITIAL STATE ===');
        console2.log('Total Staked:', staking.totalStaked() / 1e18, 'tokens');
        console2.log(
            'Underlying Balance:',
            underlying.balanceOf(address(staking)) / 1e18,
            'tokens'
        );
        console2.log('WETH Balance:', weth.balanceOf(address(staking)) / 1e18, 'WETH');

        // Simulate some initial rewards being accrued to establish baseline APR
        // Let's accrue 600K tokens to get ~2-3% APR baseline
        uint256 initialRewards = 600_000 * 1e18;
        underlying.mint(address(staking), initialRewards);
        staking.accrueRewards(address(underlying));

        console2.log('\n=== AFTER INITIAL REWARD ACCRUAL ===');
        uint256 aprBefore = staking.aprBps();
        console2.log('APR (underlying) in bps:', aprBefore);
        console2.log('APR as percentage:', aprBefore / 100);

        // Fast forward 1 day to let some rewards stream
        vm.warp(block.timestamp + 1 days);

        // Check APR after 1 day
        console2.log('\n=== AFTER 1 DAY ===');
        aprBefore = staking.aprBps();
        console2.log('APR (underlying) in bps:', aprBefore);
        console2.log('APR as percentage:', aprBefore / 100);

        // Now simulate outstanding rewards and accrue them
        console2.log('\n=== OUTSTANDING REWARDS ===');
        (uint256 availableUnderlying, ) = staking.outstandingRewards(address(underlying));
        (uint256 availableWeth, ) = staking.outstandingRewards(address(weth));
        console2.log('Available Underlying:', availableUnderlying / 1e18, 'tokens');
        console2.log('Available WETH:', availableWeth / 1e18, 'WETH');

        // Add the outstanding rewards
        underlying.mint(address(staking), OUTSTANDING_TOKEN_REWARDS);
        weth.mint(address(staking), OUTSTANDING_WETH_REWARDS);

        console2.log('\n=== BEFORE ACCRUE ===');
        (availableUnderlying, ) = staking.outstandingRewards(address(underlying));
        (availableWeth, ) = staking.outstandingRewards(address(weth));
        console2.log('Available Underlying:', availableUnderlying / 1e18, 'tokens');
        console2.log('Available WETH:', availableWeth / 1e18, 'WETH');

        // Accrue both tokens
        staking.accrueRewards(address(underlying));
        staking.accrueRewards(address(weth));

        console2.log('\n=== AFTER ACCRUE ===');
        uint256 aprAfter = staking.aprBps();
        console2.log('APR (underlying) in bps:', aprAfter);
        console2.log('APR as percentage:', aprAfter / 100);

        // Calculate WETH APR manually since aprBps() only returns underlying
        uint256 wethRate = staking.rewardRatePerSecond(address(weth));
        console2.log('WETH rate per second:', wethRate);
        uint256 wethAnnual = wethRate * 365 days;
        console2.log('WETH annual (in wei):', wethAnnual);

        // Show the jump
        console2.log('\n=== APR CHANGE ===');
        console2.log('Before (bps):', aprBefore);
        console2.log('After (bps):', aprAfter);
        if (aprAfter > aprBefore) {
            console2.log('Jump in bps:', aprAfter - aprBefore);
            console2.log('Jump in percent:', (aprAfter - aprBefore) / 100);
            console2.log('Multiplier (x100):', (aprAfter * 100) / aprBefore);
        }

        // Verify rewards will be fully emitted
        console2.log('\n=== REWARD EMISSION VERIFICATION ===');
        uint64 streamEnd = staking.streamEnd();
        console2.log('Stream ends at:', streamEnd);
        console2.log('Current time:', block.timestamp);
        console2.log('Time until stream end:', streamEnd - block.timestamp, 'seconds');

        // Fast forward to end of stream
        vm.warp(streamEnd + 1);

        // Try to claim all rewards
        address[] memory tokens = new address[](2);
        tokens[0] = address(underlying);
        tokens[1] = address(weth);

        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 aliceUnderlyingAfter = underlying.balanceOf(alice);
        uint256 aliceWethAfter = weth.balanceOf(alice);

        console2.log('\n=== REWARDS CLAIMED ===');
        console2.log(
            'Underlying claimed (tokens):',
            (aliceUnderlyingAfter - aliceUnderlyingBefore) / 1e18
        );
        console2.log('WETH claimed:', (aliceWethAfter - aliceWethBefore) / 1e18);

        // Verify no rewards left in contract (except escrow)
        uint256 stakingUnderlyingBalance = underlying.balanceOf(address(staking));
        uint256 stakingWethBalance = weth.balanceOf(address(staking));
        uint256 escrowBalance = staking.escrowBalance(address(underlying));

        console2.log('\n=== FINAL BALANCES ===');
        console2.log('Staking underlying balance:', stakingUnderlyingBalance / 1e18, 'tokens');
        console2.log('Escrow balance:', escrowBalance / 1e18, 'tokens');
        console2.log('Staking WETH balance:', stakingWethBalance / 1e18, 'WETH');
        console2.log(
            'Unaccounted underlying:',
            (stakingUnderlyingBalance - escrowBalance) / 1e18,
            'tokens'
        );

        // Explanation of remaining balance:
        // When we accrue the second time, the stream RESETS with only the new amount
        // The first stream (600K) was only 1/3 complete, so only ~200K vested
        // The remaining 400K was never added to the new stream, so it remains unaccounted
        console2.log('\n=== KEY INSIGHT ===');
        console2.log('First accrual: 600K tokens, stream for 3 days');
        console2.log('After 1 day: ~200K vested (1/3 of stream)');
        console2.log('Second accrual: 1K tokens, RESETS stream');
        console2.log('The 400K unvested from first stream is lost!');

        // WETH should be fully claimed (it had full 3-day stream)
        assertEq(stakingWethBalance, 0, 'All WETH rewards should be claimed');

        // Verify the unvested amount makes sense
        uint256 unvested = stakingUnderlyingBalance - escrowBalance;
        console2.log('\nUnvested amount:', unvested / 1e18, 'tokens');
        // Should be approximately 400K (2/3 of 600K initial reward)
        assertApproxEqRel(
            unvested,
            400_000 * 1e18,
            0.01e18, // 1% tolerance
            'Unvested should be ~400K tokens'
        );
    }

    function test_apr_calculation_with_small_rewards() public {
        console2.log('=== APR WITH DIFFERENT REWARD AMOUNTS ===\n');

        uint256[] memory rewardAmounts = new uint256[](5);
        rewardAmounts[0] = 1000 * 1e18; // 1K tokens
        rewardAmounts[1] = 10_000 * 1e18; // 10K tokens
        rewardAmounts[2] = 100_000 * 1e18; // 100K tokens
        rewardAmounts[3] = 500_000 * 1e18; // 500K tokens
        rewardAmounts[4] = 1_000_000 * 1e18; // 1M tokens

        for (uint256 i = 0; i < rewardAmounts.length; i++) {
            // Reset state
            vm.warp(1);

            // Accrue rewards
            underlying.mint(address(staking), rewardAmounts[i]);
            staking.accrueRewards(address(underlying));

            uint256 apr = staking.aprBps();
            uint256 rate = staking.rewardRatePerSecond(address(underlying));

            console2.log('Reward Amount (tokens):', rewardAmounts[i] / 1e18);
            console2.log('  Rate/sec:', rate);
            console2.log('  APR in bps:', apr);
            console2.log('  APR as %:', apr / 100);
            console2.log('');

            // Fast forward to claim all
            vm.warp(block.timestamp + 3 days + 1);

            address[] memory tokens = new address[](1);
            tokens[0] = address(underlying);

            uint256 balBefore = underlying.balanceOf(alice);
            vm.prank(alice);
            staking.claimRewards(tokens, alice);
            uint256 balAfter = underlying.balanceOf(alice);

            console2.log('  Claimed (tokens):', (balAfter - balBefore) / 1e18);
            console2.log('  Expected (tokens):', rewardAmounts[i] / 1e18);
            console2.log('---\n');

            // Verify all rewards were emitted
            assertApproxEqRel(
                balAfter - balBefore,
                rewardAmounts[i],
                0.001e18, // 0.1% tolerance
                'Should claim all rewards'
            );
        }
    }

    function test_apr_with_very_low_stake() public {
        console2.log('=== APR WITH LOW TOTAL STAKE ===\n');

        // Create a new scenario with low stake
        LevrStaking_v1 newStaking = new LevrStaking_v1(address(0));
        LevrStakedToken_v1 newStakedToken = new LevrStakedToken_v1(
            'Staked Token Low',
            'sUND2',
            18,
            address(underlying),
            address(newStaking)
        );

        vm.prank(address(factory));
        newStaking.initialize(
            address(underlying),
            address(newStakedToken),
            treasury,
            address(factory)
        );

        // Stake only 100K tokens instead of 10M
        uint256 lowStake = 100_000 * 1e18;
        underlying.mint(alice, lowStake);

        vm.startPrank(alice);
        underlying.approve(address(newStaking), lowStake);
        newStaking.stake(lowStake);
        vm.stopPrank();

        console2.log('Total Staked:', newStaking.totalStaked() / 1e18, 'tokens');

        // Accrue 1000 tokens (same as original scenario)
        underlying.mint(address(newStaking), OUTSTANDING_TOKEN_REWARDS);
        newStaking.accrueRewards(address(underlying));

        uint256 apr = newStaking.aprBps();
        console2.log('Reward Amount (tokens):', OUTSTANDING_TOKEN_REWARDS / 1e18);
        console2.log('APR in bps:', apr);
        console2.log('APR as %:', apr / 100);

        // Calculate expected APR manually
        uint256 annual = (OUTSTANDING_TOKEN_REWARDS * 365 days) / (3 days);
        uint256 expectedApr = (annual * 10_000) / lowStake;
        console2.log('Expected APR in bps:', expectedApr);
        console2.log('Expected APR as %:', expectedApr / 100);

        assertEq(apr, expectedApr, 'APR should match calculation');
    }

    function test_reproduce_exact_125_percent_apr() public {
        console2.log('=== REPRODUCING 125% APR SPIKE ===\n');

        // To get 125% APR with 1000 tokens over 3 days:
        // APR = (annual / totalStaked) * 10_000
        // 12500 = ((1000 * 365 / 3) / totalStaked) * 10_000
        // totalStaked = (1000 * 365 / 3 * 10_000) / 12500
        // totalStaked ≈ 97,333 tokens

        LevrStaking_v1 newStaking = new LevrStaking_v1(address(0));
        LevrStakedToken_v1 newStakedToken = new LevrStakedToken_v1(
            'Staked Token 125',
            'sUND3',
            18,
            address(underlying),
            address(newStaking)
        );

        vm.prank(address(factory));
        newStaking.initialize(
            address(underlying),
            address(newStakedToken),
            treasury,
            address(factory)
        );

        // Stake exactly the amount needed for 125% APR
        uint256 targetStake = 97_333 * 1e18;
        underlying.mint(alice, targetStake);

        vm.startPrank(alice);
        underlying.approve(address(newStaking), targetStake);
        newStaking.stake(targetStake);
        vm.stopPrank();

        console2.log('Total Staked:', newStaking.totalStaked() / 1e18, 'tokens');

        // Accrue 1000 tokens (same as user's scenario)
        underlying.mint(address(newStaking), OUTSTANDING_TOKEN_REWARDS);
        newStaking.accrueRewards(address(underlying));

        uint256 apr = newStaking.aprBps();
        console2.log('Reward Amount (tokens):', OUTSTANDING_TOKEN_REWARDS / 1e18);
        console2.log('APR in bps:', apr);
        console2.log('APR as %:', apr / 100);

        // Should be very close to 125%
        assertApproxEqRel(
            apr,
            12500, // 125% = 12500 bps
            0.005e18, // 0.5% tolerance
            'Should be ~125% APR'
        );

        console2.log('\n=== CONCLUSION ===');
        console2.log('To get 125% APR from 1000 tokens:');
        console2.log('  - Need ~97,333 tokens staked (NOT 10M!)');
        console2.log('  - This suggests the UI is showing incorrect totalStaked');
        console2.log('  - OR there are multiple staking pools and UI shows wrong one');
    }
}
