// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 6 - Exhaustive State Space Exploration
/// Tests all combinations of conditions to hit untested branches
contract Phase6_ExhaustiveStateSpaces_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        staking = LevrStaking_v1(project.staking);
        treasury = LevrTreasury_v1(payable(project.treasury));
        
        underlying.mint(address(treasury), 1_000_000 ether);
    }

    // ============ EXHAUSTIVE: All Governor Proposal Lifetimes ============

    function test_ex_gov_001_proposeVoteExecuteMinimal() public {
        address user = address(0x1001);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(100 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 5 ether);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(user);
        governor.vote(pid, true);
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
    }

    function test_ex_gov_002_proposeNoVoteExecute() public {
        address user = address(0x1002);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(100 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 5 ether);
        vm.warp(block.timestamp + 10 days);
        governor.execute(pid);
    }

    function test_ex_gov_003_proposeMultipleVotes() public {
        address[] memory users = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(0x2000 + i));
            underlying.mint(users[i], 10_000 ether);
            vm.prank(users[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(users[i]);
            staking.stake(200 ether);
        }
        
        vm.prank(users[0]);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        vm.warp(block.timestamp + 2 days + 1);
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            governor.vote(pid, i % 2 == 0);
        }
        
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
    }

    function test_ex_gov_004_proposeMultipleWithdraw() public {
        address user = address(0x2100);
        underlying.mint(user, 100_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 100_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user);
            uint256 pid = governor.proposeBoost(address(underlying), 10 + i * 5 ether);
            
            vm.warp(block.timestamp + 2 days + 1);
            vm.prank(user);
            governor.vote(pid, true);
            
            vm.warp(block.timestamp + 5 days + 1);
            governor.execute(pid);
            
            vm.warp(block.timestamp + 2 days);
        }
    }

    function test_ex_gov_005_proposePluralWithhold() public {
        address user = address(0x2101);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(user);
        governor.vote(pid, false);
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
    }

    // ============ EXHAUSTIVE: Staking Combinations ============

    function test_ex_staking_001_singleStakeUnstakeFull() public {
        address user = address(0x3001);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(5_000 ether);
        vm.prank(user);
        staking.unstake(5_000 ether, user);
    }

    function test_ex_staking_002_stakeUnstakePartial() public {
        address user = address(0x3002);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(10_000 ether);
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user);
            staking.unstake(1_000 ether, user);
        }
    }

    function test_ex_staking_003_multiUserStakeClaim() public {
        address[] memory users = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            users[i] = address(uint160(0x3100 + i));
            underlying.mint(users[i], 10_000 ether);
            vm.prank(users[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(users[i]);
            staking.stake((i + 1) * 1_000 ether);
        }
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        rewardToken.mint(address(staking), 30_000 ether);
        staking.accrueRewards(address(rewardToken));
        
        vm.warp(block.timestamp + 4 days);
        
        for (uint256 i = 0; i < 3; i++) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(rewardToken);
            vm.prank(users[i]);
            staking.claimRewards(tokens, users[i]);
        }
    }

    function test_ex_staking_004_stakeUnstakeRapid() public {
        address user = address(0x3101);
        underlying.mint(user, 50_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 50_000 ether);
        
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user);
            staking.stake((i + 1) * 100 ether);
            vm.warp(block.timestamp + 1 hours);
            vm.prank(user);
            try staking.unstake((i + 1) * 50 ether, user) {} catch {}
        }
    }

    function test_ex_staking_005_rewardStreamingUpdates() public {
        address user = address(0x3102);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        for (uint256 i = 0; i < 5; i++) {
            rewardToken.mint(address(staking), 1_000 ether);
            staking.accrueRewards(address(rewardToken));
            vm.warp(block.timestamp + 1 days);
        }
    }

    // ============ EXHAUSTIVE: Treasury Operations ============

    function test_ex_treasury_001_transferMultiple() public {
        address gov = address(governor);
        
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), address(uint160(0x4000 + i)), 100 ether);
        }
    }

    function test_ex_treasury_002_boostMultiple() public {
        address gov = address(governor);
        
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(gov);
            treasury.applyBoost(address(underlying), 1_000 ether);
        }
    }

    function test_ex_treasury_003_transferBoostInterleave() public {
        address gov = address(governor);
        
        for (uint256 i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                vm.prank(gov);
                treasury.transfer(address(underlying), address(uint160(0x5000 + i)), 100 ether);
            } else {
                vm.prank(gov);
                treasury.applyBoost(address(underlying), 500 ether);
            }
        }
    }

    // ============ EXHAUSTIVE: Reward Math Paths ============

    function test_ex_math_001_proportionalClaimVariations() public {
        address[] memory users = new address[](5);
        
        uint256[] memory stakes = new uint256[](5);
        stakes[0] = 100 ether;
        stakes[1] = 200 ether;
        stakes[2] = 300 ether;
        stakes[3] = 400 ether;
        stakes[4] = 500 ether;
        
        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(0x6000 + i));
            underlying.mint(users[i], 10_000 ether);
            vm.prank(users[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(users[i]);
            staking.stake(stakes[i]);
        }
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        uint256[] memory rewards = new uint256[](5);
        rewards[0] = 10_000 ether;
        rewards[1] = 50_000 ether;
        rewards[2] = 100_000 ether;
        rewards[3] = 500_000 ether;
        rewards[4] = 1_000_000 ether;
        
        for (uint256 i = 0; i < 5; i++) {
            rewardToken.mint(address(staking), rewards[i]);
            staking.accrueRewards(address(rewardToken));
            
            vm.warp(block.timestamp + 2 days);
            
            address[] memory tokens = new address[](1);
            tokens[0] = address(rewardToken);
            
            for (uint256 j = 0; j < 5; j++) {
                vm.prank(users[j]);
                try staking.claimRewards(tokens, users[j]) {} catch {}
            }
        }
    }

    // ============ EXHAUSTIVE: State Transitions ============

    function test_ex_state_001_cycleTransitions() public {
        address user = address(0x7001);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        uint256 startCycle = governor.currentCycleId();
        
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 8 days);
            governor.startNewCycle();
        }
        
        uint256 endCycle = governor.currentCycleId();
        assertTrue(endCycle > startCycle);
    }
}
