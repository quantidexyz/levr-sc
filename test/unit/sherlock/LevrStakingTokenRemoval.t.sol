// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {MockClankerToken} from '../../mocks/MockClankerToken.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {ILevrStaking_v1} from '../../../src/interfaces/ILevrStaking_v1.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';

/**
 * @title LevrStakingTokenRemoval Tests
 * @notice Tests for token removal and re-whitelisting with stale debt detection
 * @dev Tests the fix for accounting corruption when tokens are removed and re-added
 */
contract LevrStakingTokenRemovalTest is Test, LevrFactoryDeployHelper {
    LevrStaking_v1 public staking;
    LevrStakedToken_v1 public sToken;
    MockClankerToken public underlying;
    MockERC20 public rewardTokenX;
    MockERC20 public weth;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public tokenAdmin = address(0x4);
    address public treasury = address(0x5);

    // Mock factory functions for testing
    function clankerFactory() external pure returns (address) {
        return address(0);
    }

    function streamWindowSeconds(address) external pure returns (uint32) {
        return 1 days;
    }

    function setUp() public {
        // Deploy underlying token with token admin
        underlying = new MockClankerToken('Underlying', 'UND', tokenAdmin);

        // Deploy staking and staked token
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked UND',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking
        initializeStakingWithRewardTokens(
            staking,
            address(underlying),
            address(sToken),
            treasury,
            address(this),
            new address[](0)
        );

        // Deploy reward tokens
        rewardTokenX = new MockERC20('Token X', 'X');
        weth = new MockERC20('Wrapped ETH', 'WETH');

        // Fund users
        underlying.mint(alice, 10_000e18);
        underlying.mint(bob, 10_000e18);
        underlying.mint(carol, 10_000e18);

        // Approve staking
        vm.prank(alice);
        underlying.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        underlying.approve(address(staking), type(uint256).max);
        vm.prank(carol);
        underlying.approve(address(staking), type(uint256).max);
    }

    /// @notice Test that re-whitelisting resets accRewardPerShare to 0
    function test_ReWhitelisting_ResetsAccounting() public {
        // 1. Whitelist token X
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        // 2. Alice stakes
        vm.prank(alice);
        staking.stake(1000e18);

        // 3. Distribute rewards
        rewardTokenX.mint(address(staking), 1000e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // accRewardPerShare[X] should be > 0 now

        // 4. Alice claims all
        vm.prank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);
        staking.claimRewards(tokens, alice);

        // 5. Unwhitelist and remove
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));

        // 6. Re-whitelist - should reset accounting
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        // Verify token is whitelisted again
        assertTrue(staking.isTokenWhitelisted(address(rewardTokenX)));

        // Note: We can't directly check accRewardPerShare[X] == 0 without a getter
        // But we can verify behavior in subsequent tests
    }

    /// @notice Test that stale debt is detected and reset on claim
    function test_StaleDebtDetection_ResetsOnClaim() public {
        // Phase 1: Token X used, Alice earns 1000 rewards
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        rewardTokenX.mint(address(staking), 1000e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Alice claims all rewards
        vm.prank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);
        staking.claimRewards(tokens, alice);

        uint256 aliceBalanceAfterClaim = rewardTokenX.balanceOf(alice);
        assertEq(aliceBalanceAfterClaim, 1000e18, 'Alice should have 1000 tokens');

        // Phase 2: Token X removed
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));

        // Phase 3: Bob stakes while X is removed
        vm.prank(bob);
        staking.stake(1000e18);

        // Phase 4: Token X re-added with accounting reset
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        // Phase 5: New 100 rewards distributed
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Phase 6: Check claimable - Alice should get 0 on first claim (debt reset)
        uint256 bobClaimable = staking.claimableRewards(bob, address(rewardTokenX));

        // Alice gets 0 on first check (debt will be reset on actual claim)
        // Bob gets his fair share
        assertApproxEqRel(bobClaimable, 50e18, 0.01e18, 'Bob should get ~50 tokens');

        // Phase 7: Claim to trigger debt reset
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        // Check received amounts
        uint256 bobReceived = rewardTokenX.balanceOf(bob);
        assertApproxEqRel(bobReceived, 50e18, 0.01e18, 'Bob should receive ~50 tokens');
    }

    /// @notice Test that no assets get stuck after token removal and re-add
    function test_NoStuckAssets_AllRewardsClaimable() public {
        // Phase 1: Alice stakes and earns rewards
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        rewardTokenX.mint(address(staking), 1000e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Alice claims
        vm.prank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);
        staking.claimRewards(tokens, alice);

        // Phase 2: Remove token
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));

        // Phase 3: Bob stakes while removed
        vm.prank(bob);
        staking.stake(1000e18);

        // Phase 4: Re-add token
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        // Phase 5: Distribute 100 new rewards
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Phase 6: First claim round (triggers debt reset for Alice)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        // Phase 7: Distribute another 100 rewards
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Phase 8: Second claim round
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        // Check that rewards are claimable
        // After fix: Alice gets fair share in both rounds (50 + 50 = 100)
        uint256 totalClaimed = rewardTokenX.balanceOf(alice) +
            rewardTokenX.balanceOf(bob) -
            1000e18;
        assertApproxEqRel(
            totalClaimed,
            200e18,
            0.01e18,
            'Should have claimed 200 (Bob: 50+50, Alice: 50+50)'
        );

        // Verify Alice earns fairly with fixed stale debt (got 50 first round, 50 second round)
        uint256 aliceTotal = rewardTokenX.balanceOf(alice) - 1000e18; // Subtract first 1000
        assertApproxEqRel(aliceTotal, 100e18, 0.02e18, 'Alice should earn ~100 from both rounds');
    }

    /// @notice Test multiple users with different stake times
    function test_MultipleUsers_DifferentStakeTimes() public {
        // Setup: Alice stakes before token removal
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        rewardTokenX.mint(address(staking), 1000e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);
        staking.claimRewards(tokens, alice);

        // Remove token
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));

        // Bob stakes during removal
        vm.prank(bob);
        staking.stake(1000e18);

        // Re-add token
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        // Carol stakes after re-add
        vm.prank(carol);
        staking.stake(1000e18);

        // Distribute rewards
        rewardTokenX.mint(address(staking), 150e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // All claim
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        vm.prank(carol);
        staking.claimRewards(tokens, carol);

        // After fix: All users get fair share (~50 each)
        uint256 aliceClaimed = rewardTokenX.balanceOf(alice) - 1000e18;
        uint256 bobClaimed = rewardTokenX.balanceOf(bob);
        uint256 carolClaimed = rewardTokenX.balanceOf(carol);

        assertApproxEqRel(aliceClaimed, 50e18, 0.02e18, 'Alice gets ~50 (debt reset to 0)');
        assertApproxEqRel(bobClaimed, 50e18, 0.02e18, 'Bob should get ~50');
        assertApproxEqRel(carolClaimed, 50e18, 0.02e18, 'Carol should get ~50');

        // Verify total equals full distribution (150 total)
        uint256 totalClaimed = aliceClaimed + bobClaimed + carolClaimed;
        assertApproxEqRel(totalClaimed, 150e18, 0.02e18, 'Total should be ~150 (all users fair)');
    }

    /// @notice Test normal operation is unaffected (debt <= accReward)
    function test_NormalOperation_Unaffected() public {
        // Normal staking without token removal
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(bob);
        staking.stake(1000e18);

        // Distribute rewards
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        // Each gets half
        assertApproxEqRel(rewardTokenX.balanceOf(alice), 50e18, 0.01e18, 'Alice gets 50');
        assertApproxEqRel(rewardTokenX.balanceOf(bob), 50e18, 0.01e18, 'Bob gets 50');

        // Distribute more
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        // Total should be 100 each
        assertApproxEqRel(rewardTokenX.balanceOf(alice), 100e18, 0.01e18, 'Alice total 100');
        assertApproxEqRel(rewardTokenX.balanceOf(bob), 100e18, 0.01e18, 'Bob total 100');
    }

    /// @notice Test that fresh token whitelisting still works
    function test_FreshToken_InitializesCorrectly() public {
        // Whitelist a fresh token
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(weth));

        assertTrue(staking.isTokenWhitelisted(address(weth)));

        // Use it normally
        vm.prank(alice);
        staking.stake(1000e18);

        weth.mint(address(staking), 100e18);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 1 days);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        assertApproxEqRel(weth.balanceOf(alice), 100e18, 0.01e18, 'Alice claims fresh token');
    }

    /// @notice CRITICAL: Test users must claim BEFORE unwhitelist (enforced by availablePool check)
    function test_UnwhitelistEnforcesEmptyPool() public {
        // Phase 1: Setup - Alice stakes, rewards accumulate
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        // Distribute rewards
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Phase 2: Try to unwhitelist WITH pending rewards - should REVERT
        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrStaking_v1.CannotUnwhitelistWithPendingRewards.selector);
        staking.unwhitelistToken(address(rewardTokenX));

        // Phase 3: Alice claims all rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        assertApproxEqRel(rewardTokenX.balanceOf(alice), 100e18, 0.01e18, 'Alice claimed');

        // Phase 4: NOW unwhitelist succeeds (availablePool = 0)
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        // Phase 5: Alice can still unstake (critical!)
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(1000e18, alice);
        uint256 aliceUnderlyingReturned = underlying.balanceOf(alice) - aliceUnderlyingBefore;

        assertEq(aliceUnderlyingReturned, 1000e18, 'Alice gets underlying back after unwhitelist');
        assertEq(staking.stakedBalanceOf(alice), 0, 'Alice fully unstaked');

        // Phase 6: Cleanup now possible
        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));
    }

    /// @notice CRITICAL: Test users staked while unwhitelisted can claim underlying rewards
    function test_UnwhitelistedToken_NewStakersCanClaimUnderlyingRewards() public {
        // Phase 1: Whitelist and use token X
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        address[] memory tokensX = new address[](1);
        tokensX[0] = address(rewardTokenX);
        staking.claimRewards(tokensX, alice);

        // Phase 2: Unwhitelist token X
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));

        // Phase 3: Bob stakes WHILE token X is not whitelisted
        vm.prank(bob);
        staking.stake(1000e18);

        // Phase 4: Distribute UNDERLYING token rewards (always whitelisted)
        underlying.mint(address(staking), 200e18);
        staking.accrueRewards(address(underlying));
        vm.warp(block.timestamp + 1 days);

        // Phase 5: Both users can claim underlying rewards
        address[] memory underlyingTokens = new address[](1);
        underlyingTokens[0] = address(underlying);

        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(underlyingTokens, alice);
        uint256 aliceUnderlyingClaimed = underlying.balanceOf(alice) - aliceUnderlyingBefore;

        uint256 bobUnderlyingBefore = underlying.balanceOf(bob);
        vm.prank(bob);
        staking.claimRewards(underlyingTokens, bob);
        uint256 bobUnderlyingClaimed = underlying.balanceOf(bob) - bobUnderlyingBefore;

        // Both should get approximately equal shares
        assertApproxEqRel(aliceUnderlyingClaimed, 100e18, 0.01e18, 'Alice claims underlying');
        assertApproxEqRel(bobUnderlyingClaimed, 100e18, 0.01e18, 'Bob claims underlying');

        // Phase 6: Both can unstake normally
        vm.prank(alice);
        staking.unstake(1000e18, alice);

        vm.prank(bob);
        staking.unstake(1000e18, bob);

        assertEq(staking.totalStaked(), 0, 'All users unstaked successfully');
    }

    /// @notice Test unstake also handles stale debt correctly
    function test_Unstake_HandlesStaleDebt() public {
        // Phase 1: Setup with rewards
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        vm.prank(alice);
        staking.stake(1000e18);

        rewardTokenX.mint(address(staking), 1000e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenX);
        staking.claimRewards(tokens, alice);

        // Phase 2: Remove and re-add
        vm.prank(tokenAdmin);
        staking.unwhitelistToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.cleanupFinishedRewardToken(address(rewardTokenX));

        vm.prank(tokenAdmin);
        staking.whitelistToken(address(rewardTokenX));

        // Phase 3: First batch of rewards after re-whitelist
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Phase 4: First claim after re-whitelist (Alice gets fair share with fixed stale debt)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 aliceBalanceAfterFirstClaim = rewardTokenX.balanceOf(alice);
        assertApproxEqRel(
            aliceBalanceAfterFirstClaim,
            1100e18,
            0.02e18,
            'Alice gets 100 new rewards (debt reset to 0, not accReward)'
        );

        // Phase 5: Second batch of rewards (Alice continues earning normally)
        rewardTokenX.mint(address(staking), 100e18);
        staking.accrueRewards(address(rewardTokenX));
        vm.warp(block.timestamp + 1 days);

        // Phase 6: Unstake (triggers _claimAllRewards, Alice should get second batch too)
        uint256 balanceBefore = rewardTokenX.balanceOf(alice);

        vm.prank(alice);
        staking.unstake(1000e18, alice);

        uint256 balanceAfter = rewardTokenX.balanceOf(alice);
        uint256 claimed = balanceAfter - balanceBefore;

        // Alice should get her share from second batch
        assertGt(claimed, 0, 'Alice should claim rewards on unstake');
        assertApproxEqRel(claimed, 100e18, 0.02e18, 'Alice should get ~100 from second batch');
    }
}
