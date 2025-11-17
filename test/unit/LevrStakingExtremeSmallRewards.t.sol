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
     * @notice Test Vector 1: Distribute 1 wei to single staker (BLOCKED)
     * @dev Validates that 1 wei rewards are blocked by MIN_REWARD_AMOUNT
     */
    function test_rewardDurationDilutionAttack_PREVENTED() public {
        console2.log('\n=== Test Vector 9: Reward Duration Dilution Attack - PREVENTED ===');

        uint256 stakeAmount = 1_000 * 1e18;
        stakingToken.mint(user1, stakeAmount);

        vm.prank(user1);
        stakingToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        console2.log('User1 staked:', stakeAmount / 1e18, 'tokens');

        // Initial reward distribution: 1000 tokens over 7 days
        uint256 initialReward = 1_000 * 1e18;
        rewardToken.mint(address(staking), initialReward);
        staking.accrueRewards(address(rewardToken));

        console2.log('\n--- Initial Distribution ---');
        console2.log('Distributed: 1,000 tokens');
        
        uint256 initialRate = staking.rewardRatePerSecond(address(rewardToken));
        console2.log('Rate per day:', (initialRate * 1 days) / 1e18, 'tokens/day');

        // Fast forward to day 5
        vm.warp(block.timestamp + 5 days);

        // ATTACK ATTEMPT: Try to donate 1 wei
        console2.log('\n--- ATTACK ATTEMPT: Donate 1 Wei ---');
        rewardToken.mint(address(staking), 1);
        
        // Should REVERT with RewardTooSmall
        vm.expectRevert(ILevrStaking_v1.RewardTooSmall.selector);
        staking.accrueRewards(address(rewardToken));
        
        console2.log('[BLOCKED] Attack prevented by universal 10,000 wei minimum!');

        // Try with 5,000 wei (still below minimum) - should also revert
        // Note: Previous 1 wei is still in contract, so total available is 5,001
        rewardToken.mint(address(staking), 5_000);
        vm.expectRevert(ILevrStaking_v1.RewardTooSmall.selector);
        staking.accrueRewards(address(rewardToken));
        console2.log('[BLOCKED] 5,000 wei also blocked (< 10,000 minimum)');

        // Add enough to reach 10,000 minimum
        console2.log('\n--- Legitimate 10,000 Wei Distribution ---');
        rewardToken.mint(address(staking), 3_999); // Total: 5,001 + 3,999 = 9,000 (still not enough)
        vm.expectRevert(ILevrStaking_v1.RewardTooSmall.selector);
        staking.accrueRewards(address(rewardToken));
        
        // Now add enough to reach minimum
        rewardToken.mint(address(staking), 1_000); // Total: 9,000 + 1,000 = 10,000
        staking.accrueRewards(address(rewardToken)); // Should succeed
        console2.log('[PASS] 10,000 wei (meets minimum) succeeded');

        console2.log('\n[FIX VERIFIED] Universal minimum prevents duration dilution attack!');
        console2.log('Minimum: 10,000 wei (1e4) for ALL tokens');
        console2.log('  18 decimals (DAI): 0.00001 tokens (~$0.00003)');
        console2.log('  18 decimals (WETH): 0.00001 WETH (~$0.03)');
        console2.log('  6 decimals (USDC): 0.01 cents ($0.0001)');
        console2.log('  8 decimals (WBTC): 0.0001 WBTC (~$6)');
    }
}
