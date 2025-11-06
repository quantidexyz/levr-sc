// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';

import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {MockFactory} from '../../mocks/MockFactory.sol';

/**
 * @title LevrStakingMultipleClaims Test
 * @notice POC for Sherlock audit finding: Multiple claims draining reward pool
 * @dev Tests FAIL when vulnerability exists, PASS when fixed
 *
 * VULNERABILITY:
 * - User can call claimRewards() multiple times
 * - Each call takes proportional share of REMAINING pool
 * - Geometric decrease allows draining pool before other users claim
 *
 * EXPECTED BEHAVIOR:
 * - First claim should give user their fair share
 * - Second claim should return 0 (already claimed)
 * - Other users should be able to claim their fair share
 *
 * RELATIONSHIP TO STAKE DILUTION:
 * - Same root cause: pool-based distribution without per-user history
 * - Same fix: debt accounting (accRewardPerShare + rewardDebt)
 * - This test verifies the fix ALSO prevents multiple claims
 */
contract LevrStakingMultipleClaimsTest is Test {
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;
    MockFactory factory;
    address treasury;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant INITIAL_SUPPLY = 10_000 * 1e18;
    uint256 constant STREAM_WINDOW = 7 days;

    function setUp() public {
        // Deploy tokens
        underlying = new MockERC20('Test Token', 'TEST');
        weth = new MockERC20('Wrapped ETH', 'WETH');

        // Deploy mock factory
        factory = new MockFactory();
        factory.setStreamWindowSeconds(address(underlying), uint32(STREAM_WINDOW));

        // Deploy staking contract
        staking = new LevrStaking_v1(address(0)); // no forwarder for tests

        // Deploy staked token
        stakedToken = new LevrStakedToken_v1(
            'Staked Test Token',
            'sTEST',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking (must be called by factory)
        treasury = address(0x999);
        address[] memory whitelisted = new address[](1);
        whitelisted[0] = address(weth); // Whitelist WETH as reward token
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            treasury,
            address(factory),
            whitelisted
        );

        // Mint tokens to test users and test contract
        underlying.mint(alice, INITIAL_SUPPLY);
        underlying.mint(bob, INITIAL_SUPPLY);
        weth.mint(alice, INITIAL_SUPPLY);
        weth.mint(bob, INITIAL_SUPPLY);
        weth.mint(address(this), INITIAL_SUPPLY); // For reward transfers

        // Label addresses for better trace output
        vm.label(alice, 'Alice');
        vm.label(bob, 'Bob');
        vm.label(address(staking), 'Staking');
        vm.label(address(underlying), 'Underlying');
        vm.label(address(weth), 'WETH');
    }

    /**
     * @notice POC from Sherlock submission: Multiple claims geometric decrease
     * @dev This is the EXACT test from the audit submission
     *
     * SCENARIO:
     * 1. Alice stakes 500 (50% of pool)
     * 2. Bob stakes 500 (50% of pool)
     * 3. 1000 WETH rewards accumulate
     * 4. Alice claims 10 times rapidly
     * 5. Bob claims once
     *
     * EXPECTED (FAIR):
     * - Alice: 500 WETH (50% stake)
     * - Bob: 500 WETH (50% stake)
     *
     * ACTUAL WITH VULNERABILITY:
     * - Alice: 999 WETH (via repeated claims)
     * - Bob: 488 WETH (diluted by Alice's abuse)
     */
    function test_EDGE_multipleClaimsGeometricDecrease() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes 500 tokens (50% of pool)
        vm.prank(alice);
        underlying.approve(address(staking), 500 ether);
        vm.prank(alice);
        staking.stake(500 ether);

        // Bob stakes 500 tokens (50% of pool)
        vm.prank(bob);
        underlying.approve(address(staking), 500 ether);
        vm.prank(bob);
        staking.stake(500 ether);

        // Accrue 1000 WETH rewards
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        skip(7 days); // Make all rewards available (streamWindowSeconds = 7 days)

        console2.log('=== Testing Geometric Decrease (50% Stake) ===');
        console2.log('Initial pool: 1000 WETH');
        console2.log('Alice stake: 50%, Bob stake: 50%');
        console2.log('');

        uint256 totalAliceClaimed = 0;

        // Alice claims 10 times rapidly
        for (uint256 i = 1; i <= 10; i++) {
            uint256 balanceBefore = weth.balanceOf(alice);
            vm.prank(alice);
            staking.claimRewards(tokens, alice);
            uint256 claimed = weth.balanceOf(alice) - balanceBefore;
            totalAliceClaimed += claimed;

            console2.log(
                'Alice claim %s: %s WETH (cumulative: %s)',
                i,
                claimed / 1e18,
                totalAliceClaimed / 1e18
            );
        }

        // Bob claims his share (should still be able to claim)
        uint256 bobBalanceBefore = weth.balanceOf(bob);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        uint256 bobClaimed = weth.balanceOf(bob) - bobBalanceBefore;

        console2.log('');
        console2.log('=== Final Results ===');
        console2.log('Alice total: %s WETH (after 10 claims)', totalAliceClaimed / 1e18);
        console2.log('Bob total: %s WETH (after 1 claim)', bobClaimed / 1e18);
        console2.log(
            'Pool remaining: %s WETH',
            staking.claimableRewards(alice, address(weth)) / 1e18
        );

        // ASSERTIONS - Express CORRECT behavior (will FAIL if vulnerability exists)
        console2.log('');
        console2.log('=== Security Assertions ===');

        // Alice should get her fair 50% share (500 WETH ± 1%)
        // FAILS if vulnerability exists: Alice gets 999 WETH
        assertApproxEqRel(
            totalAliceClaimed,
            500 ether,
            0.01e18, // 1% tolerance
            'VULNERABILITY: Alice claimed more than her fair share via repeated claims'
        );

        // Bob should get his fair 50% share (500 WETH ± 1%)
        // FAILS if vulnerability exists: Bob only gets 488 WETH
        assertApproxEqRel(
            bobClaimed,
            500 ether,
            0.01e18, // 1% tolerance
            'VULNERABILITY: Bob was diluted by Alice repeated claims'
        );

        // After both claim, pool should be empty (or just dust)
        uint256 remainingPool = staking.claimableRewards(alice, address(weth));
        assertLt(
            remainingPool,
            0.01 ether, // Less than 0.01 WETH dust
            'Pool should be empty after both users claim'
        );

        console2.log('');
        console2.log('[EXPECTED OUTCOME]');
        console2.log('BEFORE FIX: Test FAILS - Alice drains pool via repeated claims');
        console2.log('AFTER FIX: Test PASSES - Second claim returns 0 (debt accounting)');
    }

    /**
     * @notice Simplified test: Verify second claim returns zero
     * @dev More direct test of the fix mechanism
     */
    function test_secondClaimShouldReturnZero() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes 1000 tokens (100% of pool)
        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Accrue 1000 WETH rewards
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        skip(7 days); // Make all rewards available

        console2.log('=== Test: Second Claim Should Return Zero ===');
        console2.log('');

        // First claim
        uint256 balanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 firstClaim = weth.balanceOf(alice) - balanceBefore;

        console2.log('First claim: %s WETH', firstClaim / 1e18);

        // Second claim (should be 0 with fix)
        balanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 secondClaim = weth.balanceOf(alice) - balanceBefore;

        console2.log('Second claim: %s WETH', secondClaim / 1e18);
        console2.log('');

        // ASSERTIONS
        assertApproxEqRel(
            firstClaim,
            1000 ether,
            0.01e18,
            'First claim should give all rewards (100% stake)'
        );

        // This is the key assertion - second claim MUST be 0 after fix
        assertEq(secondClaim, 0, 'VULNERABILITY: Second claim should return 0 (already claimed)');

        console2.log('[EXPECTED OUTCOME]');
        console2.log('BEFORE FIX: secondClaim > 0 (user can claim proportional share repeatedly)');
        console2.log('AFTER FIX: secondClaim = 0 (debt = accRewardPerShare blocks re-claim)');
    }

    /**
     * @notice Test: Claiming between new reward accruals
     * @dev Verify users can claim new rewards but not old ones
     */
    function test_canClaimNewRewardsButNotOldOnes() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes 1000 tokens
        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // First batch: 500 WETH rewards
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        skip(7 days);

        console2.log('=== Test: New Rewards vs Old Rewards ===');
        console2.log('');
        console2.log('First reward batch: 500 WETH');

        // Alice claims first batch
        uint256 aliceBalanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalance1 = weth.balanceOf(alice);
        uint256 firstClaim = aliceBalance1 - aliceBalanceBefore;
        console2.log('Alice claims first batch: %s WETH', firstClaim / 1e18);

        // Try to claim again (should be 0)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalance2 = weth.balanceOf(alice);
        uint256 secondAttempt = aliceBalance2 - aliceBalance1;
        console2.log('Alice tries to claim again: %s WETH', secondAttempt / 1e18);

        // Second batch: Another 500 WETH rewards
        console2.log('');
        console2.log('Second reward batch: 500 WETH');
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        skip(7 days);

        // Alice should be able to claim NEW rewards
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalance3 = weth.balanceOf(alice);
        uint256 thirdClaim = aliceBalance3 - aliceBalance2;
        console2.log('Alice claims second batch: %s WETH', thirdClaim / 1e18);

        // ASSERTIONS
        assertApproxEqRel(firstClaim, 500 ether, 0.01e18, 'First batch should be 500 WETH');

        assertEq(secondAttempt, 0, 'Second claim should be 0 (no new rewards yet)');

        assertApproxEqRel(
            thirdClaim,
            500 ether,
            0.01e18,
            'Third claim should give second batch (500 WETH)'
        );

        console2.log('');
        console2.log('[PASS] Users can claim new rewards but not re-claim old ones');
    }
}
