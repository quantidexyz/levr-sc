// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactoryDeployHelper} from "../../utils/LevrFactoryDeployHelper.sol";
import {console2} from 'forge-std/console2.sol';

import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../../src/interfaces/ILevrStaking_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @notice Mock ERC20 with custom decimals for testing
 */
contract MockERC20WithDecimals is ERC20 {
    uint8 private immutable _decimals;
    address private immutable _admin;

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
 * @notice POC tests for Sherlock #24 - Staking won't work for low decimals tokens
 * @dev Tests validate that the token-aware precision fix allows staking to work
 *      correctly for tokens with various decimals (6, 8, 18) and provides fair voting power.
 */
contract LevrStakingLowDecimalsTest is Test, LevrFactoryDeployHelper {
    MockFactoryWithConfig public factory;
    LevrStaking_v1 public staking6; // USDC (6 decimals)
    LevrStaking_v1 public staking8; // WBTC (8 decimals)
    LevrStaking_v1 public staking18; // DAI (18 decimals)

    LevrStakedToken_v1 public stakedToken6;
    LevrStakedToken_v1 public stakedToken8;
    LevrStakedToken_v1 public stakedToken18;

    MockERC20WithDecimals public usdc; // 6 decimals
    MockERC20WithDecimals public wbtc; // 8 decimals
    MockERC20WithDecimals public dai; // 18 decimals

    address public trustedForwarder = makeAddr('trustedForwarder');
    address public treasury = makeAddr('treasury');
    address public user1 = makeAddr('user1');
    address public user2 = makeAddr('user2');
    address public user3 = makeAddr('user3');
    address public rewardAdmin = makeAddr('rewardAdmin');

    function setUp() public {
        console2.log('=== Sherlock #24: Low Decimals Token POC Setup ===');

        // Deploy mock factory
        factory = new MockFactoryWithConfig();

        // Deploy mock tokens with different decimals
        usdc = new MockERC20WithDecimals('USDC', 'USDC', 6);
        wbtc = new MockERC20WithDecimals('WBTC', 'WBTC', 8);
        dai = new MockERC20WithDecimals('DAI', 'DAI', 18);

        console2.log('USDC (6 decimals):', address(usdc));
        console2.log('WBTC (8 decimals):', address(wbtc));
        console2.log('DAI (18 decimals):', address(dai));

        // Deploy staking contracts
        staking6 = new LevrStaking_v1(trustedForwarder, address(factory));
        staking8 = new LevrStaking_v1(trustedForwarder, address(factory));
        staking18 = new LevrStaking_v1(trustedForwarder, address(factory));

        // Deploy staked tokens
        stakedToken6 = createStakedToken('Staked USDC', 'sUSDC', 6, address(usdc), address(staking6));
        stakedToken8 = createStakedToken('Staked WBTC', 'sWBTC', 8, address(wbtc), address(staking8));
        stakedToken18 = createStakedToken('Staked DAI', 'sDAI', 18, address(dai), address(staking18));

        // Initialize staking contracts
        address[] memory emptyWhitelist = new address[](0);

        vm.prank(address(factory));
        staking6.initialize(address(usdc), address(stakedToken6), treasury, emptyWhitelist);

        vm.prank(address(factory));
        staking8.initialize(address(wbtc), address(stakedToken8), treasury, emptyWhitelist);

        vm.prank(address(factory));
        staking18.initialize(address(dai), address(stakedToken18), treasury, emptyWhitelist);

        console2.log('\n=== Precision Values After Initialization ===');
        console2.log('USDC staking - decimals:', staking6.underlyingDecimals());
        console2.log('USDC staking - precision:', staking6.precision());
        console2.log('USDC min reward (precision/1000):', staking6.precision() / 1000);

        console2.log('WBTC staking - decimals:', staking8.underlyingDecimals());
        console2.log('WBTC staking - precision:', staking8.precision());
        console2.log('WBTC min reward (precision/1000):', staking8.precision() / 1000);

        console2.log('DAI staking - decimals:', staking18.underlyingDecimals());
        console2.log('DAI staking - precision:', staking18.precision());
        console2.log('DAI min reward (precision/1000):', staking18.precision() / 1000);
    }

    /**
     * @notice Test Vector 1: Voting power works for 6-decimal tokens (USDC)
     * @dev Before fix: votingPower would be 0 (truncation)
     *      After fix: votingPower should be proportional to amount and time
     */
    function test_votingPower_6DecimalToken_USDC() public {
        console2.log('\n=== Test Vector 1: USDC (6 decimals) Voting Power ===');

        // User stakes 1,000 USDC (6 decimals = 1,000 * 1e6)
        uint256 stakeAmount = 1_000 * 1e6;
        console2.log('Stake amount (USDC):', stakeAmount / 1e6);

        usdc.mint(user1, stakeAmount);

        vm.startPrank(user1);
        usdc.approve(address(staking6), stakeAmount);
        staking6.stake(stakeAmount);
        vm.stopPrank();

        // Wait 30 days
        uint256 timeStaked = 30 days;
        vm.warp(block.timestamp + timeStaked);

        // Check voting power
        uint256 votingPower = staking6.getVotingPower(user1);

        console2.log('Time staked (days):', timeStaked / 1 days);
        console2.log('Voting power:', votingPower);

        // Expected: ~30,000 (1,000 tokens × 30 days)
        // With normalization: balance = 1,000 * 1e6 → normalized = 1,000 * 1e18
        // VP = (1,000 * 1e18 * 30 days) / (1e18 * 86400) = 30,000

        assertGt(votingPower, 0, 'Voting power should not be zero');
        assertApproxEqRel(votingPower, 30_000, 0.01e18, 'Voting power should be ~30,000');

        console2.log('[OK] USDC voting power works correctly');
    }

    /**
     * @notice Test Vector 2: Voting power works for 8-decimal tokens (WBTC)
     * @dev Before fix: votingPower would be 0 (truncation)
     *      After fix: votingPower should be proportional to amount and time
     */
    function test_votingPower_8DecimalToken_WBTC() public {
        console2.log('\n=== Test Vector 2: WBTC (8 decimals) Voting Power ===');

        // User stakes 1 WBTC (8 decimals = 1 * 1e8)
        uint256 stakeAmount = 1 * 1e8;
        console2.log('Stake amount (WBTC):', stakeAmount / 1e8);

        wbtc.mint(user2, stakeAmount);

        vm.startPrank(user2);
        wbtc.approve(address(staking8), stakeAmount);
        staking8.stake(stakeAmount);
        vm.stopPrank();

        // Wait 60 days
        uint256 timeStaked = 60 days;
        vm.warp(block.timestamp + timeStaked);

        // Check voting power
        uint256 votingPower = staking8.getVotingPower(user2);

        console2.log('Time staked (days):', timeStaked / 1 days);
        console2.log('Voting power:', votingPower);

        // Expected: ~60 (1 token × 60 days)
        // With normalization: balance = 1 * 1e8 → normalized = 1 * 1e18
        // VP = (1 * 1e18 * 60 days) / (1e18 * 86400) = 60

        assertGt(votingPower, 0, 'Voting power should not be zero');
        assertApproxEqRel(votingPower, 60, 0.01e18, 'Voting power should be ~60');

        console2.log('[OK] WBTC voting power works correctly');
    }

    /**
     * @notice Test Vector 3: Voting power still works for 18-decimal tokens (DAI) - Regression test
     * @dev Ensures the fix doesn't break existing 18-decimal token functionality
     */
    function test_votingPower_18DecimalToken_DAI_Regression() public {
        console2.log('\n=== Test Vector 3: DAI (18 decimals) Voting Power - Regression ===');

        // User stakes 1,000 DAI (18 decimals = 1,000 * 1e18)
        uint256 stakeAmount = 1_000 * 1e18;
        console2.log('Stake amount (DAI):', stakeAmount / 1e18);

        dai.mint(user3, stakeAmount);

        vm.startPrank(user3);
        dai.approve(address(staking18), stakeAmount);
        staking18.stake(stakeAmount);
        vm.stopPrank();

        // Wait 30 days
        uint256 timeStaked = 30 days;
        vm.warp(block.timestamp + timeStaked);

        // Check voting power
        uint256 votingPower = staking18.getVotingPower(user3);

        console2.log('Time staked (days):', timeStaked / 1 days);
        console2.log('Voting power:', votingPower);

        // Expected: ~30,000 (1,000 tokens × 30 days)
        // No normalization needed: balance = 1,000 * 1e18 (already 18 decimals)
        // VP = (1,000 * 1e18 * 30 days) / (1e18 * 86400) = 30,000

        assertGt(votingPower, 0, 'Voting power should not be zero');
        assertApproxEqRel(votingPower, 30_000, 0.01e18, 'Voting power should be ~30,000');

        console2.log('[OK] DAI voting power works correctly (regression passed)');
    }

    /**
     * @notice Test Vector 4: Fair voting power across different decimal types
     * @dev Ensures that 1,000 USDC = 1,000 DAI in terms of voting power
     */
    function test_fairVotingPower_acrossDecimals() public {
        console2.log('\n=== Test Vector 4: Fair Voting Power Across Decimals ===');

        // Stake equivalent amounts: 1,000 tokens each
        uint256 amount6 = 1_000 * 1e6; // USDC
        uint256 amount8 = 1_000 * 1e8; // WBTC
        uint256 amount18 = 1_000 * 1e18; // DAI

        // Mint and stake
        usdc.mint(user1, amount6);
        wbtc.mint(user2, amount8);
        dai.mint(user3, amount18);

        vm.prank(user1);
        usdc.approve(address(staking6), amount6);
        vm.prank(user1);
        staking6.stake(amount6);

        vm.prank(user2);
        wbtc.approve(address(staking8), amount8);
        vm.prank(user2);
        staking8.stake(amount8);

        vm.prank(user3);
        dai.approve(address(staking18), amount18);
        vm.prank(user3);
        staking18.stake(amount18);

        // Wait 30 days for all
        vm.warp(block.timestamp + 30 days);

        // Get voting powers
        uint256 power6 = staking6.getVotingPower(user1);
        uint256 power8 = staking8.getVotingPower(user2);
        uint256 power18 = staking18.getVotingPower(user3);

        console2.log('USDC (6 decimals) voting power:', power6);
        console2.log('WBTC (8 decimals) voting power:', power8);
        console2.log('DAI (18 decimals) voting power:', power18);

        // All should be approximately 30,000 (1,000 tokens × 30 days)
        assertApproxEqRel(power6, 30_000, 0.01e18, 'USDC voting power should be ~30,000');
        assertApproxEqRel(power8, 30_000, 0.01e18, 'WBTC voting power should be ~30,000');
        assertApproxEqRel(power18, 30_000, 0.01e18, 'DAI voting power should be ~30,000');

        // Cross-comparison: all powers should be within 1% of each other
        assertApproxEqRel(power6, power8, 0.01e18, 'USDC and WBTC should have similar power');
        assertApproxEqRel(power6, power18, 0.01e18, 'USDC and DAI should have similar power');
        assertApproxEqRel(power8, power18, 0.01e18, 'WBTC and DAI should have similar power');

        console2.log('[OK] Fair voting power across all decimal types verified');
    }

    /**
     * @notice Test Vector 5: Reward addition works for low-decimal tokens
     * @dev Before fix: MIN_REWARD_AMOUNT = 1e15 would require 1 billion USDC
     *      After fix: minRewardAmount = precision/1000 = 0.001 USDC
     */
    function test_addReward_6DecimalToken() public {
        console2.log('\n=== Test Vector 5: Reward Addition for 6-Decimal Token ===');

        // Setup: Need some stakers first
        uint256 stakeAmount = 10_000 * 1e6; // 10,000 USDC
        usdc.mint(user1, stakeAmount);

        vm.prank(user1);
        usdc.approve(address(staking6), stakeAmount);
        vm.prank(user1);
        staking6.stake(stakeAmount);

        // Protocol wants to add 1,000 USDC rewards
        uint256 rewardAmount = 1_000 * 1e6;
        console2.log('Reward amount (USDC):', rewardAmount / 1e6);
        console2.log('Min reward (precision):', staking6.precision());

        // Mint rewards to staking contract
        usdc.mint(address(staking6), rewardAmount);

        // Should NOT revert (realistic amount for 6-decimal token)
        vm.prank(rewardAdmin);
        staking6.accrueRewards(address(usdc));

        console2.log('[OK] Reward addition succeeded for 6-decimal token');

        // Verify rewards were accrued
        uint256 outstanding = staking6.outstandingRewards(address(usdc));
        console2.log('Outstanding rewards after accrual:', outstanding);
        assertEq(outstanding, 0, 'All rewards should be accrued');
    }

    /**
     * @notice Test Vector 6: Edge case - 2 decimal token
     * @dev Tests extremely low decimal tokens
     */
    function test_votingPower_2DecimalToken() public {
        console2.log('\n=== Test Vector 6: 2-Decimal Token (Edge Case) ===');

        // Deploy 2-decimal token (e.g., Gemini USD)
        MockERC20WithDecimals gusd = new MockERC20WithDecimals('GUSD', 'GUSD', 2);

        LevrStaking_v1 stakingGusd = new LevrStaking_v1(trustedForwarder, address(factory));

        LevrStakedToken_v1 stakedGusd = createStakedToken('Staked GUSD', 'sGUSD', 2, address(gusd), address(stakingGusd));

        address[] memory emptyWhitelist = new address[](0);
        vm.prank(address(factory));
        stakingGusd.initialize(address(gusd), address(stakedGusd), treasury, emptyWhitelist);

        // User stakes 10,000 GUSD (2 decimals = 10,000 * 1e2)
        uint256 stakeAmount = 10_000 * 1e2;
        console2.log('Stake amount (GUSD):', stakeAmount / 1e2);

        gusd.mint(user1, stakeAmount);

        vm.startPrank(user1);
        gusd.approve(address(stakingGusd), stakeAmount);
        stakingGusd.stake(stakeAmount);
        vm.stopPrank();

        // Wait 90 days
        vm.warp(block.timestamp + 90 days);

        // Check voting power
        uint256 votingPower = stakingGusd.getVotingPower(user1);

        console2.log('Voting power:', votingPower);
        console2.log('Expected: 900,000 (10,000 tokens x 90 days)');

        // Should have voting power (not zero)
        assertGt(votingPower, 0, 'Even 2-decimal tokens should have voting power');
        assertApproxEqRel(votingPower, 900_000, 0.01e18, 'Voting power should be ~900,000');

        console2.log('[OK] 2-decimal token voting power works');
    }

    /**
     * @notice Test Vector 7: Minimum reward is precision/1000 (0.001 tokens)
     * @dev Tests that precision is correctly set and min reward is reasonable
     */
    function test_precision_and_minReward() public view {
        console2.log('\n=== Test Vector 7: Precision & Min Reward (0.001 tokens) ===');

        // Check precision
        uint256 prec6 = staking6.precision();
        uint256 prec8 = staking8.precision();
        uint256 prec18 = staking18.precision();

        console2.log('USDC precision:', prec6, '| Min reward:', prec6 / 1000);
        console2.log('WBTC precision:', prec8, '| Min reward:', prec8 / 1000);
        console2.log('DAI precision:', prec18, '| Min reward:', prec18 / 1000);

        // Precision should equal 10^decimals
        assertEq(prec6, 1e6, 'USDC precision should be 1e6');
        assertEq(prec8, 1e8, 'WBTC precision should be 1e8');
        assertEq(prec18, 1e18, 'DAI precision should be 1e18');

        // Min reward (calculated inline) should be 0.001 tokens
        assertEq(prec6 / 1000, 1000, 'USDC min = 0.001 USDC');
        assertEq(prec8 / 1000, 100000, 'WBTC min = 0.001 WBTC');
        assertEq(prec18 / 1000, 1e15, 'DAI min = 0.001 DAI = 1e15');

        console2.log('[OK] Precision correct, min reward = precision/1000');
    }

    /**
     * @notice Test Vector 8: Unstake preserves voting power calculation
     * @dev Tests that the voting power calculation in unstake() also uses normalized balance
     */
    function test_unstake_votingPowerCalculation_6Decimals() public {
        console2.log('\n=== Test Vector 8: Unstake Voting Power Calculation (6 decimals) ===');

        // User stakes 10,000 USDC
        uint256 stakeAmount = 10_000 * 1e6;
        usdc.mint(user1, stakeAmount);

        vm.startPrank(user1);
        usdc.approve(address(staking6), stakeAmount);
        staking6.stake(stakeAmount);

        // Wait 30 days
        vm.warp(block.timestamp + 30 days);

        // Unstake half (5,000 USDC)
        uint256 unstakeAmount = 5_000 * 1e6;
        uint256 newVotingPower = staking6.unstake(unstakeAmount, user1);
        vm.stopPrank();

        console2.log('Remaining stake (USDC):', (stakeAmount - unstakeAmount) / 1e6);
        console2.log('New voting power after unstake:', newVotingPower);

        // Should have non-zero voting power after partial unstake
        assertGt(newVotingPower, 0, 'Should have voting power after partial unstake');

        // Verify it matches getVotingPower()
        uint256 currentVotingPower = staking6.getVotingPower(user1);
        assertEq(
            newVotingPower,
            currentVotingPower,
            'Unstake return value should match getVotingPower'
        );

        console2.log('[OK] Unstake voting power calculation works for 6-decimal tokens');
    }
}
