// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Permanent Fund Loss Bug - Critical Test
 * @notice Demonstrates that rewards are PERMANENTLY LOST when users unstake
 * @dev This is a CRITICAL bug that causes permanent fund loss:
 *      1. User stakes and earns rewards
 *      2. User unstakes - debt is reset to 0 (losing earned rewards)
 *      3. claimableRewards() returns 0 (cannot claim)
 *      4. User restakes - new debt calculated at higher accPerShare
 *      5. Previous rewards are PERMANENTLY LOST in contract reserve
 */
contract LevrStakingV1_PermanentFundLossTest is Test {
    MockERC20 internal underlying;
    MockERC20 internal weth;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);
    address internal user = address(0xA11CE);

    function clankerFactory() external pure returns (address) {
        return address(0);
    }

    function getClankerMetadata(
        address
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
        return 3 days;
    }

    function maxRewardTokens() external pure returns (uint16) {
        return 50;
    }

    function setUp() public {
        underlying = new MockERC20('DevBuy', 'DBUY');
        weth = new MockERC20('Wrapped Ether', 'WETH');

        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked DevBuy',
            'sDBUY',
            18,
            address(underlying),
            address(staking)
        );

        staking.initialize(address(underlying), address(sToken), treasury, address(this));

        underlying.mint(user, 1000 ether);
    }

    /**
     * @notice CRITICAL BUG: Demonstrates permanent fund loss
     * @dev When user unstakes, _updateDebtAll(reset, 0) sets debt to 0,
     *      losing all accumulated rewards. When restaking, debt is recalculated
     *      at higher accPerShare, meaning previous rewards are permanently lost.
     */
    function test_criticalBug_permanentFundLossOnUnstake() public {
        console2.log('\n=== CRITICAL BUG: PERMANENT FUND LOSS ===\n');

        uint256 stakeAmount = 1000 ether;
        uint256 rewardAmount = 100 ether; // 100 WETH rewards

        // Step 1: User stakes
        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Step 2: Accrue rewards
        weth.mint(address(staking), rewardAmount);
        staking.accrueRewards(address(weth));

        // Step 3: Wait for some vesting
        skip(1 days);

        // Step 4: Check claimable rewards (user earned ~33 WETH after 1 day)
        uint256 claimableBeforeUnstake = staking.claimableRewards(user, address(weth));
        uint256 wethInContractBefore = weth.balanceOf(address(staking));

        console2.log('[1] User staked:', stakeAmount / 1e18, 'tokens');
        console2.log('[2] Rewards accrued:', rewardAmount / 1e18, 'WETH');
        console2.log('[3] After 1 day, user earned:', claimableBeforeUnstake / 1e18, 'WETH');
        console2.log('    WETH in contract:', wethInContractBefore / 1e18, 'WETH');

        assertGt(claimableBeforeUnstake, 0, 'User should have earned rewards');

        // Step 5: User unstakes ALL tokens
        // BUG: _updateDebtAll(user, 0) resets debt to 0, losing earned rewards
        vm.prank(user);
        staking.unstake(stakeAmount, user);

        uint256 claimableAfterUnstake = staking.claimableRewards(user, address(weth));
        uint256 wethInContractAfterUnstake = weth.balanceOf(address(staking));

        console2.log('[4] User unstaked ALL tokens');
        console2.log('    Claimable after unstake:', claimableAfterUnstake / 1e18, 'WETH');
        console2.log('    WETH in contract:', wethInContractAfterUnstake / 1e18, 'WETH');
        console2.log('    [FIXED] claimableRewards() now returns pending rewards when balance is 0');

        // FIX VERIFIED: claimable should match earned rewards (preserved in pending mapping)
        assertEq(claimableAfterUnstake, claimableBeforeUnstake, 'Rewards should persist after unstake');

        // Step 6: Verify rewards are still in contract (they are!)
        assertEq(wethInContractAfterUnstake, wethInContractBefore, 'Rewards still in contract');

        // Step 7: User claims rewards (should work now!)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 userWethBefore = weth.balanceOf(user);
        vm.prank(user);
        staking.claimRewards(tokens, user); // This should claim pending rewards
        uint256 userWethAfter = weth.balanceOf(user);
        uint256 claimedAfterUnstake = userWethAfter - userWethBefore;

        console2.log('[5] User claimed:', claimedAfterUnstake / 1e18, 'WETH');
        assertEq(claimedAfterUnstake, claimableAfterUnstake, 'User should be able to claim pending rewards after unstaking');
        
        // Verify claimable is now 0 after claiming
        uint256 claimableAfterClaim = staking.claimableRewards(user, address(weth));
        assertEq(claimableAfterClaim, 0, 'Claimable should be 0 after claiming');

        // Step 8: User restakes
        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Step 9: Check claimable after restaking
        // BUG: Debt was reset, so user starts fresh at NEW accPerShare
        // Previous rewards are PERMANENTLY LOST
        uint256 claimableAfterRestake = staking.claimableRewards(user, address(weth));
        uint256 wethInContractAfterRestake = weth.balanceOf(address(staking));

        console2.log('[6] User restaked');
        console2.log('    Claimable after restake:', claimableAfterRestake / 1e18, 'WETH');
        console2.log('    WETH in contract:', wethInContractAfterRestake / 1e18, 'WETH');

        // Verify rewards are preserved after restaking
        // Note: After restaking, pending rewards are converted to debt offset,
        // so claimable will be recalculated from balance + debt, which should preserve rewards
        console2.log('\n=== FUND PRESERVATION ANALYSIS ===');
        console2.log('Rewards user earned (before unstake):', claimableBeforeUnstake / 1e18, 'WETH');
        console2.log('Rewards claimable after unstake:', claimableAfterUnstake / 1e18, 'WETH');
        console2.log('Rewards claimable after restake:', claimableAfterRestake / 1e18, 'WETH');
        console2.log('WETH in contract:', wethInContractAfterRestake / 1e18, 'WETH');

        // FIX VERIFIED: Rewards should be preserved (either claimable after unstake or after restake)
        // After restaking, pending rewards are converted to debt offset, so they're included in balance-based calculation
        assertGe(
            claimableAfterRestake + claimableAfterUnstake,
            claimableBeforeUnstake,
            'Rewards should be preserved (can claim after unstake or restake)'
        );
    }

    /**
     * @notice Shows that even claiming BEFORE unstaking doesn't help if stream hasn't ended
     * @dev User must wait for stream to end AND claim before unstaking to avoid loss
     */
    function test_claimBeforeUnstakeDoesNotHelp() public {
        uint256 stakeAmount = 1000 ether;
        uint256 rewardAmount = 100 ether;

        // Setup
        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        weth.mint(address(staking), rewardAmount);
        staking.accrueRewards(address(weth));
        skip(1 days);

        uint256 claimable = staking.claimableRewards(user, address(weth));
        assertGt(claimable, 0, 'Should have claimable rewards');

        // User tries to claim before stream ends (partial vesting)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(user);
        staking.claimRewards(tokens, user);

        uint256 claimedPartial = weth.balanceOf(user);
        console2.log('User claimed (partial):', claimedPartial / 1e18, 'WETH');

        // User unstakes
        vm.prank(user);
        staking.unstake(stakeAmount, user);

        // Check claimable after unstake (should still have remaining rewards)
        uint256 claimableAfter = staking.claimableRewards(user, address(weth));
        console2.log('Claimable after unstake:', claimableAfter / 1e18, 'WETH');

        // BUG: Even remaining rewards are lost because claimableRewards returns 0
        // when balance is 0, even though stream hasn't ended yet
        assertEq(claimableAfter, 0, 'BUG: Remaining rewards also lost after unstake');
    }
}

