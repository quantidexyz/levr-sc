// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactoryDeployHelper} from "../../utils/LevrFactoryDeployHelper.sol";
import {console} from 'forge-std/console.sol';

import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {MockFactory} from '../../mocks/MockFactory.sol';

/**
 * @title LevrStakingDilution Test
 * @notice POC for Sherlock audit finding: Flash loan attack via stake dilution
 * @dev Tests FAIL when vulnerability exists, PASS when fixed
 *
 * EXPECTED BEHAVIOR:
 * - Tests should FAIL now (vulnerability exists)
 * - Tests should PASS after fix (auto-claim on stake)
 *
 * Each test asserts the CORRECT behavior (what should happen).
 * When vulnerability exists, assertions fail because attack succeeds.
 */
contract LevrStakingDilutionTest is Test, LevrFactoryDeployHelper {
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockFactory factory;
    address treasury;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    uint256 constant INITIAL_SUPPLY = 1_000_000 * 1e18;
    uint256 constant STREAM_WINDOW = 7 days;

    function setUp() public {
        // Deploy underlying token
        underlying = new MockERC20('Test Token', 'TEST');

        // Deploy mock factory
        factory = new MockFactory();
        factory.setStreamWindowSeconds(address(underlying), uint32(STREAM_WINDOW));

        // Deploy staking contract first (needed for staked token)
        staking = createStaking(address(0), address(factory)); // no forwarder, factory address

        // Deploy staked token with all required parameters
        stakedToken = createStakedToken('Staked Test Token', 'sTEST', 18, address(underlying), address(staking));

        // Initialize staking (must be called by factory)
        treasury = address(0x999);
        address[] memory whitelisted = new address[](0);
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            treasury,
            whitelisted
        );

        // Mint tokens to test users
        underlying.mint(alice, INITIAL_SUPPLY);
        underlying.mint(bob, INITIAL_SUPPLY);
        underlying.mint(attacker, INITIAL_SUPPLY);

        // Label addresses for better trace output
        vm.label(alice, 'Alice');
        vm.label(bob, 'Bob');
        vm.label(attacker, 'Attacker');
        vm.label(address(staking), 'Staking');
        vm.label(address(underlying), 'Underlying');
    }

    /**
     * @notice TEST 1: Flash Loan Dilution Attack - Following Exact Scenario from Issue
     * @dev This test FAILS when vulnerability exists (current state)
     *      This test PASSES when vulnerability is fixed (after auto-claim implementation)
     *
     * SCENARIO FROM ISSUE:
     * 1. Initial State: Alice has 1,000 staked, 1,000 rewards accumulated
     * 2. Attacker Action: Bob flash loans 9,000 tokens
     * 3. Bob stakes 9,000 → total = 10,000
     * 4. Bob immediately unstakes and claims
     * 5. Expected: Alice should retain her 1,000 rewards (FAILS because she only gets 100)
     */
    function test_FlashLoanDilutionAttack_ShouldProtectAliceRewards() public {
        console.log('\n=== Sherlock Issue: Flash Loan Dilution Attack ===\n');

        // Scenario Setup (from issue)
        uint256 aliceInitialStake = 1_000 * 1e18;
        uint256 rewardAmount = 1_000 * 1e18;
        uint256 attackerFlashLoan = 9_000 * 1e18;

        // 1. Initial State: Alice has 1,000 tokens staked, Total staked: 1,000
        console.log('1. INITIAL STATE:');
        console.log('   Alice stakes 1,000 tokens (only staker)');
        vm.startPrank(alice);
        underlying.approve(address(staking), aliceInitialStake);
        staking.stake(aliceInitialStake);
        vm.stopPrank();

        console.log('   Total staked:', staking.totalStaked() / 1e18);

        // Accumulated pool: 1,000 rewards
        console.log('\n2. REWARD ACCUMULATION:');
        console.log('   Accumulate 1,000 reward tokens');
        underlying.mint(address(staking), rewardAmount);
        staking.accrueRewards(address(underlying));

        // Wait for rewards to vest
        vm.warp(block.timestamp + STREAM_WINDOW);

        uint256 aliceExpectedRewards = staking.claimableRewards(alice, address(underlying));
        console.log('   Alice claimable:', aliceExpectedRewards / 1e18);
        console.log('   Alice should own 100% of rewards (only staker)');

        // 2. Attacker Action (Single Transaction)
        console.log('\n3. ATTACKER ACTION (single transaction):');
        console.log('   Bob flash loans 9,000 tokens');

        vm.startPrank(attacker);

        // Bob stakes 9,000 → total = 10,000
        console.log('   Bob stakes 9,000 tokens');
        underlying.approve(address(staking), attackerFlashLoan);
        staking.stake(attackerFlashLoan);

        console.log('   Total staked now:', staking.totalStaked() / 1e18);

        // Bob immediately unstakes 9,000 and claims rewards
        console.log('   Bob immediately unstakes (triggers auto-claim)');
        uint256 bobBalanceBefore = underlying.balanceOf(attacker);
        staking.unstake(attackerFlashLoan, attacker);
        uint256 bobBalanceAfter = underlying.balanceOf(attacker);

        vm.stopPrank();

        // Calculate what Bob actually got
        uint256 bobRewardsClaimed = bobBalanceAfter - bobBalanceBefore - attackerFlashLoan;

        console.log('\n4. ATTACK RESULTS:');
        console.log('   Bob claimed rewards:', bobRewardsClaimed / 1e18);

        // 3. Final State - Verify Alice's rewards are PROTECTED
        uint256 aliceFinalClaimable = staking.claimableRewards(alice, address(underlying));
        console.log('   Alice claimable after attack:', aliceFinalClaimable / 1e18);

        // ASSERTIONS - These express CORRECT behavior (will FAIL with vulnerability)
        console.log('\n5. SECURITY ASSERTIONS:');

        // Alice should retain her original claimable rewards (±1% for rounding)
        // FAILS NOW: Alice only has ~100 instead of ~1000
        assertApproxEqRel(
            aliceFinalClaimable,
            aliceExpectedRewards,
            0.01e18, // 1% tolerance
            "VULNERABILITY: Alice's rewards were diluted by attacker's flash loan stake"
        );

        // Attacker should get minimal/zero rewards (not 90% of pool!)
        // FAILS NOW: Attacker gets ~900 tokens
        assertLt(
            bobRewardsClaimed,
            rewardAmount / 10, // Should be less than 10% of pool
            'VULNERABILITY: Attacker drained majority of reward pool with flash loan'
        );

        // Total claimed + remaining should equal original pool
        assertApproxEqAbs(
            bobRewardsClaimed + aliceFinalClaimable,
            rewardAmount,
            1e15, // Dust tolerance
            'Reward accounting broken'
        );

        console.log('\n[TEST SHOULD FAIL - Vulnerability exists]');
        console.log('After fix: Alice will keep her rewards, attacker gets minimal/zero');
    }

    /**
     * @notice TEST 2: Sequential Stakers - Unfair Reward Distribution
     * @dev This test FAILS when vulnerability exists
     *      Alice earned rewards alone, Bob just joined but instantly dilutes her share
     *      EXPECTED: Alice keeps her accumulated rewards when Bob joins
     *      ACTUAL: Alice loses 50% of rewards to Bob who just arrived
     */
    function test_SequentialStakers_ShouldNotDiluteExistingRewards() public {
        console.log('\n=== TEST 2: Sequential Stakers Unfair Distribution ===\n');

        uint256 aliceStake = 1_000 * 1e18;
        uint256 bobStake = 1_000 * 1e18;
        uint256 rewardAmount = 1_000 * 1e18;

        // 1. Alice stakes first (at t=0)
        console.log('1. Alice stakes 1,000 tokens at t=0');
        vm.startPrank(alice);
        underlying.approve(address(staking), aliceStake);
        staking.stake(aliceStake);
        vm.stopPrank();

        // 2. Time passes, rewards accumulate (Alice is ALONE earning rewards)
        console.log('2. Rewards accumulate while Alice is alone');
        vm.warp(block.timestamp + 1 days);
        underlying.mint(address(staking), rewardAmount);
        staking.accrueRewards(address(underlying));

        // Vest rewards
        vm.warp(block.timestamp + STREAM_WINDOW);

        // Alice's expected rewards (she was alone when rewards accumulated)
        uint256 aliceRewardsBeforeBob = staking.claimableRewards(alice, address(underlying));
        console.log('   Alice claimable: ', aliceRewardsBeforeBob / 1e18);
        console.log('   Alice earned alone for 1 day');

        // 3. Bob joins NOW (after rewards already accumulated to Alice)
        console.log('\n3. Bob joins NOW (just arrived)');
        vm.startPrank(bob);
        underlying.approve(address(staking), bobStake);
        staking.stake(bobStake);
        vm.stopPrank();

        console.log('   Total staked now:', staking.totalStaked() / 1e18);

        // 4. Check reward distribution after Bob joins
        uint256 aliceRewardsAfterBob = staking.claimableRewards(alice, address(underlying));
        uint256 bobRewards = staking.claimableRewards(bob, address(underlying));

        console.log('\n4. REWARD DISTRIBUTION:');
        console.log('   Alice claimable:', aliceRewardsAfterBob / 1e18);
        console.log('   Bob claimable:  ', bobRewards / 1e18);

        // ASSERTIONS - Express CORRECT behavior (will FAIL with vulnerability)
        console.log('\n5. SECURITY ASSERTIONS:');

        // Alice should keep her rewards when Bob joins (she earned them while alone)
        // FAILS NOW: Alice loses 50% when Bob stakes
        assertApproxEqRel(
            aliceRewardsAfterBob,
            aliceRewardsBeforeBob,
            0.01e18, // 1% tolerance
            "VULNERABILITY: Alice's earned rewards diluted when Bob joined"
        );

        // Bob should have minimal/zero rewards (he just joined, no time staked)
        // FAILS NOW: Bob instantly has 50% of pool
        assertLt(
            bobRewards,
            rewardAmount / 10, // Should be less than 10%
            'VULNERABILITY: Bob got significant rewards despite just joining'
        );

        console.log('\n[TEST SHOULD FAIL - Vulnerability exists]');
        console.log('After fix: Alice keeps her rewards when Bob joins');
    }
}
