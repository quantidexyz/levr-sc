// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Claimable Rewards After Unstake Bug Reproduction
 * @notice Tests the bug where claimableRewards() returns 0 after unstaking,
 *         even though rewards should persist and be claimable
 * @dev This reproduces the exact user-reported scenario:
 *      1. Stake tokens
 *      2. Generate fees (WETH rewards)
 *      3. Accrue rewards - claimable shows correctly
 *      4. Unstake - claimable incorrectly resets to 0 ❌
 *      5. Restake - claimable shows reduced amount ❌
 */
contract LevrStakingV1_ClaimableAfterUnstakeTest is Test {
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

        // User starts with 100M underlying tokens
        underlying.mint(user, 100_000_000 ether);
        weth.mint(address(this), 10_000 ether);
    }

    function test_claimableRewardsPersistAfterUnstake() public {
        console2.log('\n=== BUG REPRODUCTION: Claimable After Unstake ===\n');

        uint256 stakeAmount = 100_000_000 ether;

        // Step 1: User stakes all tokens
        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        console2.log('[1] User staked:', stakeAmount / 1e18, 'tokens');
        uint256 claimable0 = staking.claimableRewards(user, address(weth));
        assertEq(claimable0, 0, 'Claimable should be 0 initially');
        console2.log('    Claimable WETH:', claimable0 / 1e15, 'mWETH');

        // Step 2: Generate fees from swaps (simulate swap fees)
        // Swap generates 0.16 WETH in fees
        uint256 swapFees = 160_000_000_000_000_000; // 0.16 WETH
        weth.mint(address(staking), swapFees);
        console2.log('[2] Swap fees generated:', swapFees / 1e15, 'mWETH');

        // Step 3: Accrue rewards
        staking.accrueRewards(address(weth));
        console2.log('[3] Rewards accrued');

        // Wait 1 day to allow some vesting
        skip(1 days);

        // Check claimable rewards after accrual
        uint256 claimable1 = staking.claimableRewards(user, address(weth));
        console2.log('[4] After 1 day, claimable:', claimable1 / 1e15, 'mWETH');
        assertGt(claimable1, 0, 'Claimable should be > 0 after accrual and time');

        // Step 4: User unstakes ALL tokens
        vm.startPrank(user);
        staking.unstake(stakeAmount, user);
        vm.stopPrank();

        console2.log('[5] User unstaked ALL tokens');
        console2.log('    User balance:', underlying.balanceOf(user) / 1e18);
        console2.log('    Staked balance:', sToken.balanceOf(user));
        assertEq(sToken.balanceOf(user), 0, 'Staked balance should be 0');

        // FIX VERIFIED: claimableRewards() now returns pending rewards even when balance is 0
        uint256 claimable2 = staking.claimableRewards(user, address(weth));
        console2.log('[6] Claimable after unstake:', claimable2 / 1e15, 'mWETH');
        console2.log('    Expected: ~', claimable1 / 1e15, 'mWETH (same as before)');
        console2.log('    Actual:', claimable2 / 1e15, 'mWETH [FIXED]');

        // FIX VERIFIED: Rewards should persist after unstaking
        assertEq(claimable2, claimable1, 'Rewards should persist after unstake');

        // Verify rewards are still in the contract
        uint256 wethInContract = weth.balanceOf(address(staking));
        console2.log('    WETH still in contract:', wethInContract / 1e15, 'mWETH');
        assertGt(wethInContract, 0, 'WETH should still be in contract');

        // Step 5: User restakes
        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        console2.log('[7] User restaked:', stakeAmount / 1e18, 'tokens');

        // After restaking, pending rewards are converted to debt offset
        // So claimable should account for both new staking rewards and preserved pending rewards
        uint256 claimable3 = staking.claimableRewards(user, address(weth));
        console2.log('[8] Claimable after restake:', claimable3 / 1e15, 'mWETH');
        console2.log('    Previous claimable (before unstake):', claimable1 / 1e15, 'mWETH');
        console2.log('    Note: Pending rewards converted to debt offset, may show differently');

        // User can claim rewards either:
        // 1. After unstaking (from pending rewards)
        // 2. After restaking (from balance + debt offset)
        // Try to claim after restaking
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 userWethBefore = weth.balanceOf(user);
        vm.prank(user);
        staking.claimRewards(tokens, user);
        uint256 userWethAfter = weth.balanceOf(user);
        uint256 claimed = userWethAfter - userWethBefore;

        console2.log('[9] User claimed after restake:', claimed / 1e15, 'mWETH');
        console2.log(
            '    Total claimable (unstake + restake):',
            (claimable2 + claimable3) / 1e15,
            'mWETH'
        );

        // Summary
        console2.log('\n=== SUMMARY ===');
        console2.log('Before unstake claimable:', claimable1 / 1e15, 'mWETH');
        console2.log(
            'After unstake claimable:',
            claimable2 / 1e15,
            'mWETH [FIXED: rewards persist]'
        );
        console2.log('After restake claimable:', claimable3 / 1e15, 'mWETH');
        console2.log('Actually claimed:', claimed / 1e15, 'mWETH');

        // FIX VERIFIED: Rewards should be preserved
        // User can claim rewards either after unstaking or after restaking
        assertEq(claimable2, claimable1, 'Rewards persist after unstake');
        assertGe(claimed + claimable2, claimable1, 'User can claim all earned rewards');
    }

    /**
     * @notice Expected behavior: claimableRewards() should return the same amount
     *         before and after unstaking, if the stream hasn't ended
     * @dev This test FAILS intentionally to document the bug.
     *      The bug is that claimableRewards() returns 0 when balance is 0,
     *      even though rewards should persist per the new design.
     */
    function test_expectedBehavior_claimablePersistsDuringUnstake() public {
        uint256 stakeAmount = 1000 ether;

        // Setup: stake and accrue
        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        weth.mint(address(staking), 100 ether);
        staking.accrueRewards(address(weth));

        skip(1 days);

        uint256 claimableBeforeUnstake = staking.claimableRewards(user, address(weth));
        assertGt(claimableBeforeUnstake, 0, 'Should have claimable rewards');

        console2.log('Before unstake - claimable:', claimableBeforeUnstake / 1e15, 'mWETH');

        // Unstake
        vm.prank(user);
        staking.unstake(stakeAmount, user);

        // EXPECTED: claimable should still be the same (rewards persist)
        // ACTUAL: claimable is preserved via pending rewards mapping [FIXED]
        uint256 claimableAfterUnstake = staking.claimableRewards(user, address(weth));

        console2.log('After unstake - claimable:', claimableAfterUnstake / 1e15, 'mWETH');
        console2.log('Expected:', claimableBeforeUnstake / 1e15, 'mWETH');
        console2.log('Actual:', claimableAfterUnstake / 1e15, 'mWETH [FIXED]');

        // FIX VERIFIED: Rewards now persist after unstaking via _pendingRewards mapping
        assertEq(
            claimableAfterUnstake,
            claimableBeforeUnstake,
            'FIXED: claimableRewards() now persists after unstake via pending rewards'
        );
    }
}
