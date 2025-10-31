// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Governance Boost Mid-Stream Test
 * @notice Verify that governance boost doesn't lose rewards when called mid-stream
 * @dev The boost path also calls _creditRewards(), so it had the same bug
 */
contract LevrStakingV1GovernanceBoostMidstreamTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    LevrTreasury_v1 treasury;
    MockERC20 underlying;

    address alice = address(0xA11CE);
    address mockGovernor = address(0x6066);

    function setUp() public {
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
            minimumQuorumBps: 25, // 0.25% minimum quorum
            maxRewardTokens: 10 // Max non-whitelisted reward tokens
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0));
        underlying = new MockERC20('Underlying Token', 'UND');

        // Deploy treasury, staking, staked token
        treasury = new LevrTreasury_v1(address(factory), address(0));
        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize contracts
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(treasury),
            address(factory)
        );

        vm.prank(address(factory));
        treasury.initialize(mockGovernor, address(underlying));

        // Alice stakes 10M tokens
        underlying.mint(alice, 10_000_000 * 1e18);
        vm.startPrank(alice);
        underlying.approve(address(staking), 10_000_000 * 1e18);
        staking.stake(10_000_000 * 1e18);
        vm.stopPrank();

        // Fund treasury with tokens for boost
        underlying.mint(address(treasury), 1_000_000 * 1e18);
    }

    /// @notice Test that treasury boost (accrueFromTreasury) mid-stream preserves unvested rewards
    function test_treasuryBoostMidstream_preservesUnvestedRewards() public {
        console2.log('=== TREASURY BOOST MID-STREAM TEST ===\n');

        // First: Manual accrual of 600K
        underlying.mint(address(staking), 600_000 * 1e18);
        staking.accrueRewards(address(underlying));

        console2.log('Initial accrual: 600K tokens');
        console2.log('Stream window: 3 days');

        // Wait 1 day (1/3 of stream)
        vm.warp(block.timestamp + 1 days);
        console2.log('\nAfter 1 day:');
        console2.log('  Vested: ~200K (1/3)');
        console2.log('  Unvested: ~400K (2/3)');

        // Treasury boost: Simulate governance boost via accrueFromTreasury
        console2.log('\nTreasury boost: 50K tokens');

        // Transfer from treasury to staking and accrue
        underlying.mint(address(staking), 50_000 * 1e18);

        vm.prank(address(treasury));
        staking.accrueFromTreasury(address(underlying), 50_000 * 1e18, false);

        console2.log('  accrueFromTreasury() called');

        // Complete the stream
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(streamEnd);

        // Claim all rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;
        uint256 totalExpected = 600_000 * 1e18 + 50_000 * 1e18;

        // Check for stuck rewards
        uint256 stakingBalance = underlying.balanceOf(address(staking));
        uint256 escrowBalance = staking.escrowBalance(address(underlying));
        uint256 stuck = stakingBalance - escrowBalance;

        console2.log('\n=== RESULTS ===');
        console2.log('Total rewards (manual + boost):', totalExpected / 1e18);
        console2.log('Total claimed:', claimed / 1e18);
        console2.log('Stuck:', stuck / 1e18);

        // With the fix, treasury boost should preserve unvested rewards
        assertEq(stuck, 0, 'No rewards should be stuck (treasury boost fix verified)');
        assertApproxEqRel(
            claimed,
            totalExpected,
            0.001e18,
            'Should claim all rewards including boost (fix verified)'
        );
    }

    /// @notice Test multiple treasury boosts during same stream
    function test_multipleTreasuryBoosts_midstream() public {
        console2.log('=== MULTIPLE TREASURY BOOSTS MID-STREAM ===\n');

        // Initial manual accrual
        underlying.mint(address(staking), 500_000 * 1e18);
        staking.accrueRewards(address(underlying));
        uint256 totalAccrued = 500_000 * 1e18;

        console2.log('Initial: 500K tokens');

        // Boost 1: After 1 day
        vm.warp(block.timestamp + 1 days);
        underlying.mint(address(staking), 100_000 * 1e18);
        vm.prank(address(treasury));
        staking.accrueFromTreasury(address(underlying), 100_000 * 1e18, false);
        totalAccrued += 100_000 * 1e18;
        console2.log('Boost 1 (day 1): 100K tokens');

        // Boost 2: After another day
        vm.warp(block.timestamp + 1 days);
        underlying.mint(address(staking), 50_000 * 1e18);
        vm.prank(address(treasury));
        staking.accrueFromTreasury(address(underlying), 50_000 * 1e18, false);
        totalAccrued += 50_000 * 1e18;
        console2.log('Boost 2 (day 2): 50K tokens');

        // Complete final stream
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(underlying));
        vm.warp(streamEnd);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;

        console2.log('\n=== RESULTS ===');
        console2.log('Total accrued (manual + boosts):', totalAccrued / 1e18);
        console2.log('Total claimed:', claimed / 1e18);

        // Multiple boosts should all be preserved
        assertApproxEqRel(
            claimed,
            totalAccrued,
            0.001e18,
            'Should claim all rewards from multiple boosts (fix verified)'
        );
    }
}
