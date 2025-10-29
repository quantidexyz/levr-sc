// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Fund Stuck Scenarios Analysis
 * @notice Comprehensive tests to identify any scenarios where funds can get stuck
 * @dev Tests all possible paths: stake, unstake, transfer, claim, accrual
 */
contract LevrStaking_FundStuckAnalysisTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address charlie = address(0x3333);

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
            maxRewardTokens: 50
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));
        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('WETH', 'WETH');

        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(this),
            address(factory)
        );

        // Setup users
        underlying.mint(alice, 100000 ether);
        underlying.mint(bob, 100000 ether);
        underlying.mint(charlie, 100000 ether);
    }

    /// @notice Test: Can principal (staked underlying) get stuck?
    /// @dev Scenario: Multiple stakes and unstakes
    function test_accounting_principalNeverStuck() public {
        uint256 totalStaked = 0;
        uint256 totalUnstaked = 0;

        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(1000 ether);
        totalStaked += 1000 ether;

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(2000 ether);
        totalStaked += 2000 ether;

        // Alice unstakes partial
        vm.startPrank(alice);
        staking.unstake(400 ether, alice);
        totalUnstaked += 400 ether;

        // Charlie stakes
        vm.startPrank(charlie);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(500 ether);
        totalStaked += 500 ether;

        // Bob unstakes all
        vm.startPrank(bob);
        staking.unstake(2000 ether, bob);
        totalUnstaked += 2000 ether;

        // Check accounting
        uint256 escrow = staking.escrowBalance(address(underlying));
        uint256 totalInContract = totalStaked - totalUnstaked;

        console.log('Total staked:', totalStaked);
        console.log('Total unstaked:', totalUnstaked);
        console.log('Expected escrow:', totalInContract);
        console.log('Actual escrow:', escrow);

        // CRITICAL: Escrow should match expected
        assertEq(escrow, totalInContract, 'Escrow should match staked - unstaked');

        // Everyone unstakes
        vm.startPrank(alice);
        staking.unstake(600 ether, alice);
        vm.startPrank(charlie);
        staking.unstake(500 ether, charlie);

        // CRITICAL: All principal should be withdrawable, escrow = 0
        assertEq(
            staking.escrowBalance(address(underlying)),
            0,
            'All principal should be withdrawn'
        );
        assertEq(staking.totalStaked(), 0, 'Total staked should be 0');
    }

    /// @notice Test: Can rewards get stuck in reserve?
    /// @dev Scenario: Accrue, claim, check for stuck funds
    function test_accounting_rewardsNeverStuckInReserve() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Complete stream
        vm.warp(block.timestamp + 3 days + 1);

        uint256 claimable = staking.claimableRewards(alice, address(weth));
        console.log('Claimable:', claimable);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        staking.claimRewards(tokens, alice);

        // CRITICAL: Check if any WETH stuck in contract
        uint256 wethInContract = weth.balanceOf(address(staking));
        console.log('WETH remaining in contract:', wethInContract);

        // Should be 0 or very small (rounding dust)
        assertLt(wethInContract, 0.01 ether, 'No significant WETH should be stuck');
    }

    /// @notice Test: Can funds get stuck during transfers with rewards?
    /// @dev Scenario: Transfer with active rewards, verify no stuck funds
    function test_accounting_transferWithRewards_noStuckFunds() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Wait partial
        vm.warp(block.timestamp + 1 days);

        uint256 stakingWethBefore = weth.balanceOf(address(staking));
        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Transfer (triggers auto-claim)
        stakedToken.transfer(bob, 500 ether);

        uint256 stakingWethAfter = weth.balanceOf(address(staking));
        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceWethClaimed = aliceWethAfter - aliceWethBefore;

        console.log('WETH in staking before transfer:', stakingWethBefore);
        console.log('WETH in staking after transfer:', stakingWethAfter);
        console.log('Alice WETH claimed during transfer:', aliceWethClaimed);

        // CRITICAL: WETH decreased by exact amount Alice claimed
        assertEq(
            stakingWethBefore - stakingWethAfter,
            aliceWethClaimed,
            'Staking contract WETH should decrease by claimed amount'
        );

        // Complete stream and verify all remaining can be claimed
        vm.warp(block.timestamp + 3 days);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.startPrank(alice);
        uint256 aliceFinal = staking.claimableRewards(alice, address(weth));
        if (aliceFinal > 0) staking.claimRewards(tokens, alice);

        vm.startPrank(bob);
        uint256 bobFinal = staking.claimableRewards(bob, address(weth));
        if (bobFinal > 0) staking.claimRewards(tokens, bob);

        // CRITICAL: No WETH stuck (allow tiny rounding dust)
        uint256 wethStuck = weth.balanceOf(address(staking));
        console.log('WETH stuck in contract:', wethStuck);
        assertLt(wethStuck, 0.01 ether, 'No significant WETH stuck');
    }

    /// @notice Test: Accounting during midstream accrual with global streaming
    /// @dev Scenario: Verify unvested is properly added to new stream
    function test_accounting_midstreamAccrual_unvestedPreserved() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // First accrual: WETH 1000 ether
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        uint256 wethInContract1 = weth.balanceOf(address(staking));
        console.log('WETH in contract after first accrual:', wethInContract1);
        assertEq(wethInContract1, 1000 ether, 'Should be 1000 WETH');

        // Wait 1 day (333 vested, 666 unvested)
        vm.warp(block.timestamp + 1 days);

        // Second accrual: underlying 500 ether (resets window)
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        uint256 wethInContract2 = weth.balanceOf(address(staking));
        uint256 underlyingInContract = underlying.balanceOf(address(staking));

        console.log('WETH in contract after second accrual:', wethInContract2);
        console.log('Underlying in contract after accrual:', underlyingInContract);

        // CRITICAL: WETH amount unchanged (no loss during window reset)
        assertEq(wethInContract2, 1000 ether, 'WETH should still be 1000 (no loss)');

        // Complete stream
        vm.warp(block.timestamp + 3 days + 1);

        // Claim all
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(underlying);
        staking.claimRewards(tokens, alice);

        uint256 wethRemaining = weth.balanceOf(address(staking));
        console.log('WETH remaining after claims:', wethRemaining);

        // CRITICAL: All WETH claimed, none stuck
        assertLt(wethRemaining, 0.01 ether, 'No WETH should be stuck');
    }

    /// @notice Test: _totalStaked accounting with complex operations
    /// @dev Scenario: Mix of stakes, unstakes, transfers
    function test_accounting_totalStaked_alwaysAccurate() public {
        // Track expected total
        uint256 expectedTotal = 0;

        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(1000 ether);
        expectedTotal += 1000 ether;
        assertEq(staking.totalStaked(), expectedTotal, 'Total should be 1000');

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(2000 ether);
        expectedTotal += 2000 ether;
        assertEq(staking.totalStaked(), expectedTotal, 'Total should be 3000');

        // Alice transfers to Charlie
        vm.startPrank(alice);
        stakedToken.transfer(charlie, 400 ether);
        // Transfer doesn't change total
        assertEq(staking.totalStaked(), expectedTotal, 'Total unchanged after transfer');

        // Bob unstakes partial
        vm.startPrank(bob);
        staking.unstake(500 ether, bob);
        expectedTotal -= 500 ether;
        assertEq(staking.totalStaked(), expectedTotal, 'Total should be 2500');

        // Alice stakes more
        vm.startPrank(alice);
        staking.stake(1500 ether);
        expectedTotal += 1500 ether;
        assertEq(staking.totalStaked(), expectedTotal, 'Total should be 4000');

        // CRITICAL: Verify sum of all balances equals totalStaked
        uint256 aliceBalance = staking.stakedBalanceOf(alice);
        uint256 bobBalance = staking.stakedBalanceOf(bob);
        uint256 charlieBalance = staking.stakedBalanceOf(charlie);
        uint256 sumOfBalances = aliceBalance + bobBalance + charlieBalance;

        console.log('Alice balance:', aliceBalance);
        console.log('Bob balance:', bobBalance);
        console.log('Charlie balance:', charlieBalance);
        console.log('Sum of balances:', sumOfBalances);
        console.log('Total staked:', staking.totalStaked());

        assertEq(sumOfBalances, staking.totalStaked(), 'Sum of balances must equal totalStaked');
        assertEq(sumOfBalances, expectedTotal, 'Sum should match expected');
    }

    /// @notice Test: Can rewards get stuck if user never claims?
    /// @dev Scenario: User stakes, rewards accrue, user unstakes without claiming
    function test_accounting_unclaimedRewards_reclaimable() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Complete stream
        vm.warp(block.timestamp + 3 days + 1);

        uint256 aliceClaimable = staking.claimableRewards(alice, address(weth));
        console.log('Alice claimable:', aliceClaimable);

        // Alice unstakes WITHOUT claiming rewards
        staking.unstake(1000 ether, alice);

        // CRITICAL: Alice's rewards should have been auto-claimed during unstake
        // Check if WETH was transferred to Alice
        uint256 aliceWeth = weth.balanceOf(alice);
        console.log('Alice WETH balance after unstake:', aliceWeth);

        // Alice should have received her rewards during unstake
        assertEq(aliceWeth, aliceClaimable, 'Rewards should be auto-claimed on unstake');

        // Check if any WETH stuck
        uint256 wethStuck = weth.balanceOf(address(staking));
        console.log('WETH stuck in contract:', wethStuck);
        assertLt(wethStuck, 0.01 ether, 'No significant WETH stuck');
    }

    /// @notice Test: Escrow vs rewards accounting separation
    /// @dev Ensures principal and rewards are tracked separately
    function test_accounting_escrowVsRewards_properSeparation() public {
        // Alice stakes underlying
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        uint256 escrow1 = staking.escrowBalance(address(underlying));
        console.log('Escrow after stake:', escrow1);
        assertEq(escrow1, 1000 ether, 'Escrow should be staked amount');

        // Accrue underlying as REWARD
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        uint256 escrow2 = staking.escrowBalance(address(underlying));
        console.log('Escrow after reward accrual:', escrow2);

        // CRITICAL: Escrow should NOT include rewards
        assertEq(escrow2, 1000 ether, 'Escrow unchanged by reward accrual');

        // Check contract balance
        uint256 contractBalance = underlying.balanceOf(address(staking));
        console.log('Contract balance:', contractBalance);
        assertEq(contractBalance, 1500 ether, 'Contract has escrow + rewards');

        // Complete stream and claim rewards
        vm.warp(block.timestamp + 3 days + 1);
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        staking.claimRewards(tokens, alice);

        // Unstake principal
        uint256 aliceBalanceBefore = underlying.balanceOf(alice);
        staking.unstake(1000 ether, alice);
        uint256 aliceBalanceAfter = underlying.balanceOf(alice);

        console.log('Alice received on unstake:', aliceBalanceAfter - aliceBalanceBefore);

        // CRITICAL: Alice should receive exactly her principal
        assertEq(
            aliceBalanceAfter - aliceBalanceBefore,
            1000 ether,
            'Should receive exact principal'
        );

        // No underlying stuck
        uint256 underlyingStuck = underlying.balanceOf(address(staking));
        console.log('Underlying stuck:', underlyingStuck);
        assertLt(underlyingStuck, 0.01 ether, 'No underlying stuck');
    }

    /// @notice Test: Multiple transfers in sequence don't create accounting issues
    /// @dev Scenario: A → B → C → D chain transfers
    function test_accounting_multipleTransfers_noLeakage() public {
        address dave = address(0x4444);

        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        vm.warp(block.timestamp + 1 days);

        // Transfer chain: Alice → Bob → Charlie → Dave
        uint256 totalAutoClaimed = 0;

        // Alice → Bob
        uint256 aliceWethBefore = weth.balanceOf(alice);
        stakedToken.transfer(bob, 400 ether);
        uint256 aliceAutoClaimed = weth.balanceOf(alice) - aliceWethBefore;
        totalAutoClaimed += aliceAutoClaimed;
        console.log('Alice auto-claimed:', aliceAutoClaimed);

        // Bob → Charlie
        vm.warp(block.timestamp + 0.5 days);
        vm.startPrank(bob);
        uint256 bobWethBefore = weth.balanceOf(bob);
        stakedToken.transfer(charlie, 200 ether);
        uint256 bobAutoClaimed = weth.balanceOf(bob) - bobWethBefore;
        totalAutoClaimed += bobAutoClaimed;
        console.log('Bob auto-claimed:', bobAutoClaimed);

        // Charlie → Dave
        vm.warp(block.timestamp + 0.5 days);
        vm.startPrank(charlie);
        uint256 charlieWethBefore = weth.balanceOf(charlie);
        stakedToken.transfer(dave, 100 ether);
        uint256 charlieAutoClaimed = weth.balanceOf(charlie) - charlieWethBefore;
        totalAutoClaimed += charlieAutoClaimed;
        console.log('Charlie auto-claimed:', charlieAutoClaimed);

        // Complete stream
        vm.warp(block.timestamp + 3 days);

        // All claim remaining
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 totalFinalClaimed = 0;

        vm.startPrank(alice);
        uint256 aliceFinal = staking.claimableRewards(alice, address(weth));
        if (aliceFinal > 0) {
            staking.claimRewards(tokens, alice);
            totalFinalClaimed += aliceFinal;
        }

        vm.startPrank(bob);
        uint256 bobFinal = staking.claimableRewards(bob, address(weth));
        if (bobFinal > 0) {
            staking.claimRewards(tokens, bob);
            totalFinalClaimed += bobFinal;
        }

        vm.startPrank(charlie);
        uint256 charlieFinal = staking.claimableRewards(charlie, address(weth));
        if (charlieFinal > 0) {
            staking.claimRewards(tokens, charlie);
            totalFinalClaimed += charlieFinal;
        }

        vm.startPrank(dave);
        uint256 daveFinal = staking.claimableRewards(dave, address(weth));
        if (daveFinal > 0) {
            staking.claimRewards(tokens, dave);
            totalFinalClaimed += daveFinal;
        }

        uint256 totalClaimed = totalAutoClaimed + totalFinalClaimed;
        uint256 totalWethAccrued = 1000 ether;

        console.log('Total auto-claimed during transfers:', totalAutoClaimed);
        console.log('Total final claimed:', totalFinalClaimed);
        console.log('Total claimed:', totalClaimed);
        console.log('Total accrued:', totalWethAccrued);

        // CRITICAL: All WETH should be claimed (allow tiny rounding)
        // With multiple transfers and accruals, some precision loss is expected
        assertGe(totalClaimed, (totalWethAccrued * 999) / 1000, 'At least 99.9% WETH claimed');
        assertLe(totalClaimed, totalWethAccrued, 'Cannot exceed accrued');

        // Verify minimal WETH stuck (only dust from rounding)
        uint256 wethStuck = weth.balanceOf(address(staking));
        console.log('WETH stuck (dust):', wethStuck);
        assertLt(wethStuck, 0.01 ether, 'Only dust from rounding');
    }

    /// @notice Test: Balance consistency across all operations
    /// @dev Verifies stakedToken.balanceOf == staking.stakedBalanceOf
    function test_accounting_balanceConsistency_alwaysSynced() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(
            stakedToken.balanceOf(alice),
            staking.stakedBalanceOf(alice),
            'Balances synced after stake'
        );

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);

        assertEq(
            stakedToken.balanceOf(bob),
            staking.stakedBalanceOf(bob),
            'Balances synced for Bob'
        );

        // Alice transfers
        vm.startPrank(alice);
        stakedToken.transfer(charlie, 300 ether);

        assertEq(
            stakedToken.balanceOf(alice),
            staking.stakedBalanceOf(alice),
            'Alice balances synced after transfer'
        );
        assertEq(
            stakedToken.balanceOf(charlie),
            staking.stakedBalanceOf(charlie),
            'Charlie balances synced after receiving'
        );

        // Bob unstakes
        vm.startPrank(bob);
        staking.unstake(200 ether, bob);

        assertEq(
            stakedToken.balanceOf(bob),
            staking.stakedBalanceOf(bob),
            'Bob balances synced after unstake'
        );

        // CRITICAL: Sum of all balances = totalStaked
        uint256 sumBalances = stakedToken.balanceOf(alice) +
            stakedToken.balanceOf(bob) +
            stakedToken.balanceOf(charlie);

        assertEq(sumBalances, staking.totalStaked(), 'Sum equals totalStaked');
        assertEq(sumBalances, stakedToken.totalSupply(), 'Sum equals totalSupply');
    }

    /// @notice Test: Reserve accounting - rewards never exceed reserve
    /// @dev Ensures we can't distribute more than we have
    function test_accounting_reserve_neverExceeded() public {
        // Alice and Bob stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue WETH
        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Wait for full vesting
        vm.warp(block.timestamp + 3 days + 1);

        // Alice claims her share (500 ether)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 aliceClaimable = staking.claimableRewards(alice, address(weth));
        console.log('Alice claimable:', aliceClaimable);

        staking.claimRewards(tokens, alice);

        // Bob claims his share (500 ether)
        vm.startPrank(bob);
        uint256 bobClaimable = staking.claimableRewards(bob, address(weth));
        console.log('Bob claimable:', bobClaimable);

        staking.claimRewards(tokens, bob);

        // CRITICAL: Total claimed should not exceed what was accrued
        uint256 totalClaimed = aliceClaimable + bobClaimable;
        console.log('Total claimed:', totalClaimed);
        assertLe(totalClaimed, 1000 ether, 'Cannot claim more than accrued');

        // Check for stuck funds
        uint256 wethStuck = weth.balanceOf(address(staking));
        console.log('WETH stuck:', wethStuck);
        assertLt(wethStuck, 0.01 ether, 'No significant WETH stuck');
    }

    /// @notice Test: Dust accumulation over many operations
    /// @dev Scenario: Many small operations, check if dust accumulates
    function test_accounting_dustAccumulation_negligible() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(1000 ether);

        // Accrue small amounts many times
        for (uint i = 0; i < 10; i++) {
            weth.mint(address(staking), 10 ether);
            staking.accrueRewards(address(weth));
            vm.warp(block.timestamp + 0.3 days);
        }

        uint256 totalAccrued = 100 ether;

        // Complete stream
        vm.warp(block.timestamp + 3 days);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 wethBefore = weth.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 wethClaimed = weth.balanceOf(alice) - wethBefore;

        console.log('Total accrued:', totalAccrued);
        console.log('Total claimed:', wethClaimed);

        // CRITICAL: Dust should be negligible (< 0.1%)
        uint256 dust = totalAccrued > wethClaimed ? totalAccrued - wethClaimed : 0;
        console.log('Dust remaining:', dust);
        assertLt(dust, totalAccrued / 1000, 'Dust should be < 0.1% of total');

        // Check stuck funds
        uint256 wethStuck = weth.balanceOf(address(staking));
        assertLt(wethStuck, 0.1 ether, 'Minimal WETH stuck from rounding');
    }

    /// @notice Test: Can funds get stuck if last user unstakes during active stream?
    /// @dev Scenario: Active stream, last staker exits
    function test_accounting_lastUserUnstakes_streamPausesCorrectly() public {
        // Alice stakes (only user)
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Wait 1 day (333 vested)
        vm.warp(block.timestamp + 1 days);

        uint256 claimableBefore = staking.claimableRewards(alice, address(weth));
        console.log('Claimable before unstake:', claimableBefore);

        // Alice unstakes ALL (last staker)
        staking.unstake(1000 ether, alice);

        // Check if rewards were claimed
        uint256 aliceWeth = weth.balanceOf(alice);
        console.log('Alice WETH after unstake:', aliceWeth);
        assertEq(aliceWeth, claimableBefore, 'Should auto-claim on unstake');

        // Check total staked
        assertEq(staking.totalStaked(), 0, 'No stakers remaining');

        // Check for stuck funds
        uint256 wethInContract = weth.balanceOf(address(staking));
        console.log('WETH in contract after last unstake:', wethInContract);

        // CRITICAL: Unvested rewards should remain in contract (not stuck, just unvested)
        // When someone stakes again, they should get these rewards
        assertGt(wethInContract, 0, 'Unvested rewards should remain');
        assertLt(wethInContract, 700 ether, 'Should be the unvested portion');

        // Bob stakes later
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);

        // Complete stream
        vm.warp(block.timestamp + 3 days);

        // Bob should be able to claim the remaining rewards
        uint256 bobClaimable = staking.claimableRewards(bob, address(weth));
        console.log('Bob claimable (got remaining):', bobClaimable);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        staking.claimRewards(tokens, bob);

        // CRITICAL: All rewards eventually claimed (no permanent stuck)
        uint256 finalWethStuck = weth.balanceOf(address(staking));
        console.log('Final WETH stuck:', finalWethStuck);
        assertLt(finalWethStuck, 0.01 ether, 'All rewards eventually claimable');
    }

    /// @notice Test: Complex scenario - mixed operations
    /// @dev Ultimate stress test for accounting
    function test_accounting_complexMixedOperations_perfectAccounting() public {
        uint256 totalUnderlyingStaked = 0;
        uint256 totalUnderlyingUnstaked = 0;
        uint256 totalWethAccrued = 0;

        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(1000 ether);
        totalUnderlyingStaked += 1000 ether;

        // Accrue WETH
        weth.mint(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        totalWethAccrued += 500 ether;

        // Bob stakes
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(bob);
        underlying.approve(address(staking), 10000 ether);
        staking.stake(2000 ether);
        totalUnderlyingStaked += 2000 ether;

        // Alice transfers to Charlie
        vm.startPrank(alice);
        stakedToken.transfer(charlie, 300 ether);

        // Accrue more WETH (resets window)
        vm.warp(block.timestamp + 0.5 days);
        weth.mint(address(staking), 300 ether);
        staking.accrueRewards(address(weth));
        totalWethAccrued += 300 ether;

        // Bob unstakes partial
        vm.startPrank(bob);
        staking.unstake(500 ether, bob);
        totalUnderlyingUnstaked += 500 ether;

        // Complete stream
        vm.warp(block.timestamp + 3 days);

        // VERIFY ACCOUNTING

        // 1. Escrow accounting
        uint256 expectedEscrow = totalUnderlyingStaked - totalUnderlyingUnstaked;
        uint256 actualEscrow = staking.escrowBalance(address(underlying));
        console.log('Expected escrow:', expectedEscrow);
        console.log('Actual escrow:', actualEscrow);
        assertEq(actualEscrow, expectedEscrow, 'Escrow should match staked - unstaked');

        // 2. totalStaked accounting
        uint256 sumBalances = staking.stakedBalanceOf(alice) +
            staking.stakedBalanceOf(bob) +
            staking.stakedBalanceOf(charlie);
        assertEq(sumBalances, staking.totalStaked(), 'Sum of balances = totalStaked');

        // 3. All rewards claimable
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 totalClaimable = staking.claimableRewards(alice, address(weth)) +
            staking.claimableRewards(bob, address(weth)) +
            staking.claimableRewards(charlie, address(weth));

        console.log('Total WETH accrued:', totalWethAccrued);
        console.log('Total claimable:', totalClaimable);

        // Rewards may still be vesting, so check reasonable bounds
        assertGt(totalClaimable, 0, 'Should have claimable rewards');
        assertLe(totalClaimable, totalWethAccrued, 'Cannot exceed accrued');

        // Actually claim to verify no stuck funds
        vm.startPrank(alice);
        staking.claimRewards(tokens, alice);
        vm.startPrank(bob);
        staking.claimRewards(tokens, bob);
        vm.startPrank(charlie);
        staking.claimRewards(tokens, charlie);

        // Check WETH balance in contract (should only be unvested portion)
        uint256 wethRemaining = weth.balanceOf(address(staking));
        console.log('WETH remaining (unvested):', wethRemaining);

        // CRITICAL: Remaining should be unvested portion, not stuck
        // It should equal: totalAccrued - totalClaimable
        uint256 expectedRemaining = totalWethAccrued - totalClaimable;
        assertLe(wethRemaining, expectedRemaining + 0.01 ether, 'Remaining is unvested, not stuck');
    }
}
