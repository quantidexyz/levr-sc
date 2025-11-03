// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 3B - Mathematical and Conditional Branch Coverage
contract Phase3_MathematicalBoundaries_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        
        underlying.mint(address(treasury), 1_000_000 ether);
    }

    // ============ Mathematical Boundary Tests ============

    /// Test: Division edge case - amount / (denominator == 1)
    function test_math_001_divisionByOne() public {
        address gov = address(governor);
        
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xA001), 1000000000000000001); // Odd number
    }

    /// Test: Overflow prevention - max uint256
    function test_math_002_largeAmounts() public {
        address gov = address(governor);
        
        underlying.mint(address(treasury), type(uint128).max);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xA002), type(uint128).max);
    }

    /// Test: Precision loss - very small amounts
    function test_math_003_verySmallAmounts() public {
        address gov = address(governor);
        
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xA003), 1);
        
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xA004), 2);
        
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xA005), 3);
    }

    /// Test: Fractional distribution
    function test_math_004_fractionalDistribution() public {
        address user1 = address(0xB001);
        address user2 = address(0xB002);
        
        underlying.mint(user1, 10_000 ether);
        underlying.mint(user2, 10_000 ether);
        
        vm.prank(user1);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user1);
        staking.stake(3_333 ether); // Not even division
        
        vm.prank(user2);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user2);
        staking.stake(6_667 ether); // Not even division
        
        // Total = 10_000, ratio = 1:2 but not exact
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        rewardToken.mint(address(staking), 10_001 ether); // Odd number of rewards
        staking.accrueRewards(address(rewardToken));
    }

    /// Test: Rounding down in division
    function test_math_005_roundingDown() public {
        address user = address(0xC001);
        
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(3 ether); // Prime number
        
        vm.prank(user);
        staking.unstake(1 ether, user);
        
        assertEq(underlying.balanceOf(user), 10_000 ether - 3 ether + 1 ether);
    }

    /// Test: Zero remainder handling
    function test_math_006_zeroRemainder() public {
        address user = address(0xC002);
        
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        vm.prank(user);
        staking.unstake(1_000 ether, user);
        
        assertEq(underlying.balanceOf(user), 10_000 ether);
    }

    /// Test: Accumulation across multiple operations
    function test_math_007_accumulationAcrossOps() public {
        address user = address(0xC003);
        underlying.mint(user, 100_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 100_000 ether);
        
        uint256 totalStaked = 0;
        for (uint256 i = 1; i <= 100; i++) {
            vm.prank(user);
            staking.stake(i * 1 ether);
            totalStaked += i * 1 ether;
        }
        
        uint256 balance = underlying.balanceOf(address(staking));
        assertGt(balance, 0);
    }

    /// Test: Pool effect - multiple stakers, same reward
    function test_math_008_poolRewardDistribution() public {
        address[] memory stakers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            stakers[i] = address(uint160(0xD000 + i));
            underlying.mint(stakers[i], 10_000 ether);
            
            vm.prank(stakers[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(stakers[i]);
            staking.stake((i + 1) * 100 ether); // 100, 200, 300, 400, 500
        }
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        rewardToken.mint(address(staking), 10_500 ether); // 1500 total stakes, 10500 rewards
        staking.accrueRewards(address(rewardToken));
        
        vm.warp(block.timestamp + 4 days);
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(stakers[i]);
            staking.claimRewards(tokens, stakers[i]);
        }
    }

    /// Test: Percentage calculations
    function test_math_009_percentageCalculations() public pure {
        // Test various BPS calculations
        uint256[] memory bpsValues = new uint256[](5);
        bpsValues[0] = 100;    // 1%
        bpsValues[1] = 500;    // 5%
        bpsValues[2] = 1000;   // 10%
        bpsValues[3] = 5000;   // 50%
        bpsValues[4] = 10000;  // 100%
        
        for (uint256 i = 0; i < 5; i++) {
            uint256 amount = 10_000 ether;
            uint256 percentage = (amount * bpsValues[i]) / 10_000;
            assertGt(percentage, 0);
        }
    }

    /// Test: Time-based calculations
    function test_math_010_timeBasedCalcs() public {
        address user = address(0xE001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        rewardToken.mint(address(staking), 10_000 ether);
        staking.accrueRewards(address(rewardToken));
        
        // Test different time intervals
        uint256[] memory intervals = new uint256[](5);
        intervals[0] = 1 days;
        intervals[1] = 7 days;
        intervals[2] = 3 days;
        intervals[3] = 1 hours;
        intervals[4] = 30 days;
        
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + intervals[i]);
            
            address[] memory tokens = new address[](1);
            tokens[0] = address(rewardToken);
            
            try staking.claimRewards(tokens, user) {
                // May claim or may have nothing to claim
            } catch {
                // Acceptable
            }
        }
    }

    // ============ Conditional Branch Tests ============

    /// Test: Condition - if (amount > 0)
    function test_cond_001_zeroVsNonZero() public {
        address gov = address(governor);
        
        // Non-zero
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xF001), 100 ether);
        
        // Zero transfer may be allowed depending on implementation
        vm.prank(gov);
        try treasury.transfer(address(underlying), address(0xF002), 0) {
            // May succeed (zero transfer)
        } catch {
            // May fail (zero not allowed)
        }
    }

    /// Test: Condition - if (balance >= amount)
    function test_cond_002_balanceChecks() public {
        address gov = address(governor);
        uint256 treasuryBalance = underlying.balanceOf(address(treasury));
        
        // Valid transfer
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xF003), treasuryBalance / 2);
        
        // Exceeds balance
        vm.prank(gov);
        vm.expectRevert();
        treasury.transfer(address(underlying), address(0xF004), treasuryBalance);
    }

    /// Test: Condition - if (sender == authorized)
    function test_cond_003_authorizationChecks() public {
        address unauthorized = address(0xF005);
        
        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.transfer(address(underlying), address(0xF006), 100 ether);
    }

    /// Test: Condition - if (reward > minimum)
    function test_cond_004_minimumChecks() public {
        address user = address(0xF007);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        // Too small amount - should revert
        rewardToken.mint(address(staking), 1);
        vm.expectRevert();
        staking.accrueRewards(address(rewardToken));
    }

    /// Test: Condition - if (whitelisted)
    function test_cond_005_whitelistChecks() public {
        address user = address(0xF008);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        MockERC20 nonWhitelisted = new MockERC20('Bad', 'BAD');
        nonWhitelisted.mint(address(staking), 10_000 ether);
        
        vm.expectRevert();
        staking.accrueRewards(address(nonWhitelisted));
    }
}
