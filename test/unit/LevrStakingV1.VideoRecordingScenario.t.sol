// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Video Recording Scenario - Exact Reproduction
 * @notice Following the EXACT steps from the video recording
 */
contract LevrStakingV1_VideoRecordingScenario_UnitTest is Test {
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
        underlying = new MockERC20('TestToken', 'TT');
        weth = new MockERC20('Wrapped Ether', 'WETH');

        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked TestToken',
            'sTT',
            18,
            address(underlying),
            address(staking)
        );

        staking.initialize(address(underlying), address(sToken), treasury, address(this));

        underlying.mint(user, 100_000_000_000 ether);
        weth.mint(address(this), 10_000 ether);
        weth.mint(user, 10_000 ether); // User has WETH to send manually
    }

    function test_ExactVideoRecordingScenario() public {
        console2.log('\n=== VIDEO RECORDING SCENARIO ===\n');

        uint256 stakeAmount = 10_000_000 ether;

        // Step 1-2: Swap generates fees (not staked), then stake
        uint256 fees1 = 40_000_000_000_000_000; // 0.04 WETH
        weth.mint(address(staking), fees1);

        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        console2.log('[1-2] Swapped, then staked');
        console2.log('      Outstanding:', fees1 / 1e15, 'mWETH');

        // Step 3: Accrue
        staking.accrueRewards(address(weth));
        console2.log('[3] Accrued');

        // Step 4: Swap more
        uint256 fees2 = 80_000_000_000_000_000; // More fees
        weth.mint(address(staking), fees2);
        console2.log('[4] More swap fees generated');

        // Step 5: Warp 1 day
        skip(1 days);
        console2.log('[5] Warped 1 day');

        // Step 6: Claim
        uint256 claimable1 = staking.claimableRewards(user, address(weth));
        console2.log('[6] Claimable:', claimable1 / 1e15, 'mWETH');

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(user);
        staking.claimRewards(tokens, user);
        uint256 userWeth = weth.balanceOf(user);
        console2.log('    Claimed, user now has:', userWeth / 1e15, 'mWETH');

        // Step 7: Manually send WETH (0.12 WETH)
        uint256 manualSend = 120_000_000_000_000_000;
        vm.prank(user);
        weth.transfer(address(staking), manualSend);
        console2.log('[7] Manually sent', manualSend / 1e15, 'mWETH to staking');

        (uint256 outstanding1, ) = staking.outstandingRewards(address(weth));
        console2.log('    Outstanding now:', outstanding1 / 1e15, 'mWETH');

        // Step 8: Check available before accrue
        uint256 wethBefore = weth.balanceOf(address(staking));
        console2.log('[8] Before accrue - WETH in contract:', wethBefore / 1e15, 'mWETH');

        // Accrue
        staking.accrueRewards(address(weth));
        uint256 wethAfter = weth.balanceOf(address(staking));
        console2.log('    After accrue - WETH in contract:', wethAfter / 1e15, 'mWETH');

        uint256 claimable2 = staking.claimableRewards(user, address(weth));
        console2.log('    Claimable:', claimable2 / 1e15, 'mWETH');

        // Step 9: Unstake ALL
        vm.prank(user);
        staking.unstake(stakeAmount, user);
        console2.log('[9] Unstaked ALL');

        uint256 wethRemaining = weth.balanceOf(address(staking));
        console2.log('    WETH remaining:', wethRemaining / 1e15, 'mWETH');
        console2.log('    Total staked:', staking.totalStaked());

        // Step 10: Warp 3 days
        uint64 streamEnd = staking.streamEnd();
        skip((streamEnd - block.timestamp) + 1);
        console2.log('[10] Warped 3 days - stream CLOSED');

        (uint256 available2, ) = staking.outstandingRewards(address(weth));
        console2.log('     Available:', available2 / 1e15, 'mWETH');

        // Step 11: Stake all again
        console2.log('[11] About to stake again...');
        console2.log('     Current totalStaked:', staking.totalStaked());
        console2.log('     WETH in contract:', weth.balanceOf(address(staking)) / 1e15, 'mWETH');

        vm.startPrank(user);
        underlying.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        console2.log('     Staked! New totalStaked:', staking.totalStaked() / 1e18);
        console2.log(
            '     WETH still in contract:',
            weth.balanceOf(address(staking)) / 1e15,
            'mWETH'
        );

        // Step 12: Check claimable
        uint256 claimable3 = staking.claimableRewards(user, address(weth));
        (uint256 available3, ) = staking.outstandingRewards(address(weth));

        console2.log('\n=== AFTER RESTAKING ===');
        console2.log('Claimable:', claimable3 / 1e15, 'mWETH');
        console2.log('Available:', available3 / 1e15, 'mWETH');

        if (claimable3 > 0 && claimable3 == wethRemaining) {
            console2.log('\n!!! BUG: User can claim ALL unvested rewards!');
            console2.log('They were NOT staked during unvesting period');
        }

        // Step 13: Try to claim
        console2.log('\n[13] Trying to claim...');
        uint256 userBalBefore = weth.balanceOf(user);

        vm.prank(user);
        try staking.claimRewards(tokens, user) {
            uint256 actualClaimed = weth.balanceOf(user) - userBalBefore;
            console2.log('     [SUCCESS] Claimed:', actualClaimed / 1e15, 'mWETH');

            if (actualClaimed > 0) {
                console2.log('\n     !!! BUG CONFIRMED !!!');
                console2.log('     User received unvested rewards they should not have!');
            }
        } catch Error(string memory reason) {
            console2.log('     [REVERT]', reason);
        }

        // Step 14: Try to unstake
        console2.log('\n[14] Trying to unstake...');
        vm.startPrank(user);
        try staking.unstake(stakeAmount / 2, user) {
            console2.log('     [SUCCESS] Unstake worked');
        } catch Error(string memory reason) {
            console2.log('     [REVERT]', reason);
        }
        vm.stopPrank();
    }
}
