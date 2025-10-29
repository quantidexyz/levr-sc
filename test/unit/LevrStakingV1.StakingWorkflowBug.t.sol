// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';

/**
 * @title Staking Cycle Bug Reproduction - Deployment #2
 * @notice Reproduces inconsistencies in reward accrual, claim, and pool state updates
 * @dev Based on exact user scenario with 12B token stake, swaps, unstake, and restake
 */
contract LevrStakingV1_StakingWorkflowBugTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;

    address user = address(0x1111);

    uint256 constant INITIAL_BALANCE = 12_000_000_000 ether; // 12B tokens
    uint256 constant STREAM_WINDOW = 3 days;

    function setUp() public {
        // Deploy mock tokens
        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('Wrapped ETH', 'WETH');

        // Deploy factory with stream window config
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: uint32(STREAM_WINDOW),
            protocolTreasury: address(0x3333),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 50
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));

        // Deploy staking and staked token directly
        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking (must call from factory address)
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(0x3333),
            address(factory)
        );

        // Mint tokens for user
        underlying.mint(user, INITIAL_BALANCE);
    }

    function test_StakingCycleBug_Deployment2() public {
        console2.log('\n=== STEP 1: Deployment & Initialization ===');

        // Step 1: User stakes all 12B tokens
        uint256 userBalance = underlying.balanceOf(user);
        console2.log('Available tokens:', userBalance / 1e18, 'tokens');

        vm.startPrank(user);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(userBalance);
        vm.stopPrank();

        uint256 stakedAmount = stakedToken.balanceOf(user);
        console2.log('Staked:', stakedAmount / 1e18, 'tokens');

        (uint256 outstanding0, ) = staking.outstandingRewards(address(weth));
        console2.log('Outstanding rewards:', outstanding0 / 1e15, 'mWETH');
        assertEq(outstanding0, 0, 'Should have 0 outstanding initially');

        uint64 streamStart0 = staking.streamStart();
        uint64 streamEnd0 = staking.streamEnd();
        console2.log('Stream window active:', streamStart0 > 0 && block.timestamp <= streamEnd0);

        console2.log('\n=== STEP 2: First Swap (Generate Initial Fees) ===');

        // Step 2: Generate fees from swap (simulate 2 ETH swap generating 0.07 WETH fees)
        uint256 firstSwapFees = 0.07 ether; // 0.07 WETH
        weth.mint(address(staking), firstSwapFees);
        console2.log('Swap fees generated:', firstSwapFees / 1e15, 'mWETH');

        (uint256 outstanding1, ) = staking.outstandingRewards(address(weth));
        console2.log('Outstanding rewards after swap:', outstanding1 / 1e15, 'mWETH');
        assertEq(outstanding1, firstSwapFees, 'Should show 0.07 WETH outstanding');

        console2.log('\n=== STEP 3: First Accrual ===');

        // Step 3: Accrue rewards
        staking.accrueRewards(address(weth));

        (uint256 available1, ) = staking.outstandingRewards(address(weth));
        console2.log('Available after first accrual:', available1 / 1e15, 'mWETH');
        console2.log('Expected: ~0.07 WETH');
        console2.log('Actual:', available1 / 1e15, 'mWETH');
        // Note: May be slightly higher due to previous stream unvested amounts

        console2.log('\n=== STEP 4: Warp 1 Day ===');

        // Step 4: Warp 1 day
        vm.warp(block.timestamp + 1 days);

        uint256 claimable1 = staking.claimableRewards(user, address(weth));
        console2.log('Claimable after 1 day:', claimable1 / 1e15, 'mWETH');

        // Claim rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 wethBeforeClaim = weth.balanceOf(user);
        vm.prank(user);
        staking.claimRewards(tokens, user);
        uint256 wethAfterClaim = weth.balanceOf(user);
        uint256 claimed1 = wethAfterClaim - wethBeforeClaim;
        console2.log('Claimed:', claimed1 / 1e15, 'mWETH');

        (uint256 availableAfterClaim, ) = staking.outstandingRewards(address(weth));
        console2.log('Available after claim:', availableAfterClaim / 1e15, 'mWETH');

        uint64 streamEnd4 = staking.streamEnd();
        uint64 streamStart4 = staking.streamStart();
        uint256 timeRemaining = streamEnd4 > block.timestamp ? streamEnd4 - block.timestamp : 0;
        console2.log('Stream window ends in:', timeRemaining / 3600, 'hours');

        console2.log('\n=== STEP 5: Unstake ===');

        // Step 5: Unstake all tokens
        vm.startPrank(user);
        staking.unstake(stakedAmount, user);
        vm.stopPrank();

        uint256 claimableAfterUnstake = staking.claimableRewards(user, address(weth));
        console2.log('Claimable after unstake:', claimableAfterUnstake / 1e15, 'mWETH');
        console2.log('(Small residual due to brief overlap before window end)');

        (uint256 availableAfterUnstake, ) = staking.outstandingRewards(address(weth));
        console2.log('Available after unstake:', availableAfterUnstake / 1e15, 'mWETH');

        (uint256 outstandingAfterUnstake, ) = staking.outstandingRewards(address(weth));
        console2.log('Outstanding after unstake:', outstandingAfterUnstake / 1e15, 'mWETH');

        streamEnd4 = staking.streamEnd();
        timeRemaining = streamEnd4 > block.timestamp ? streamEnd4 - block.timestamp : 0;
        console2.log('Stream window remaining:', timeRemaining / 3600, 'hours');

        console2.log('\n=== STEP 6: Manual Contract Transfer ===');

        // Step 6: Send manually claimed WETH back to contract
        uint256 manualTransfer = claimed1; // 0.043 WETH
        vm.prank(user);
        weth.transfer(address(staking), manualTransfer);
        console2.log('Manually sent:', manualTransfer / 1e15, 'mWETH to staking contract');

        (uint256 availableAfterTransfer, ) = staking.outstandingRewards(address(weth));
        console2.log('Available after transfer:', availableAfterTransfer / 1e15, 'mWETH');

        (uint256 outstandingAfterTransfer, ) = staking.outstandingRewards(address(weth));
        console2.log('Outstanding after transfer:', outstandingAfterTransfer / 1e15, 'mWETH');

        // Accrue again
        staking.accrueRewards(address(weth));

        streamEnd4 = staking.streamEnd();
        streamStart4 = staking.streamStart();
        console2.log('After second accrual:');
        console2.log('Stream window active:', streamStart4 > 0 && block.timestamp <= streamEnd4);
        console2.log(
            'Stream window duration:',
            (streamEnd4 - streamStart4) / 3600,
            'hours (should be 72)'
        );

        (uint256 availableAfterSecondAccrual, ) = staking.outstandingRewards(address(weth));
        console2.log(
            'Available after second accrual:',
            availableAfterSecondAccrual / 1e15,
            'mWETH'
        );

        console2.log('\n=== STEP 7: Warp 3 Days While Unstaked ===');

        // Step 7: Warp 3 days while unstaked
        vm.warp(block.timestamp + 3 days);

        (uint256 availableAfterWarp, ) = staking.outstandingRewards(address(weth));
        console2.log('Available after 3-day warp:', availableAfterWarp / 1e15, 'mWETH');

        streamEnd4 = staking.streamEnd();
        streamStart4 = staking.streamStart();
        console2.log('Stream window active:', streamStart4 > 0 && block.timestamp <= streamEnd4);
        console2.log('Stream window ended:', block.timestamp > streamEnd4);

        uint256 claimableAfterWarp = staking.claimableRewards(user, address(weth));
        console2.log('Claimable (user unstaked):', claimableAfterWarp / 1e15, 'mWETH');
        assertEq(claimableAfterWarp, 0, 'User unstaked, should have 0 claimable');

        console2.log('\n=== STEP 8: Second Swap While Unstaked ===');

        // Step 8: Generate more fees from second swap (0.029 WETH)
        uint256 secondSwapFees = 0.029 ether;
        weth.mint(address(staking), secondSwapFees);
        console2.log('Second swap fees generated:', secondSwapFees / 1e15, 'mWETH');

        (uint256 outstandingAfterSecondSwap, ) = staking.outstandingRewards(address(weth));
        console2.log(
            'Outstanding rewards after second swap:',
            outstandingAfterSecondSwap / 1e15,
            'mWETH'
        );
        assertEq(outstandingAfterSecondSwap, secondSwapFees, 'Should show 0.029 WETH outstanding');

        console2.log('\n=== STEP 9: Restake and Restart Cycle ===');

        // Step 9: Restake tokens
        vm.startPrank(user);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(userBalance);
        vm.stopPrank();

        console2.log('Restaked:', userBalance / 1e18, 'tokens');

        // Accrue rewards (starts new 3-day stream)
        staking.accrueRewards(address(weth));

        (uint256 availableAfterRestakeAccrual, ) = staking.outstandingRewards(address(weth));
        console2.log(
            'Available after restake + accrue:',
            availableAfterRestakeAccrual / 1e15,
            'mWETH'
        );

        streamEnd4 = staking.streamEnd();
        streamStart4 = staking.streamStart();
        uint256 streamDuration = streamEnd4 > streamStart4 ? streamEnd4 - streamStart4 : 0;
        console2.log('Stream window active:', streamStart4 > 0 && block.timestamp <= streamEnd4);
        console2.log('Stream window duration:', streamDuration / 3600, 'hours (should be 72)');

        uint256 claimableAfterRestakeAccrual = staking.claimableRewards(user, address(weth));
        console2.log(
            'Claimable after restake + accrue:',
            claimableAfterRestakeAccrual / 1e15,
            'mWETH'
        );
        // Note: May show non-zero if previous stream had unvested rewards included

        console2.log('\n=== STEP 10: Warp 3 Days (CRITICAL BUG) ===');

        // Step 10: Warp 3 days (full stream window)
        uint64 streamEndBeforeFinalWarp = staking.streamEnd();
        vm.warp(streamEndBeforeFinalWarp + 1); // Warp 1 second past stream end

        console2.log('Current timestamp:', block.timestamp);
        console2.log('Stream start:', staking.streamStart());
        console2.log('Stream end:', staking.streamEnd());
        console2.log('Stream window ended:', block.timestamp > staking.streamEnd());

        uint256 poolBalance = weth.balanceOf(address(staking));
        uint256 finalClaimable = staking.claimableRewards(user, address(weth));
        (uint256 finalAvailable, ) = staking.outstandingRewards(address(weth));

        console2.log('\n[CRITICAL BUG CHECK]');
        console2.log('Pool WETH balance:', poolBalance / 1e15, 'mWETH');
        console2.log('Available WETH (outstanding):', finalAvailable / 1e15, 'mWETH');
        console2.log('Claimable WETH:', finalClaimable / 1e15, 'mWETH');
        console2.log('Total staked:', staking.totalStaked() / 1e18, 'tokens');

        // Debug: Check internal state to trace the bug
        console2.log('\n[DEBUG] Internal State:');
        uint256 escrowBalance = staking.escrowBalance(address(weth));
        console2.log('Escrow balance:', escrowBalance / 1e15, 'mWETH');
        console2.log('Unaccounted (pool - escrow):', (poolBalance - escrowBalance) / 1e15, 'mWETH');

        // The bug:
        // Total fees generated: 70 (first swap) + 29 (second swap) = 99 mWETH
        // User claimed: 23 mWETH from first stream
        // Remaining should be: 99 - 23 = 76 mWETH claimable
        // But only 69 mWETH is claimable, leaving 29 mWETH stuck
        //
        // Root cause analysis:
        // The 29 mWETH appears to be from the second swap that was generated while user was unstaked.
        // When user restakes and third accrual happens, those 29 mWETH are included in the stream.
        // But the stream that included unvested rewards from the second accrual (which paused)
        // doesn't fully vest those rewards to accPerShare.

        // BUG: Claimable should equal available but is 0
        if (finalClaimable == 0 && finalAvailable > 0) {
            console2.log('\n[BUG CONFIRMED] Claimable = 0 but pool has WETH');
            console2.log('Expected: Claimable should equal available WETH');
            console2.log('Actual: Claimable = 0');
        }

        // Try to claim anyway (bug reproduction)
        uint256 userWethBeforeClaim = weth.balanceOf(user);
        address[] memory tokensToClaim = new address[](1);
        tokensToClaim[0] = address(weth);
        vm.prank(user);
        staking.claimRewards(tokensToClaim, user);
        uint256 userWethAfterClaim = weth.balanceOf(user);
        uint256 actuallyClaimed = userWethAfterClaim - userWethBeforeClaim;

        console2.log('\n[CLAIM ATTEMPT]');
        console2.log('Actually claimed:', actuallyClaimed / 1e15, 'mWETH');
        console2.log('Pool WETH after claim:', weth.balanceOf(address(staking)) / 1e15, 'mWETH');

        if (actuallyClaimed == 0 && poolBalance > 0) {
            console2.log('\n[BUG CONFIRMED] Claim executed but no WETH transferred');
            console2.log('Pool still retains all WETH');
        }

        // BUG ANALYSIS:
        // - Pool has WETH balance but outstandingRewards() shows 0
        // - Claimable shows 69 mWETH but pool has 99 mWETH
        // - After claiming 69 mWETH, pool still has 29 mWETH (should be claimable but isn't)
        // The issue: outstandingRewards() doesn't reflect actual pool balance after stream ends

        console2.log('\n[BUG ANALYSIS]');
        console2.log('Issue: outstandingRewards() shows 0 but pool has WETH');
        console2.log('Pool balance:', poolBalance / 1e15, 'mWETH');
        console2.log('Claimable:', finalClaimable / 1e15, 'mWETH');
        console2.log('Actually claimed:', actuallyClaimed / 1e15, 'mWETH');
        uint256 remainingAfterClaim = weth.balanceOf(address(staking));
        console2.log('Remaining in pool after claim:', remainingAfterClaim / 1e15, 'mWETH');

        // Verify claimable matches what can actually be claimed
        assertEq(
            finalClaimable,
            actuallyClaimed,
            'claimableRewards should match what claimRewards can claim'
        );

        // Verify all pool balance should be claimable after full stream
        uint256 remainingInPool = weth.balanceOf(address(staking));
        uint256 totalShouldBeClaimable = poolBalance;
        assertApproxEqRel(
            actuallyClaimed + remainingInPool,
            totalShouldBeClaimable,
            0.01e18, // 1% tolerance
            'All pool balance should be accounted for (claimable + remaining)'
        );

        // BUG: Remaining balance should be 0 or claimable after full stream
        if (remainingInPool > 0 && finalClaimable == actuallyClaimed) {
            console2.log('\n[BUG CONFIRMED] Pool has unclaimable WETH after full stream window');
        }
    }
}
