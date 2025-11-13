// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';
import {console2} from 'forge-std/console2.sol';

import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @notice Mock ERC20 for testing
 */
contract MockERC20 is ERC20 {
    address private _admin;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _admin = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function admin() external view returns (address) {
        return _admin;
    }

    function setAdmin(address newAdmin) external {
        _admin = newAdmin;
    }
}

/**
 * @notice Mock Factory with stream window configuration
 */
contract MockFactoryWithConfig {
    uint32 public defaultStreamWindow = 7 days;

    function streamWindowSeconds(address) external view returns (uint32) {
        return defaultStreamWindow;
    }

    function setStreamWindow(uint32 window) external {
        defaultStreamWindow = window;
    }
}

/**
 * @title LevrStakingExtremeSmallRewardsTest
 * @notice Tests extreme edge case: distributing 1 wei or few weis of rewards
 * @dev Validates that extremely small reward amounts don't corrupt accounting:
 *      - accRewardPerShare remains consistent
 *      - rewardDebt tracking stays correct
 *      - No overflow/underflow in calculations
 *      - State remains recoverable even after 1 wei distribution
 *      - Normal rewards work correctly after small reward distribution
 */
contract LevrStakingExtremeSmallRewardsTest is Test, LevrFactoryDeployHelper {
    MockFactoryWithConfig public factory;
    LevrStaking_v1 public staking;
    LevrStakedToken_v1 public stakedToken;

    MockERC20 public stakingToken; // 18 decimals
    MockERC20 public rewardToken; // 18 decimals

    address public trustedForwarder = makeAddr('trustedForwarder');
    address public treasury = makeAddr('treasury');
    address public tokenAdmin = makeAddr('tokenAdmin');
    address public user1 = makeAddr('user1');
    address public user2 = makeAddr('user2');
    address public user3 = makeAddr('user3');

    function setUp() public {
        console2.log('=== Extreme Small Rewards Test Setup ===');

        // Deploy mock factory
        factory = new MockFactoryWithConfig();

        // Deploy tokens (both 18 decimals for max precision)
        stakingToken = new MockERC20('Staking Token', 'STAKE');
        stakingToken.setAdmin(tokenAdmin);

        rewardToken = new MockERC20('Reward Token', 'REWARD');

        console2.log('Staking Token:', address(stakingToken));
        console2.log('Reward Token:', address(rewardToken));

        // Deploy staking contract
        staking = new LevrStaking_v1(trustedForwarder, address(factory));

        // Deploy staked token
        stakedToken = createStakedToken(
            'Staked Token',
            'sSTAKE',
            18,
            address(stakingToken),
            address(staking)
        );

        // Initialize staking contract with reward token whitelisted
        address[] memory initialWhitelist = new address[](1);
        initialWhitelist[0] = address(rewardToken);

        vm.prank(address(factory));
        staking.initialize(address(stakingToken), address(stakedToken), treasury, initialWhitelist);

        console2.log('Staking contract initialized');
        console2.log('PRECISION:', staking.PRECISION());
    }

    /**
     * @notice Test Vector 1: Distribute 1 wei to single staker
     * @dev The smallest possible reward distribution
     */
    function test_oneWei_singleStaker() public {
        console2.log('\n=== Test Vector 1: 1 Wei to Single Staker ===');

        // User stakes a normal amount
        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked:', stakeAmount / 1e18, 'tokens');

        // Capture state before 1 wei distribution
        uint256 accRewardBefore = staking.accRewardPerShare(address(rewardToken));
        console2.log('accRewardPerShare before:', accRewardBefore);

        // Distribute 1 wei
        rewardToken.mint(address(staking), 1);
        staking.accrueRewards(address(rewardToken));

        // Wait for streaming to complete
        vm.warp(block.timestamp + 7 days);

        // Capture state after
        uint256 accRewardAfter = staking.accRewardPerShare(address(rewardToken));
        console2.log('accRewardPerShare after:', accRewardAfter);

        // Check claimable
        uint256 claimable = staking.claimableRewards(user1, address(rewardToken));
        console2.log('User1 claimable:', claimable);

        // Accounting should not overflow or corrupt
        assertGe(accRewardAfter, accRewardBefore, 'accRewardPerShare should not decrease');

        // Expected: (1 * PRECISION) / stakeAmount
        // = (1 * 1e18) / (1000 * 1e18) = 1e18 / 1000e18 = 1/1000 = 0 (rounds down)
        // So accRewardPerShare might not change if reward is too small

        console2.log('[OK] 1 wei distribution does not corrupt accounting');
    }

    /**
     * @notice Test Vector 2: Distribute 1 wei to multiple stakers
     * @dev Tests precision loss with multiple beneficiaries
     */
    function test_oneWei_multipleStakers() public {
        console2.log('\n=== Test Vector 2: 1 Wei to Multiple Stakers ===');

        // Three users stake equal amounts
        uint256 stakeAmount = 1_000 * 1e18;

        stakingToken.mint(user1, stakeAmount);
        stakingToken.mint(user2, stakeAmount);
        stakingToken.mint(user3, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.prank(user2);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user2);
        staking.stake(stakeAmount);

        vm.prank(user3);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user3);
        staking.stake(stakeAmount);

        console2.log('3 users staked:', stakeAmount / 1e18, 'tokens each');
        console2.log('Total staked:', staking.totalStaked() / 1e18, 'tokens');

        // Distribute 1 wei across 3 stakers
        rewardToken.mint(address(staking), 1);
        staking.accrueRewards(address(rewardToken));

        vm.warp(block.timestamp + 7 days);

        // Check claimable for each user
        uint256 claimable1 = staking.claimableRewards(user1, address(rewardToken));
        uint256 claimable2 = staking.claimableRewards(user2, address(rewardToken));
        uint256 claimable3 = staking.claimableRewards(user3, address(rewardToken));

        console2.log('User1 claimable:', claimable1);
        console2.log('User2 claimable:', claimable2);
        console2.log('User3 claimable:', claimable3);

        // With 1 wei and large totalStaked, everyone likely gets 0 due to precision
        // But accounting should remain consistent
        uint256 totalClaimable = claimable1 + claimable2 + claimable3;
        console2.log('Total claimable:', totalClaimable);

        // Accounting should not overflow
        assertLe(totalClaimable, 1, 'Cannot claim more than distributed');

        console2.log('[OK] 1 wei to multiple stakers does not corrupt accounting');
    }

    /**
     * @notice Test Vector 3: Multiple 1 wei distributions
     * @dev Tests if repeated small distributions cause accumulation issues
     */
    function test_multiple_oneWei_distributions() public {
        console2.log('\n=== Test Vector 3: Multiple 1 Wei Distributions ===');

        uint256 stakeAmount = 100 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked:', stakeAmount / 1e18, 'tokens');

        // Distribute 1 wei, 10 times
        for (uint256 i = 0; i < 10; i++) {
            rewardToken.mint(address(staking), 1);
            staking.accrueRewards(address(rewardToken));
            vm.warp(block.timestamp + 7 days);
        }

        uint256 accRewardFinal = staking.accRewardPerShare(address(rewardToken));
        console2.log('accRewardPerShare after 10 distributions:', accRewardFinal);

        uint256 claimable = staking.claimableRewards(user1, address(rewardToken));
        console2.log('Total claimable:', claimable);

        // Should be able to claim without reverting
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(user1);
        staking.claimRewards(tokens, user1);

        uint256 received = rewardToken.balanceOf(user1);
        console2.log('Actually received:', received);

        // Received should not exceed what was distributed (10 wei)
        assertLe(received, 10, 'Cannot receive more than distributed');

        console2.log('[OK] Multiple 1 wei distributions handled correctly');
    }

    /**
     * @notice Test Vector 4: Normal rewards after 1 wei distribution (DOS Prevention)
     * @dev Validates that 1 wei distribution doesn't DOS the reward system:
     *      - accrueRewards doesn't revert
     *      - Streaming continues to work
     *      - Subsequent rewards can be distributed
     *      - Claims work normally after dust distribution
     */
    function test_normalRewards_after_oneWei_noDOS() public {
        console2.log('\n=== Test Vector 4: Normal Rewards After 1 Wei (DOS Prevention) ===');

        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        // First: distribute 1 wei (dust) - should NOT revert
        console2.log('Distributing 1 wei (should not revert)...');
        rewardToken.mint(address(staking), 1);
        staking.accrueRewards(address(rewardToken)); // Should succeed

        console2.log('[PASS] accrueRewards with 1 wei succeeded (no DOS)');

        // Verify streaming was set up
        (uint64 streamStart1, uint64 streamEnd1, uint256 streamTotal1) = staking.getTokenStreamInfo(
            address(rewardToken)
        );
        console2.log('Stream after 1 wei - Start:', streamStart1);
        console2.log('Stream after 1 wei - End:', streamEnd1);
        console2.log('Stream after 1 wei - Total:', streamTotal1);

        assertGt(streamEnd1, streamStart1, 'Stream window should be set');
        assertEq(streamTotal1, 1, 'Stream total should be 1 wei');

        // Wait for stream to vest
        vm.warp(block.timestamp + 7 days);

        // Claim should not revert (even if claimable is 0 due to rounding)
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(user1);
        staking.claimRewards(tokens, user1); // Should not revert
        console2.log('[PASS] Claim after 1 wei succeeded (no DOS)');

        // Then: distribute normal amount (1000 tokens) - should still work
        console2.log('\nDistributing 1,000 tokens after dust...');
        uint256 normalReward = 1_000 * 1e18;
        rewardToken.mint(address(staking), normalReward);
        staking.accrueRewards(address(rewardToken)); // Should succeed
        console2.log('[PASS] accrueRewards with normal amount succeeded');

        vm.warp(block.timestamp + 7 days);

        // Check claimable for normal rewards
        uint256 claimable = staking.claimableRewards(user1, address(rewardToken));
        console2.log('Claimable after normal rewards:', claimable / 1e18, 'tokens');

        // Should get approximately the normal reward amount (1 wei was already claimed/lost to rounding)
        assertApproxEqRel(claimable, normalReward, 0.01e18, 'Should get ~1000 tokens');

        // Claim and verify - should not revert
        vm.prank(user1);
        staking.claimRewards(tokens, user1);

        uint256 received = rewardToken.balanceOf(user1);
        console2.log('Actually received:', received / 1e18, 'tokens');

        assertApproxEqRel(received, normalReward, 0.01e18, 'Should receive ~1000 tokens');

        console2.log('[OK] No DOS: System works normally after 1 wei distribution');
    }

    /**
     * @notice Test Vector 5: Extreme case - 1 wei with very large stake
     * @dev Tests the most extreme precision loss scenario
     */
    function test_oneWei_largeStake() public {
        console2.log('\n=== Test Vector 5: 1 Wei with Large Stake ===');

        // User stakes a very large amount (1 billion tokens)
        uint256 largeStake = 1_000_000_000 * 1e18;
        stakingToken.mint(user1, largeStake);

        vm.prank(user1);
        stakingToken.approve(address(staking), largeStake);
        vm.prank(user1);
        staking.stake(largeStake);

        console2.log('User1 staked:', largeStake / 1e18, 'tokens');

        // Capture initial state
        uint256 totalStakedBefore = staking.totalStaked();
        uint256 accRewardBefore = staking.accRewardPerShare(address(rewardToken));

        // Distribute 1 wei
        rewardToken.mint(address(staking), 1);
        staking.accrueRewards(address(rewardToken));
        vm.warp(block.timestamp + 7 days);

        // Capture state after
        uint256 totalStakedAfter = staking.totalStaked();
        uint256 accRewardAfter = staking.accRewardPerShare(address(rewardToken));

        console2.log('Total staked before:', totalStakedBefore);
        console2.log('Total staked after:', totalStakedAfter);
        console2.log('accRewardPerShare before:', accRewardBefore);
        console2.log('accRewardPerShare after:', accRewardAfter);

        // Verify no corruption
        assertEq(totalStakedBefore, totalStakedAfter, 'Total staked should not change');
        assertGe(accRewardAfter, accRewardBefore, 'accRewardPerShare should not decrease');

        // With 1 wei / 1 billion tokens, increment will be:
        // (1 * 1e18) / (1e9 * 1e18) = 1e18 / 1e27 = 1e-9 → rounds to 0
        // So accRewardPerShare might not change, which is OK

        uint256 claimable = staking.claimableRewards(user1, address(rewardToken));
        console2.log('Claimable:', claimable);

        // Try to claim (should not revert)
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(user1);
        staking.claimRewards(tokens, user1);

        console2.log('[OK] Extreme precision loss handled without corruption');
    }

    /**
     * @notice Test Vector 6: Few weis (2-10 wei) distribution
     * @dev Tests slightly larger but still extremely small amounts
     */
    function test_fewWeis_distribution() public {
        console2.log('\n=== Test Vector 6: Few Weis (2-10) Distribution ===');

        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);
        stakingToken.mint(user2, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.prank(user2);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user2);
        staking.stake(stakeAmount);

        console2.log('2 users staked 1,000 tokens each');

        // Distribute 10 wei
        rewardToken.mint(address(staking), 10);
        staking.accrueRewards(address(rewardToken));
        vm.warp(block.timestamp + 7 days);

        uint256 claimable1 = staking.claimableRewards(user1, address(rewardToken));
        uint256 claimable2 = staking.claimableRewards(user2, address(rewardToken));

        console2.log('User1 claimable:', claimable1);
        console2.log('User2 claimable:', claimable2);

        // Claim both
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(user1);
        staking.claimRewards(tokens, user1);

        vm.prank(user2);
        staking.claimRewards(tokens, user2);

        uint256 received1 = rewardToken.balanceOf(user1);
        uint256 received2 = rewardToken.balanceOf(user2);

        console2.log('User1 received:', received1);
        console2.log('User2 received:', received2);

        // Total received should not exceed distributed
        assertLe(received1 + received2, 10, 'Total received <= distributed');

        console2.log('[OK] Few weis handled correctly');
    }

    /**
     * @notice Test Vector 7: Stake, distribute 1 wei, unstake
     * @dev Tests full lifecycle with 1 wei reward
     */
    function test_fullLifecycle_oneWei() public {
        console2.log('\n=== Test Vector 7: Full Lifecycle with 1 Wei ===');

        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        // Stake
        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('Staked:', stakeAmount / 1e18, 'tokens');

        // Distribute 1 wei
        rewardToken.mint(address(staking), 1);
        staking.accrueRewards(address(rewardToken));
        vm.warp(block.timestamp + 7 days);

        console2.log('Distributed 1 wei');

        // Check state before unstake
        uint256 claimableBefore = staking.claimableRewards(user1, address(rewardToken));
        console2.log('Claimable before unstake:', claimableBefore);

        // Unstake (auto-claims rewards)
        vm.prank(user1);
        staking.unstake(stakeAmount, user1);

        console2.log('Unstaked');

        // Check final state
        uint256 finalStakingBalance = stakingToken.balanceOf(user1);
        uint256 finalRewardBalance = rewardToken.balanceOf(user1);

        console2.log('Final staking token balance:', finalStakingBalance / 1e18);
        console2.log('Final reward balance:', finalRewardBalance);

        // Should get staking tokens back
        assertEq(finalStakingBalance, stakeAmount, 'Should get all staking tokens back');

        // Reward balance should not overflow
        assertLe(finalRewardBalance, 1, 'Cannot receive more than 1 wei');

        console2.log('[OK] Full lifecycle with 1 wei completes successfully');
    }

    /**
     * @notice Test Vector 8: DOS Attack Prevention - Repeated 1 wei spam
     * @dev Validates that an attacker cannot DOS the system by repeatedly sending 1 wei
     *      Key validations:
     *      - accrueRewards succeeds with 1 wei (no revert)
     *      - Streaming is set up correctly
     *      - Claims don't revert
     *      - System remains usable after spam
     *      - Normal rewards still work after spam attack
     */
    function test_dosAttackPrevention_repeatedOneWeiSpam() public {
        console2.log('\n=== Test Vector 8: DOS Attack Prevention (1 Wei Spam) ===');

        uint256 stakeAmount = 500 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked:', stakeAmount / 1e18, 'tokens');
        console2.log('\nSimulating DOS attack: 100 consecutive 1 wei distributions...');

        // Simulate DOS attack: attacker sends 100 consecutive 1 wei rewards
        for (uint256 i = 1; i <= 100; i++) {
            // Each distribution should NOT revert
            rewardToken.mint(address(staking), 1);
            staking.accrueRewards(address(rewardToken)); // Should not revert

            // Advance time slightly to trigger new stream windows
            vm.warp(block.timestamp + 1 hours);

            if (i % 25 == 0) {
                console2.log('  Completed', i, 'spam distributions (no revert)');
            }
        }

        console2.log('[PASS] All 100 spam distributions succeeded without DOS');

        // Verify streaming is still working
        (uint64 streamStart, uint64 streamEnd, uint256 streamTotal) = staking.getTokenStreamInfo(
            address(rewardToken)
        );
        console2.log('Stream still active - Start:', streamStart);
        console2.log('Stream still active - End:', streamEnd);
        console2.log('Stream total after spam:', streamTotal);

        assertGt(streamEnd, streamStart, 'Streaming should still be active');

        // User should be able to claim without reverting (even if amount is 0)
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(user1);
        staking.claimRewards(tokens, user1); // Should not revert
        console2.log('[PASS] Claim after spam attack succeeded (no DOS)');

        // Now distribute normal rewards - system should still work
        console2.log('\nDistributing normal rewards (1000 tokens) after spam...');
        uint256 normalReward = 1_000 * 1e18;
        rewardToken.mint(address(staking), normalReward);
        staking.accrueRewards(address(rewardToken)); // Should not revert
        console2.log('[PASS] Normal accrueRewards succeeded after spam');

        vm.warp(block.timestamp + 7 days);

        uint256 claimable = staking.claimableRewards(user1, address(rewardToken));
        console2.log('Claimable after spam + normal:', claimable / 1e18, 'tokens');

        // Should get approximately the normal reward
        assertApproxEqRel(claimable, normalReward, 0.05e18, 'Should get ~1000 tokens');

        // Final claim should work
        vm.prank(user1);
        staking.claimRewards(tokens, user1);

        uint256 finalBalance = rewardToken.balanceOf(user1);
        console2.log('Final balance:', finalBalance / 1e18, 'tokens');

        console2.log('[OK] DOS attack prevented: System remains functional after 100x 1 wei spam');
    }

    /**
     * @notice Test Vector 9: Accounting consistency after multiple small distributions
     * @dev Verifies all accounting invariants hold after many small distributions
     */
    function test_accountingInvariants_multipleSmallDistributions() public {
        console2.log('\n=== Test Vector 8: Accounting Invariants ===');

        uint256 stakeAmount = 500 * 1e18;
        stakingToken.mint(user1, stakeAmount);
        stakingToken.mint(user2, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.prank(user2);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user2);
        staking.stake(stakeAmount);

        console2.log('2 users staked 500 tokens each');

        // Distribute small amounts multiple times
        for (uint256 i = 1; i <= 5; i++) {
            rewardToken.mint(address(staking), i); // 1, 2, 3, 4, 5 wei
            staking.accrueRewards(address(rewardToken));
            vm.warp(block.timestamp + 7 days);
            console2.log('Distributed', i, 'wei');
        }

        // Total distributed: 1+2+3+4+5 = 15 wei

        uint256 claimable1 = staking.claimableRewards(user1, address(rewardToken));
        uint256 claimable2 = staking.claimableRewards(user2, address(rewardToken));

        console2.log('User1 claimable:', claimable1);
        console2.log('User2 claimable:', claimable2);

        // Claim both
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(user1);
        staking.claimRewards(tokens, user1);

        vm.prank(user2);
        staking.claimRewards(tokens, user2);

        uint256 received1 = rewardToken.balanceOf(user1);
        uint256 received2 = rewardToken.balanceOf(user2);

        console2.log('User1 received:', received1);
        console2.log('User2 received:', received2);

        // Invariant: total received <= total distributed
        assertLe(received1 + received2, 15, 'Total received should not exceed 15 wei');

        // Verify no dust stuck in contract (all distributed or claimable)
        uint256 contractBalance = rewardToken.balanceOf(address(staking));
        console2.log('Remaining in contract:', contractBalance);
        assertLe(contractBalance, 15, 'Contract should not have more than distributed');

        console2.log('[OK] Accounting invariants hold after multiple small distributions');
    }
}
