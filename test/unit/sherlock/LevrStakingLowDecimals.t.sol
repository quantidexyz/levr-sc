// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';
import {console2} from 'forge-std/console2.sol';

import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../../src/interfaces/ILevrStaking_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @notice Mock ERC20 with custom decimals for testing
 */
contract MockERC20WithDecimals is ERC20 {
    uint8 private immutable _decimals;
    address private _admin;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
        _admin = msg.sender;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
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
 * @title LevrStakingLowDecimalsTest
 * @notice POC tests for Sherlock #24 - Reward distribution with low decimals reward tokens
 * @dev Tests validate that reward distribution works correctly when reward tokens
 *      have various decimals (6, 8, 18) while the staking token is standard 18 decimals.
 *      The system only allows staking the token defined in the factory.
 */
contract LevrStakingLowDecimalsTest is Test, LevrFactoryDeployHelper {
    MockFactoryWithConfig public factory;
    LevrStaking_v1 public staking; // Single staking contract with 18-decimal token

    LevrStakedToken_v1 public stakedToken;

    MockERC20WithDecimals public stakingToken; // 18 decimals (the token users stake)
    MockERC20WithDecimals public usdc; // 6 decimals (reward token)
    MockERC20WithDecimals public wbtc; // 8 decimals (reward token)
    MockERC20WithDecimals public dai; // 18 decimals (reward token)

    address public trustedForwarder = makeAddr('trustedForwarder');
    address public treasury = makeAddr('treasury');
    address public tokenAdmin = makeAddr('tokenAdmin');
    address public user1 = makeAddr('user1');
    address public user2 = makeAddr('user2');
    address public user3 = makeAddr('user3');

    function setUp() public {
        console2.log('=== Sherlock #24: Low Decimals Reward Token POC Setup ===');

        // Deploy mock factory
        factory = new MockFactoryWithConfig();

        // Deploy staking token (18 decimals - standard)
        stakingToken = new MockERC20WithDecimals('Staking Token', 'STAKE', 18);

        // Set the admin of the staking token to tokenAdmin so they can whitelist reward tokens
        stakingToken.setAdmin(tokenAdmin);

        console2.log('Staking Token (18 decimals):', address(stakingToken));

        // Deploy reward tokens with different decimals
        usdc = new MockERC20WithDecimals('USDC', 'USDC', 6);
        wbtc = new MockERC20WithDecimals('WBTC', 'WBTC', 8);
        dai = new MockERC20WithDecimals('DAI', 'DAI', 18);

        console2.log('USDC Reward Token (6 decimals):', address(usdc));
        console2.log('WBTC Reward Token (8 decimals):', address(wbtc));
        console2.log('DAI Reward Token (18 decimals):', address(dai));

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

        // Initialize staking contract (no initial whitelist needed)
        address[] memory emptyWhitelist = new address[](0);

        vm.prank(address(factory));
        staking.initialize(address(stakingToken), address(stakedToken), treasury, emptyWhitelist);

        // Whitelist reward tokens via tokenAdmin (who is the admin of the staking token)
        vm.startPrank(tokenAdmin);
        staking.whitelistToken(address(usdc));
        staking.whitelistToken(address(wbtc));
        staking.whitelistToken(address(dai));
        vm.stopPrank();

        console2.log('\n=== Staking Contract Initialized ===');
        console2.log('Staking token decimals:', IERC20Metadata(staking.underlying()).decimals());
        console2.log('Precision:', staking.PRECISION());
        console2.log('Min reward (precision/1000):', staking.PRECISION() / 1000);
    }

    /**
     * @notice Test Vector 1: Reward distribution works with 6-decimal reward token (USDC)
     * @dev Tests that rewards in USDC (6 decimals) are distributed correctly to stakers
     */
    function test_rewardDistribution_6DecimalRewardToken() public {
        console2.log('\n=== Test Vector 1: USDC (6 decimals) Reward Distribution ===');

        // Users stake 18-decimal staking tokens
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

        console2.log('User1 staked: 1,000 tokens');
        console2.log('User2 staked: 1,000 tokens');

        // Distribute USDC rewards (6 decimals)
        uint256 rewardAmount = 1_000 * 1e6; // 1,000 USDC
        usdc.mint(address(staking), rewardAmount);

        staking.accrueRewards(address(usdc));

        // Wait for rewards to vest (stream window is 7 days, wait full window)
        vm.warp(block.timestamp + 7 days);

        // Check claimable amounts
        uint256 claimable1 = staking.claimableRewards(user1, address(usdc));
        uint256 claimable2 = staking.claimableRewards(user2, address(usdc));

        console2.log('User1 claimable USDC:', claimable1 / 1e6);
        console2.log('User2 claimable USDC:', claimable2 / 1e6);

        // Should split 50/50
        assertApproxEqRel(claimable1, rewardAmount / 2, 0.01e18, 'User1 should get ~50%');
        assertApproxEqRel(claimable2, rewardAmount / 2, 0.01e18, 'User2 should get ~50%');

        // Claim rewards
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(usdc);

        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);

        vm.prank(user2);
        staking.claimRewards(rewardTokens, user2);

        console2.log('User1 USDC balance:', usdc.balanceOf(user1) / 1e6);
        console2.log('User2 USDC balance:', usdc.balanceOf(user2) / 1e6);

        assertApproxEqAbs(usdc.balanceOf(user1), rewardAmount / 2, 1e4, 'User1 received rewards');
        assertApproxEqAbs(usdc.balanceOf(user2), rewardAmount / 2, 1e4, 'User2 received rewards');

        console2.log('[OK] 6-decimal reward token distribution works correctly');
    }

    /**
     * @notice Test Vector 2: Reward distribution works with 8-decimal reward token (WBTC)
     * @dev Tests that rewards in WBTC (8 decimals) are distributed correctly to stakers
     */
    function test_rewardDistribution_8DecimalRewardToken() public {
        console2.log('\n=== Test Vector 2: WBTC (8 decimals) Reward Distribution ===');

        // User stakes 18-decimal staking tokens
        uint256 stakeAmount = 5_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked: 5,000 tokens');

        // Distribute WBTC rewards (8 decimals)
        uint256 rewardAmount = 2 * 1e8; // 2 WBTC
        wbtc.mint(address(staking), rewardAmount);

        staking.accrueRewards(address(wbtc));

        // Wait for rewards to vest (stream window is 7 days)
        vm.warp(block.timestamp + 7 days);

        // Check claimable amount
        uint256 claimable = staking.claimableRewards(user1, address(wbtc));
        console2.log('User1 claimable WBTC:', claimable);

        // Should get all rewards (only staker)
        assertApproxEqAbs(claimable, rewardAmount, 1e4, 'User1 should get all rewards');

        // Claim rewards
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(wbtc);

        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);

        console2.log('User1 WBTC balance:', wbtc.balanceOf(user1));

        assertApproxEqAbs(wbtc.balanceOf(user1), rewardAmount, 1e4, 'User1 received rewards');

        console2.log('[OK] 8-decimal reward token distribution works correctly');
    }

    /**
     * @notice Test Vector 3: Reward distribution works with 18-decimal reward token (DAI) - Regression
     * @dev Ensures standard 18-decimal reward tokens still work correctly
     */
    function test_rewardDistribution_18DecimalRewardToken() public {
        console2.log('\n=== Test Vector 3: DAI (18 decimals) Reward Distribution - Regression ===');

        // Users stake with different proportions
        uint256 stake1 = 3_000 * 1e18;
        uint256 stake2 = 7_000 * 1e18;

        stakingToken.mint(user1, stake1);
        stakingToken.mint(user2, stake2);

        vm.prank(user1);
        stakingToken.approve(address(staking), stake1);
        vm.prank(user1);
        staking.stake(stake1);

        vm.prank(user2);
        stakingToken.approve(address(staking), stake2);
        vm.prank(user2);
        staking.stake(stake2);

        console2.log('User1 staked: 3,000 tokens (30%)');
        console2.log('User2 staked: 7,000 tokens (70%)');

        // Distribute DAI rewards (18 decimals)
        uint256 rewardAmount = 10_000 * 1e18; // 10,000 DAI
        dai.mint(address(staking), rewardAmount);

        staking.accrueRewards(address(dai));

        // Wait for rewards to vest (stream window is 7 days)
        vm.warp(block.timestamp + 7 days);

        // Check claimable amounts
        uint256 claimable1 = staking.claimableRewards(user1, address(dai));
        uint256 claimable2 = staking.claimableRewards(user2, address(dai));

        console2.log('User1 claimable DAI:', claimable1 / 1e18);
        console2.log('User2 claimable DAI:', claimable2 / 1e18);

        // Should split 30/70
        assertApproxEqRel(claimable1, (rewardAmount * 30) / 100, 0.01e18, 'User1 should get ~30%');
        assertApproxEqRel(claimable2, (rewardAmount * 70) / 100, 0.01e18, 'User2 should get ~70%');

        console2.log('[OK] 18-decimal reward token distribution works correctly');
    }

    /**
     * @notice Test Vector 4: Multiple reward cycles with different decimal reward tokens
     * @dev Tests multiple reward distributions with USDC (6 decimals) across multiple users
     */
    function test_rewardDistribution_multipleRewardCycles() public {
        console2.log('\n=== Test Vector 4: Multiple Reward Cycles with 6-Decimal USDC ===');

        // Setup: Multiple stakers with different amounts
        uint256 stake1 = 1_000 * 1e18; // user1: 1,000 tokens
        uint256 stake2 = 2_000 * 1e18; // user2: 2,000 tokens
        uint256 stake3 = 500 * 1e18; // user3: 500 tokens

        stakingToken.mint(user1, stake1);
        stakingToken.mint(user2, stake2);
        stakingToken.mint(user3, stake3);

        // All users stake
        vm.prank(user1);
        stakingToken.approve(address(staking), stake1);
        vm.prank(user1);
        staking.stake(stake1);

        vm.prank(user2);
        stakingToken.approve(address(staking), stake2);
        vm.prank(user2);
        staking.stake(stake2);

        vm.prank(user3);
        stakingToken.approve(address(staking), stake3);
        vm.prank(user3);
        staking.stake(stake3);

        console2.log('Total staked: 3,500 tokens');
        console2.log('User1 stake: 1,000 tokens (28.57%)');
        console2.log('User2 stake: 2,000 tokens (57.14%)');
        console2.log('User3 stake: 500 tokens (14.29%)');

        // First reward distribution: 1,000 USDC (6 decimals)
        uint256 reward1 = 1_000 * 1e6;
        usdc.mint(address(staking), reward1);
        staking.accrueRewards(address(usdc));

        // Wait for rewards to vest (stream window is 7 days)
        vm.warp(block.timestamp + 7 days);

        console2.log('\n--- First Reward Cycle: 1,000 USDC ---');
        uint256 claimable1_user1 = staking.claimableRewards(user1, address(usdc));
        uint256 claimable1_user2 = staking.claimableRewards(user2, address(usdc));
        uint256 claimable1_user3 = staking.claimableRewards(user3, address(usdc));

        console2.log('User1 claimable:', claimable1_user1 / 1e6);
        console2.log('User2 claimable:', claimable1_user2 / 1e6);
        console2.log('User3 claimable:', claimable1_user3 / 1e6);

        // Verify proportional distribution
        assertApproxEqRel(
            claimable1_user1,
            (reward1 * 1000) / 3500,
            0.01e18,
            'User1 should get ~28.57% of rewards'
        );
        assertApproxEqRel(
            claimable1_user2,
            (reward1 * 2000) / 3500,
            0.01e18,
            'User2 should get ~57.14% of rewards'
        );
        assertApproxEqRel(
            claimable1_user3,
            (reward1 * 500) / 3500,
            0.01e18,
            'User3 should get ~14.29% of rewards'
        );

        // Users claim rewards
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(usdc);

        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);

        vm.prank(user2);
        staking.claimRewards(rewardTokens, user2);

        vm.prank(user3);
        staking.claimRewards(rewardTokens, user3);

        console2.log('\n--- After Claims ---');
        console2.log('User1 USDC balance:', usdc.balanceOf(user1) / 1e6);
        console2.log('User2 USDC balance:', usdc.balanceOf(user2) / 1e6);
        console2.log('User3 USDC balance:', usdc.balanceOf(user3) / 1e6);

        // Second reward distribution: 2,000 USDC
        uint256 reward2 = 2_000 * 1e6;
        usdc.mint(address(staking), reward2);
        staking.accrueRewards(address(usdc));

        // Wait for rewards to vest (stream window is 7 days)
        vm.warp(block.timestamp + 7 days);

        console2.log('\n--- Second Reward Cycle: 2,000 USDC ---');
        uint256 claimable2_user1 = staking.claimableRewards(user1, address(usdc));
        uint256 claimable2_user2 = staking.claimableRewards(user2, address(usdc));
        uint256 claimable2_user3 = staking.claimableRewards(user3, address(usdc));

        console2.log('User1 claimable:', claimable2_user1 / 1e6);
        console2.log('User2 claimable:', claimable2_user2 / 1e6);
        console2.log('User3 claimable:', claimable2_user3 / 1e6);

        // Claim again
        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);

        vm.prank(user2);
        staking.claimRewards(rewardTokens, user2);

        vm.prank(user3);
        staking.claimRewards(rewardTokens, user3);

        console2.log('\n--- Final Balances After Multiple Rewards ---');
        uint256 final1 = usdc.balanceOf(user1);
        uint256 final2 = usdc.balanceOf(user2);
        uint256 final3 = usdc.balanceOf(user3);

        console2.log('User1 total USDC:', final1 / 1e6);
        console2.log('User2 total USDC:', final2 / 1e6);
        console2.log('User3 total USDC:', final3 / 1e6);

        // Verify all rewards were distributed
        uint256 totalRewards = reward1 + reward2;
        uint256 totalClaimed = final1 + final2 + final3;
        assertApproxEqAbs(totalClaimed, totalRewards, 1e4, 'All rewards should be distributed');

        console2.log('[OK] Multi-cycle reward distribution works correctly for 6-decimal rewards');
    }

    /**
     * @notice Test Vector 5: Mixed reward tokens with different decimals
     * @dev Tests simultaneous distribution of multiple reward tokens with different decimals
     */
    function test_rewardDistribution_mixedDecimals() public {
        console2.log('\n=== Test Vector 5: Mixed Reward Tokens (6, 8, 18 decimals) ===');

        // User stakes
        uint256 stakeAmount = 10_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked: 10,000 tokens');

        // Distribute rewards in all three tokens
        uint256 usdcReward = 500 * 1e6; // 500 USDC (6 decimals)
        uint256 wbtcReward = 1 * 1e8; // 1 WBTC (8 decimals)
        uint256 daiReward = 1_000 * 1e18; // 1,000 DAI (18 decimals)

        usdc.mint(address(staking), usdcReward);
        wbtc.mint(address(staking), wbtcReward);
        dai.mint(address(staking), daiReward);

        staking.accrueRewards(address(usdc));
        staking.accrueRewards(address(wbtc));
        staking.accrueRewards(address(dai));

        // Wait for rewards to vest (stream window is 7 days)
        vm.warp(block.timestamp + 7 days);

        console2.log('\n--- Rewards Distributed ---');
        console2.log('USDC (6 decimals):', usdcReward / 1e6);
        console2.log('WBTC (8 decimals):', wbtcReward / 1e8);
        console2.log('DAI (18 decimals):', daiReward / 1e18);

        // Check claimable amounts
        uint256 claimableUsdc = staking.claimableRewards(user1, address(usdc));
        uint256 claimableWbtc = staking.claimableRewards(user1, address(wbtc));
        uint256 claimableDai = staking.claimableRewards(user1, address(dai));

        console2.log('\n--- Claimable Amounts ---');
        console2.log('USDC claimable:', claimableUsdc / 1e6);
        console2.log('WBTC claimable:', claimableWbtc / 1e8);
        console2.log('DAI claimable:', claimableDai / 1e18);

        // Should get all rewards (only staker)
        assertApproxEqAbs(claimableUsdc, usdcReward, 1e4, 'Should get all USDC');
        assertApproxEqAbs(claimableWbtc, wbtcReward, 1e4, 'Should get all WBTC');
        assertApproxEqAbs(claimableDai, daiReward, 1e10, 'Should get all DAI');

        // Claim all rewards
        address[] memory rewardTokens = new address[](3);
        rewardTokens[0] = address(usdc);
        rewardTokens[1] = address(wbtc);
        rewardTokens[2] = address(dai);

        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);

        console2.log('\n--- Claimed Balances ---');
        console2.log('USDC balance:', usdc.balanceOf(user1) / 1e6);
        console2.log('WBTC balance:', wbtc.balanceOf(user1) / 1e8);
        console2.log('DAI balance:', dai.balanceOf(user1) / 1e18);

        assertApproxEqAbs(usdc.balanceOf(user1), usdcReward, 1e4, 'Received all USDC');
        assertApproxEqAbs(wbtc.balanceOf(user1), wbtcReward, 1e4, 'Received all WBTC');
        assertApproxEqAbs(dai.balanceOf(user1), daiReward, 1e10, 'Received all DAI');

        console2.log('[OK] Mixed decimal reward tokens work correctly');
    }

    /**
     * @notice Test Vector 6: Extreme low decimal reward token (2 decimals)
     * @dev Tests edge case with extremely low decimal reward tokens
     */
    function test_rewardDistribution_extremeLowDecimals() public {
        console2.log('\n=== Test Vector 6: Extreme Low Decimals (2 decimals) ===');

        // Deploy 2-decimal reward token (e.g., Gemini USD)
        MockERC20WithDecimals gusd = new MockERC20WithDecimals('GUSD', 'GUSD', 2);

        // Whitelist GUSD
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(gusd));

        // Users stake
        uint256 stakeAmount = 5_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked: 5,000 tokens');

        // Distribute GUSD rewards (2 decimals)
        uint256 rewardAmount = 10_000 * 1e2; // 10,000 GUSD (2 decimals)
        gusd.mint(address(staking), rewardAmount);
        staking.accrueRewards(address(gusd));

        // Wait for rewards to vest (stream window is 7 days)
        vm.warp(block.timestamp + 7 days);

        console2.log('Reward distributed: 10,000 GUSD (2 decimals)');

        // Check claimable amount
        uint256 claimable = staking.claimableRewards(user1, address(gusd));
        console2.log('User1 claimable GUSD:', claimable / 1e2);

        // Should get all rewards
        assertApproxEqAbs(claimable, rewardAmount, 100, 'Should get all GUSD rewards');

        // Claim rewards
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(gusd);

        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);

        console2.log('User1 GUSD balance:', gusd.balanceOf(user1) / 1e2);

        assertApproxEqAbs(gusd.balanceOf(user1), rewardAmount, 100, 'Received GUSD rewards');

        console2.log('[OK] Extreme low decimal (2) reward token works correctly');
    }

    /**
     * @notice Test Vector 7: Precision check - ensures PRECISION is always 1e18
     * @dev Validates that PRECISION constant is correct regardless of staking token
     */
    function test_precision_constant() public view {
        console2.log('\n=== Test Vector 7: Precision Constant Check ===');

        uint256 precision = staking.PRECISION();
        console2.log('PRECISION:', precision);
        console2.log('Min reward (precision/1000):', precision / 1000);

        // Precision should always be 1e18 for voting power calculations
        assertEq(precision, 1e18, 'PRECISION should be 1e18');
        assertEq(precision / 1000, 1e15, 'Min reward should be 1e15');

        console2.log('[OK] Precision constant is correct');
    }

    /**
     * @notice Test Vector 8: Voting power is independent of reward token decimals
     * @dev Ensures voting power only depends on staking token, not reward tokens
     */
    function test_votingPower_independentOfRewardTokenDecimals() public {
        console2.log('\n=== Test Vector 8: Voting Power Independent of Reward Decimals ===');

        // User stakes
        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        // Wait 30 days
        vm.warp(block.timestamp + 30 days);

        // Check voting power BEFORE any rewards
        uint256 votingPowerBefore = staking.getVotingPower(user1);
        console2.log('Voting power before rewards:', votingPowerBefore);

        // Distribute rewards in all three decimals
        usdc.mint(address(staking), 1_000 * 1e6);
        wbtc.mint(address(staking), 1 * 1e8);
        dai.mint(address(staking), 1_000 * 1e18);

        staking.accrueRewards(address(usdc));
        staking.accrueRewards(address(wbtc));
        staking.accrueRewards(address(dai));

        // Check voting power AFTER rewards
        uint256 votingPowerAfter = staking.getVotingPower(user1);
        console2.log('Voting power after rewards:', votingPowerAfter);

        // Voting power should be unchanged
        assertEq(
            votingPowerBefore,
            votingPowerAfter,
            'Voting power should not change with reward distribution'
        );

        // Expected: ~30,000 (1,000 tokens × 30 days)
        assertApproxEqRel(votingPowerAfter, 30_000, 0.01e18, 'Voting power should be ~30,000');

        console2.log('[OK] Voting power is independent of reward token decimals');
    }

    /**
     * @notice Test Vector 9: Dust amounts with low decimal tokens
     * @dev Tests precision/truncation with very small reward amounts
     */
    function test_rewardDistribution_dustAmounts_lowDecimals() public {
        console2.log('\n=== Test Vector 9: Dust Amounts (Low Decimals) ===');

        // Multiple stakers
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

        console2.log('3 users staked 1,000 tokens each');

        // Distribute VERY SMALL amount of 6-decimal token (1 USDC)
        uint256 dustReward = 1 * 1e6; // 1 USDC across 3 stakers
        usdc.mint(address(staking), dustReward);
        staking.accrueRewards(address(usdc));

        vm.warp(block.timestamp + 7 days);

        uint256 claimable1 = staking.claimableRewards(user1, address(usdc));
        uint256 claimable2 = staking.claimableRewards(user2, address(usdc));
        uint256 claimable3 = staking.claimableRewards(user3, address(usdc));

        console2.log('User1 claimable (raw):', claimable1);
        console2.log('User2 claimable (raw):', claimable2);
        console2.log('User3 claimable (raw):', claimable3);

        // Each should get ~0.333 USDC (333333 units in 6 decimals)
        // With precision loss, they should still get non-zero amounts
        assertGt(claimable1, 0, 'User1 should get non-zero dust reward');
        assertGt(claimable2, 0, 'User2 should get non-zero dust reward');
        assertGt(claimable3, 0, 'User3 should get non-zero dust reward');

        // Total claimed should be very close to total distributed (allowing for dust loss)
        uint256 totalClaimable = claimable1 + claimable2 + claimable3;
        console2.log('Total claimable:', totalClaimable);
        console2.log('Original reward:', dustReward);
        
        // Allow up to 1% loss due to rounding in streaming/distribution
        assertApproxEqRel(totalClaimable, dustReward, 0.01e18, 'Most dust should be distributed');

        console2.log('[OK] Dust amounts handled correctly with low decimals');
    }

    /**
     * @notice Test Vector 10: Indivisible reward amounts (precision loss)
     * @dev Tests what happens when reward amount doesn't divide evenly
     */
    function test_rewardDistribution_indivisibleAmounts() public {
        console2.log('\n=== Test Vector 10: Indivisible Reward Amounts ===');

        // 3 stakers with equal stakes
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

        console2.log('3 users staked 1,000 tokens each (equal stakes)');

        // Distribute 100 USDC (6 decimals) - doesn't divide evenly by 3
        // 100e6 / 3 = 33.333333... USDC per user
        uint256 indivisibleReward = 100 * 1e6;
        usdc.mint(address(staking), indivisibleReward);
        staking.accrueRewards(address(usdc));

        vm.warp(block.timestamp + 7 days);

        uint256 claimable1 = staking.claimableRewards(user1, address(usdc));
        uint256 claimable2 = staking.claimableRewards(user2, address(usdc));
        uint256 claimable3 = staking.claimableRewards(user3, address(usdc));

        console2.log('User1 claimable USDC:', claimable1);
        console2.log('User2 claimable USDC:', claimable2);
        console2.log('User3 claimable USDC:', claimable3);

        // Each user should get approximately 33.33 USDC
        uint256 expectedPerUser = indivisibleReward / 3;
        assertApproxEqAbs(claimable1, expectedPerUser, 1e5, 'User1 gets ~33.33 USDC');
        assertApproxEqAbs(claimable2, expectedPerUser, 1e5, 'User2 gets ~33.33 USDC');
        assertApproxEqAbs(claimable3, expectedPerUser, 1e5, 'User3 gets ~33.33 USDC');

        // Verify total distribution (allowing for small precision loss)
        uint256 totalClaimable = claimable1 + claimable2 + claimable3;
        console2.log('Total claimable:', totalClaimable);
        console2.log('Original reward:', indivisibleReward);
        
        // Should distribute nearly all rewards (within 1%)
        assertApproxEqRel(totalClaimable, indivisibleReward, 0.01e18, 'Nearly all rewards distributed');

        // Claim to verify actual transfers work
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(user1);
        staking.claimRewards(tokens, user1);
        vm.prank(user2);
        staking.claimRewards(tokens, user2);
        vm.prank(user3);
        staking.claimRewards(tokens, user3);

        uint256 totalReceived = usdc.balanceOf(user1) + usdc.balanceOf(user2) + usdc.balanceOf(user3);
        console2.log('Total actually received:', totalReceived);
        
        assertApproxEqRel(totalReceived, indivisibleReward, 0.01e18, 'All rewards claimed successfully');

        console2.log('[OK] Indivisible amounts handled with minimal precision loss');
    }

    /**
     * @notice Test Vector 11: Late staking (no retroactive rewards)
     * @dev Ensures users who stake after reward distribution don't get historical rewards
     */
    function test_rewardDistribution_lateStaking_noRetroactive() public {
        console2.log('\n=== Test Vector 11: Late Staking (No Retroactive Rewards) ===');

        // User1 stakes early
        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);
        stakingToken.mint(user2, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 stakes: 1,000 tokens');

        // First reward distribution (only User1 staked)
        uint256 reward1 = 1_000 * 1e6; // 1,000 USDC
        usdc.mint(address(staking), reward1);
        staking.accrueRewards(address(usdc));

        console2.log('First reward: 1,000 USDC distributed');

        // Wait for rewards to vest
        vm.warp(block.timestamp + 7 days);

        // User1 should be able to claim all of first reward
        uint256 user1Claimable1 = staking.claimableRewards(user1, address(usdc));
        console2.log('User1 claimable after first reward:', user1Claimable1 / 1e6);
        assertApproxEqRel(user1Claimable1, reward1, 0.01e18, 'User1 gets all first reward');

        // NOW User2 stakes (late to the party)
        vm.prank(user2);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user2);
        staking.stake(stakeAmount);

        console2.log('\nUser2 stakes AFTER first reward: 1,000 tokens');

        // User2 should have ZERO claimable from first reward
        uint256 user2Claimable1 = staking.claimableRewards(user2, address(usdc));
        console2.log('User2 claimable from first reward:', user2Claimable1);
        assertEq(user2Claimable1, 0, 'User2 should NOT get retroactive rewards');

        // Second reward distribution (both users staked now)
        uint256 reward2 = 1_000 * 1e6; // Another 1,000 USDC
        usdc.mint(address(staking), reward2);
        staking.accrueRewards(address(usdc));

        console2.log('\nSecond reward: 1,000 USDC distributed');

        vm.warp(block.timestamp + 7 days);

        // Now check claimable for both users
        uint256 user1Claimable2 = staking.claimableRewards(user1, address(usdc));
        uint256 user2Claimable2 = staking.claimableRewards(user2, address(usdc));

        console2.log('User1 total claimable:', user1Claimable2 / 1e6);
        console2.log('User2 total claimable:', user2Claimable2 / 1e6);

        // User1 should have: ~1000 (first) + ~500 (half of second) = ~1500 USDC
        assertApproxEqRel(user1Claimable2, 1500 * 1e6, 0.01e18, 'User1 gets first + half of second');

        // User2 should have: ~500 (half of second only) = ~500 USDC
        assertApproxEqRel(user2Claimable2, 500 * 1e6, 0.01e18, 'User2 gets only half of second reward');

        // Claim and verify actual balances
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(user1);
        staking.claimRewards(tokens, user1);
        vm.prank(user2);
        staking.claimRewards(tokens, user2);

        console2.log('\nFinal balances:');
        console2.log('User1 USDC:', usdc.balanceOf(user1) / 1e6);
        console2.log('User2 USDC:', usdc.balanceOf(user2) / 1e6);

        assertApproxEqRel(usdc.balanceOf(user1), 1500 * 1e6, 0.01e18, 'User1 received correct total');
        assertApproxEqRel(usdc.balanceOf(user2), 500 * 1e6, 0.01e18, 'User2 received only new rewards');

        console2.log('[OK] Late staking does not grant retroactive rewards');
    }

    /**
     * @notice Test Vector 12: Extreme dust with 2-decimal token
     * @dev Tests the absolute minimum reward scenario with lowest decimal token
     *      NOTE: With streaming over 7 days, we need enough rewards to not round to zero
     */
    function test_rewardDistribution_extremeDust_2Decimals() public {
        console2.log('\n=== Test Vector 12: Extreme Dust (2 decimals) ===');

        // Deploy 2-decimal token
        MockERC20WithDecimals gusd = new MockERC20WithDecimals('GUSD', 'GUSD', 2);
        vm.prank(tokenAdmin);
        staking.whitelistToken(address(gusd));

        // 10 stakers with equal stakes
        address[] memory users = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(1000 + i));
            stakingToken.mint(users[i], 1_000 * 1e18);
            
            vm.prank(users[i]);
            stakingToken.approve(address(staking), 1_000 * 1e18);
            vm.prank(users[i]);
            staking.stake(1_000 * 1e18);
        }

        console2.log('10 users staked 1,000 tokens each');

        // Distribute 100 GUSD (100 * 1e2) across 10 stakers
        // Expected: ~10 GUSD per user (10e2 units)
        // With streaming over 7 days, this should still be distributable
        uint256 minimalReward = 100 * 1e2;
        gusd.mint(address(staking), minimalReward);
        staking.accrueRewards(address(gusd));

        vm.warp(block.timestamp + 7 days);

        console2.log('Distributed 100 GUSD across 10 users');

        // Check each user gets their share
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 claimable = staking.claimableRewards(users[i], address(gusd));
            totalClaimable += claimable;
            
            if (i < 3) {
                console2.log('User', i, 'claimable:', claimable);
            }
            
            // Each should get approximately 10 GUSD (1000 units in 2 decimals)
            assertGt(claimable, 0, 'User should get non-zero reward');
        }

        console2.log('Total claimable:', totalClaimable);
        console2.log('Original reward:', minimalReward);

        // Should distribute most of the rewards (allowing for minimal precision loss)
        assertApproxEqRel(totalClaimable, minimalReward, 0.02e18, 'Most minimal rewards distributed');

        console2.log('[OK] Extreme dust with 2-decimal tokens handled correctly');
        console2.log('[NOTE] Amounts below ~100 units with streaming may experience significant rounding');
    }
}
