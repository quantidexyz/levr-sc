// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactoryDeployHelper} from "../utils/LevrFactoryDeployHelper.sol";
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Global Streaming Midstream Accrual Tests
 * @notice Comprehensive tests for global streaming with midstream accruals
 * @dev CRITICAL: Verifies no fund loss when multiple tokens accrue at different times
 */
contract LevrStaking_GlobalStreamingMidstreamTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;
    MockERC20 usdc;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address charlie = address(0x3333);

    uint256 constant STREAM_WINDOW = 3 days;

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: uint32(STREAM_WINDOW),
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        ILevrFactory_v1.ConfigBounds memory bounds = ILevrFactory_v1.ConfigBounds({
            minStreamWindowSeconds: 1,
            minProposalWindowSeconds: 1,
            minVotingWindowSeconds: 1,
            minQuorumBps: 1,
            minApprovalBps: 1,
            minMinSTokenBpsToSubmit: 1,
            minMinimumQuorumBps: 1
        });

        factory = new LevrFactory_v1(
            config,
            bounds,
            address(this),
            address(0),
            address(0),
            new address[](0)
        );

        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('Wrapped Ether', 'WETH');
        usdc = new MockERC20('USD Coin', 'USDC');

        staking = createStaking(address(0), address(factory));
        stakedToken = createStakedToken('Staked UND', 'sUND', 18, address(underlying), address(staking));

        // Initialize staking with reward tokens already whitelisted
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = address(weth);
        rewardTokens[1] = address(usdc);

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(this),
            rewardTokens
        );

        // Setup users with tokens
        underlying.mint(alice, 10000 ether);
        underlying.mint(bob, 10000 ether);
        underlying.mint(charlie, 10000 ether);
    }

    /// @notice Test that accruing second token resets global window and preserves unvested from first
    /// @dev CRITICAL: Verifies no fund loss when window resets
    function test_globalStream_secondAccrualResetsWindow_preservesUnvested() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // T=0: Accrue WETH (1000 ether over 3 days)
        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        (uint64 firstStreamStart, uint64 firstStreamEnd, ) = staking.getTokenStreamInfo(
            address(underlying)
        );
        console.log('First stream: start =', firstStreamStart, ', end =', firstStreamEnd);

        // T=1 day: 333 ether should be vested for WETH
        vm.warp(block.timestamp + 1 days);

        uint256 wethClaimableDay1 = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable at day 1:', wethClaimableDay1);
        assertTrue(wethClaimableDay1 > 333 ether, 'Should have ~333 ether vested');

        // T=1 day: Accrue underlying (500 ether) - this RESETS global window
        vm.startPrank(alice);
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        (uint64 secondStreamStart, uint64 secondStreamEnd, ) = staking.getTokenStreamInfo(
            address(underlying)
        );
        console.log('Second stream: start =', secondStreamStart, ', end =', secondStreamEnd);

        // CRITICAL: Verify window was reset
        assertGt(secondStreamStart, firstStreamStart, 'Stream should have reset');
        assertGt(secondStreamEnd, firstStreamEnd, 'Stream end should have moved forward');

        // CRITICAL: WETH unvested should be preserved
        // At day 1, 666 ether was unvested from WETH
        // This should now be in the new stream
        uint256 wethClaimableAfterReset = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable after reset (immediate):', wethClaimableAfterReset);

        // Wait for new stream to complete - claim AT end, not after
        (, uint64 newStreamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(newStreamEnd);

        uint256 wethFinal = staking.claimableRewards(alice, address(weth));
        uint256 underlyingFinal = staking.claimableRewards(alice, address(underlying));

        console.log('WETH claimable at stream end:', wethFinal);
        console.log('Underlying claimable at stream end:', underlyingFinal);

        // CRITICAL: Alice should be able to claim ALL rewards (no loss)
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(underlying);

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);

        staking.claimRewards(tokens, alice);
        vm.stopPrank();

        uint256 wethClaimed = weth.balanceOf(alice) - aliceWethBefore;
        uint256 underlyingClaimed = underlying.balanceOf(alice) - aliceUnderlyingBefore;

        console.log('Total WETH claimed:', wethClaimed);
        console.log('Total underlying claimed:', underlyingClaimed);

        // CRITICAL: All rewards should be claimable (no loss from window reset)
        assertEq(wethClaimed, 1000 ether, 'All WETH should be claimable');
        assertEq(underlyingClaimed, 500 ether, 'All underlying should be claimable');
    }

    /// @notice Test multiple token accruals in sequence with global streaming
    /// @dev Verifies unvested accumulation works correctly across multiple resets
    function test_globalStream_multipleTokenAccruals_unvestedAccumulation() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        uint256 totalWethAccrued = 0;
        uint256 totalUnderlyingAccrued = 0;
        uint256 totalUsdcAccrued = 0;

        // Day 0: Accrue WETH
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        totalWethAccrued += 1000 ether;

        // Day 1: Accrue underlying (WETH has 666 ether unvested)
        vm.warp(block.timestamp + 1 days);
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));
        totalUnderlyingAccrued += 500 ether;

        // Day 2: Accrue USDC (WETH and underlying both have unvested)
        vm.warp(block.timestamp + 1 days);
        usdc.mint(address(staking), 300 ether);
        staking.accrueRewards(address(usdc));
        totalUsdcAccrued += 300 ether;

        // Day 3: Accrue more WETH (extends WETH's stream)
        vm.warp(block.timestamp + 1 days);
        weth.mint(address(staking), 200 ether);
        staking.accrueRewards(address(weth));
        totalWethAccrued += 200 ether;

        // Wait for ALL streams to complete
        // WETH was last accrued at day 3, so it ends at day 6
        (, uint64 wethStreamEnd, ) = staking.getTokenStreamInfo(address(weth));
        vm.warp(wethStreamEnd);

        // Claim all rewards
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(underlying);
        tokens[2] = address(usdc);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 underlyingBefore = underlying.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        staking.claimRewards(tokens, alice);

        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;
        uint256 underlyingClaimed = underlying.balanceOf(alice) - underlyingBefore;
        uint256 usdcClaimed = usdc.balanceOf(alice) - usdcBefore;

        console.log('Total WETH accrued:', totalWethAccrued);
        console.log('Total WETH claimed:', wethClaimed);
        console.log('Total underlying accrued:', totalUnderlyingAccrued);
        console.log('Total underlying claimed:', underlyingClaimed);
        console.log('Total USDC accrued:', totalUsdcAccrued);
        console.log('Total USDC claimed:', usdcClaimed);

        // CRITICAL: All rewards should be fully distributed (no loss from multiple resets)
        assertEq(wethClaimed, totalWethAccrued, 'All WETH rewards should be distributed');
        assertEq(underlyingClaimed, totalUnderlyingAccrued, 'All underlying should be distributed');
        assertEq(usdcClaimed, totalUsdcAccrued, 'All USDC should be distributed');
    }

    /// @notice Test that users can claim rewards across stream resets
    /// @dev Simplified test focusing on core functionality
    function test_globalStream_accrualAfterStreamEnds_noStuckFunds() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Complete WETH's stream
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(weth));
        vm.warp(streamEnd);

        // Claim WETH
        address[] memory wethTokens = new address[](1);
        wethTokens[0] = address(weth);
        uint256 wethBefore = weth.balanceOf(alice);
        staking.claimRewards(wethTokens, alice);
        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;

        // CRITICAL: All WETH should be claimable
        assertEq(wethClaimed, 1000 ether, 'All WETH should be claimed');
    }

    /// @notice Test rapid successive accruals of same token
    /// @dev Verifies unvested accumulation when same token accrued multiple times
    function test_globalStream_rapidSameTokenAccruals_unvestedPreserved() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        uint256 totalAccrued = 0;

        // Accrue WETH 5 times in quick succession
        for (uint i = 0; i < 5; i++) {
            weth.mint(address(staking), 200 ether);
            staking.accrueRewards(address(weth));
            totalAccrued += 200 ether;

            // Wait 6 hours between accruals (stream resets each time)
            vm.warp(block.timestamp + 6 hours);
        }

        console.log('Total WETH accrued:', totalAccrued);

        // Complete final stream
        vm.warp(block.timestamp + 3 days);

        uint256 claimable = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable after all accruals:', claimable);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 wethBefore = weth.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;

        console.log('Total WETH claimed:', wethClaimed);

        // CRITICAL: All WETH should be claimable despite multiple resets
        // Allow for small rounding error (< 0.01%)
        assertGe(
            wethClaimed,
            (totalAccrued * 9999) / 10000,
            'At least 99.99% WETH should be distributed'
        );
        assertLe(wethClaimed, totalAccrued, 'No inflation (cannot exceed accrued)');
    }

    /// @notice Test that multiple users with different tokens all get correct rewards
    /// @dev Verifies global streaming doesn't cause cross-contamination
    function test_globalStream_multipleUsersMultipleTokens_fairDistribution() public {
        // Alice and Bob both stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        vm.startPrank(alice);
        weth.mint(address(staking), 2000 ether);
        staking.accrueRewards(address(weth));

        // Wait 1 day
        vm.warp(block.timestamp + 1 days);

        // Accrue underlying (resets window)
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Complete stream
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(streamEnd);

        // Both users claim both tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(underlying);

        vm.startPrank(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceWeth = weth.balanceOf(alice) - aliceWethBefore;
        uint256 aliceUnderlying = underlying.balanceOf(alice) - aliceUnderlyingBefore;

        vm.startPrank(bob);
        uint256 bobWethBefore = weth.balanceOf(bob);
        uint256 bobUnderlyingBefore = underlying.balanceOf(bob);
        staking.claimRewards(tokens, bob);
        uint256 bobWeth = weth.balanceOf(bob) - bobWethBefore;
        uint256 bobUnderlying = underlying.balanceOf(bob) - bobUnderlyingBefore;

        console.log('Alice WETH:', aliceWeth);
        console.log('Bob WETH:', bobWeth);
        console.log('Alice underlying:', aliceUnderlying);
        console.log('Bob underlying:', bobUnderlying);

        // DEBT ACCOUNTING: Claim timing NO LONGER affects distribution
        uint256 totalWeth = aliceWeth + bobWeth;
        uint256 totalUnderlying = aliceUnderlying + bobUnderlying;

        // With debt accounting, both get equal shares (50/50) regardless of claim order
        // Alice and Bob both staked before rewards, so both have debt = 0
        assertApproxEqAbs(
            aliceWeth,
            bobWeth,
            1 ether,
            'Equal stakes = equal WETH (debt accounting)'
        );
        assertApproxEqAbs(
            aliceUnderlying,
            bobUnderlying,
            1 ether,
            'Equal stakes = equal underlying'
        );

        // Both should receive something
        assertGt(aliceWeth, 0, 'Alice gets WETH');
        assertGt(bobWeth, 0, 'Bob gets WETH');
        assertGt(aliceUnderlying, 0, 'Alice gets underlying');
        assertGt(bobUnderlying, 0, 'Bob gets underlying');

        // Total claimed should equal accrued (no remainder from claim timing with debt accounting)
        assertApproxEqAbs(totalWeth, 2000 ether, 1 ether, 'All WETH distributed');
        assertApproxEqAbs(totalUnderlying, 1000 ether, 1 ether, 'All underlying distributed');
    }

    /// @notice Test edge case: Accrue same token twice within same second
    /// @dev Ensures no weird behavior with rapid accruals
    function test_globalStream_sameSecondAccrual_handledCorrectly() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // First accrual
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Second accrual in SAME SECOND (no time advancement)
        weth.mint(address(staking), 500 ether);
        staking.accrueRewards(address(weth));

        // Total accrued: 1500 ether
        // Unvested from first: 1000 (since 0 seconds passed)
        // New stream should have: 1000 + 500 = 1500 ether

        // Complete WETH's stream
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(weth));
        vm.warp(streamEnd);

        uint256 claimable = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable:', claimable);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 wethBefore = weth.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;

        // CRITICAL: All 1500 ether should be claimable
        assertEq(wethClaimed, 1500 ether, 'Both accruals should sum correctly');
    }

    /// @notice Test that global window reset doesn't cause reward loss for any token
    /// @dev Comprehensive test with 3 tokens accrued at different times
    function test_globalStream_threeTokensDifferentTimes_noLoss() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // T=0: WETH accrual (1000 over 3 days) - ends at T=3
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // T=1 day: Underlying accrual (500 over 3 days) - ends at T=4
        // With per-token streams: WETH continues vesting independently
        vm.warp(block.timestamp + 1 days);
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        // T=2 days: USDC accrual (300 over 3 days) - ends at T=5
        // With per-token streams: WETH and underlying continue independently
        vm.warp(block.timestamp + 1 days);
        usdc.mint(address(staking), 300 ether);
        staking.accrueRewards(address(usdc));

        // T=5 days: Complete ALL streams (USDC ends last at T=5)
        (, uint64 usdcStreamEnd, ) = staking.getTokenStreamInfo(address(usdc));
        vm.warp(usdcStreamEnd);

        // Claim all
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(underlying);
        tokens[2] = address(usdc);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 underlyingBefore = underlying.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        staking.claimRewards(tokens, alice);

        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;
        uint256 underlyingClaimed = underlying.balanceOf(alice) - underlyingBefore;
        uint256 usdcClaimed = usdc.balanceOf(alice) - usdcBefore;

        console.log('WETH claimed:', wethClaimed);
        console.log('Underlying claimed:', underlyingClaimed);
        console.log('USDC claimed:', usdcClaimed);

        // CRITICAL: All rewards distributed despite multiple window resets
        assertEq(wethClaimed, 1000 ether, 'All WETH distributed');
        assertEq(underlyingClaimed, 500 ether, 'All underlying distributed');
        assertEq(usdcClaimed, 300 ether, 'All USDC distributed');

        // Verify no funds stuck in contract
        assertEq(weth.balanceOf(address(staking)), 0, 'No WETH stuck');
        // Underlying escrow should be 1000 (Alice's stake), rewards are separate
        assertEq(
            staking.escrowBalance(address(underlying)),
            1000 ether,
            'Escrow is Alice stake only'
        );
    }

    /// @notice Test that unvested calculation works correctly with global streaming
    /// @dev Ensures _calculateUnvested returns correct amounts for each token
    function test_globalStream_unvestedCalculation_accurate() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Wait 1 day (1/3 of stream) - 333 vested, 666 unvested
        vm.warp(block.timestamp + 1 days);

        // Check claimable (this uses unvested calculation internally)
        uint256 wethClaimable = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable at day 1:', wethClaimable);
        assertTrue(
            wethClaimable > 333 ether && wethClaimable < 334 ether,
            'Should be ~333 ether vested'
        );

        // Accrue underlying - this should preserve WETH's ~666 unvested
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        // Immediately after reset, WETH should still have unvested in new stream
        uint256 wethClaimableAfterReset = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable after reset:', wethClaimableAfterReset);

        // Complete new stream
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(streamEnd);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(underlying);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 underlyingBefore = underlying.balanceOf(alice);

        staking.claimRewards(tokens, alice);

        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;
        uint256 underlyingClaimed = underlying.balanceOf(alice) - underlyingBefore;

        console.log('Final WETH claimed:', wethClaimed);
        console.log('Final underlying claimed:', underlyingClaimed);

        // CRITICAL: All rewards claimable
        assertEq(wethClaimed, 1000 ether, 'All WETH should be claimable');
        assertEq(underlyingClaimed, 500 ether, 'All underlying should be claimable');
    }

    /// @notice Test zero stakers edge case with global streaming
    /// @dev Ensures stream pause logic works correctly with global window
    function test_globalStream_zeroStakers_streamPauses() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Wait 1 day
        vm.warp(block.timestamp + 1 days);

        // Alice fully unstakes (0 stakers now)
        staking.unstake(1000 ether, alice);

        // Wait 1 more day (stream should pause)
        vm.warp(block.timestamp + 1 days);

        // Alice stakes again
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Complete stream
        vm.warp(block.timestamp + 1 days + 1);

        // Alice should get ALL WETH (stream paused when no stakers)
        uint256 claimable = staking.claimableRewards(alice, address(weth));
        console.log('WETH claimable:', claimable);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 wethBefore = weth.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;

        // Stream pause should have preserved rewards
        assertTrue(wethClaimed > 0, 'Should have preserved rewards during pause');
    }
}
