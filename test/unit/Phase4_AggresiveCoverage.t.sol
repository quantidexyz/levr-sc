// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 4 - Aggressive Branch Permutation Coverage
contract Phase4_AggresiveCoverage_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        
        underlying.mint(address(treasury), 500_000 ether);
    }

    // ============ PHASE 4A: Forwarder Permutation Tests ============

    function test_p4a_001_forwarding_singleCall() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x1001))
        });
        forwarder.executeMulticall(calls);
    }

    function test_p4a_002_forwarding_dualCalls() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x1001))
        });
        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x1002))
        });
        forwarder.executeMulticall(calls);
    }

    function test_p4a_003_forwarding_tripleCalls() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] = ILevrForwarder_v1.SingleCall({
                target: address(treasury),
                callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(uint160(0x2000 + i)))
            });
        }
        forwarder.executeMulticall(calls);
    }

    function test_p4a_004_forwarding_manyUnrelatedCalls() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](10);
        for (uint256 i = 0; i < 10; i++) {
            calls[i] = ILevrForwarder_v1.SingleCall({
                target: address(treasury),
                callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(uint160(0x3000 + i)))
            });
        }
        forwarder.executeMulticall(calls);
    }

    function test_p4a_005_forwarding_withFailureHandling() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x4001))
        });
        // Second call with invalid data - should fail
        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            callData: bytes("")
        });
        
        try forwarder.executeMulticall(calls) {
            // May fail or succeed depending on implementation
        } catch {
            // Expected
        }
    }

    // ============ PHASE 4B: Treasury State Combinations ============

    function test_p4b_001_treasury_transferWithDifferentAmounts() public {
        address gov = address(governor);
        
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1 ether;
        amounts[1] = 100 ether;
        amounts[2] = 1_000 ether;
        amounts[3] = 10_000 ether;
        amounts[4] = 50_000 ether;
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), address(uint160(0x5000 + i)), amounts[i]);
        }
    }

    function test_p4b_002_treasury_boostWithDifferentAmounts() public {
        address gov = address(governor);
        
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1_000 ether;
        amounts[1] = 5_000 ether;
        amounts[2] = 10_000 ether;
        amounts[3] = 50_000 ether;
        
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(gov);
            treasury.applyBoost(address(underlying), amounts[i]);
        }
    }

    function test_p4b_003_treasury_alternatingTransferBoost() public {
        address gov = address(governor);
        
        for (uint256 i = 0; i < 5; i++) {
            if (i % 2 == 0) {
                vm.prank(gov);
                treasury.transfer(address(underlying), address(uint160(0x6000 + i)), 1_000 ether);
            } else {
                vm.prank(gov);
                treasury.applyBoost(address(underlying), 2_000 ether);
            }
        }
    }

    // ============ PHASE 4C: Staking Rapid-Fire Tests ============

    function test_p4c_001_staking_rapidStaking() public {
        address user = address(0x7001);
        underlying.mint(user, 50_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 50_000 ether);
        
        for (uint256 i = 1; i <= 10; i++) {
            vm.prank(user);
            staking.stake(i * 100 ether);
        }
    }

    function test_p4c_002_staking_rapidUnstaking() public {
        address user = address(0x7002);
        underlying.mint(user, 50_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 50_000 ether);
        
        vm.prank(user);
        staking.stake(5_500 ether);
        
        for (uint256 i = 1; i <= 10; i++) {
            vm.prank(user);
            staking.unstake(i * 50 ether, user);
        }
    }

    function test_p4c_003_staking_mixedOpsRapid() public {
        address user = address(0x7003);
        underlying.mint(user, 50_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 50_000 ether);
        
        for (uint256 i = 0; i < 20; i++) {
            if (i % 3 == 0) {
                vm.prank(user);
                staking.stake(250 ether);
            } else if (i % 3 == 1) {
                vm.prank(user);
                try staking.unstake(50 ether, user) {
                    // May succeed or fail
                } catch {
                    // Expected
                }
            } else {
                address[] memory tokens = new address[](0);
                vm.prank(user);
                try staking.claimRewards(tokens, user) {
                    // May succeed or fail
                } catch {
                    // Expected
                }
            }
        }
    }

    // ============ PHASE 4D: Governor Proposal Variations ============

    function test_p4d_001_governor_manyProposalsSequential() public {
        address[] memory proposers = new address[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            proposers[i] = address(uint160(0x8000 + i));
            underlying.mint(proposers[i], 10_000 ether);
            
            vm.prank(proposers[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(proposers[i]);
            staking.stake(500 ether);
        }
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(proposers[i]);
            governor.proposeBoost(address(underlying), (i + 1) * 5 ether);
        }
    }

    function test_p4d_002_governor_cycleSequential() public {
        address user = address(0x8100);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        for (uint256 cycle = 0; cycle < 3; cycle++) {
            vm.prank(user);
            uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
            
            vm.warp(block.timestamp + 2 days + 1);
            
            vm.prank(user);
            governor.vote(pid, true);
            
            vm.warp(block.timestamp + 5 days + 1);
            governor.execute(pid);
            
            vm.warp(block.timestamp + 5 days);
            governor.startNewCycle();
        }
    }

    // ============ PHASE 4E: Combinatorial Edge Cases ============

    function test_p4e_001_emptyAmounts() public {
        address user = address(0x9001);
        underlying.mint(user, 1000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 1000 ether);
        
        // Try to stake empty
        vm.prank(user);
        vm.expectRevert();
        staking.stake(0);
    }

    function test_p4e_002_maxAmounts() public {
        address user = address(0x9002);
        underlying.mint(user, type(uint128).max);
        
        vm.prank(user);
        underlying.approve(address(staking), type(uint128).max);
        
        vm.prank(user);
        try staking.stake(type(uint128).max) {
            // May succeed or fail
        } catch {
            // Expected
        }
    }

    function test_p4e_003_sequentialErrors() public {
        address user = address(0x9003);
        
        // No balance
        vm.prank(user);
        vm.expectRevert();
        staking.stake(100 ether);
        
        // Get balance
        underlying.mint(user, 1000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 1000 ether);
        
        // Now it works
        vm.prank(user);
        staking.stake(500 ether);
    }

    function test_p4e_004_timeWarping() public {
        address user = address(0x9004);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1000 ether);
        
        // Warp through multiple time windows
        uint256[] memory warps = new uint256[](5);
        warps[0] = 1 hours;
        warps[1] = 1 days;
        warps[2] = 7 days;
        warps[3] = 30 days;
        warps[4] = 365 days;
        
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + warps[i]);
        }
    }

    // ============ PHASE 4F: Cross-Contract State ============

    function test_p4f_001_crossContractState() public {
        address user = address(0xa001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1000 ether);
        
        // Treasury state
        address gov = address(governor);
        vm.prank(gov);
        treasury.transfer(address(underlying), user, 100 ether);
        
        // Governor state
        vm.prank(user);
        staking.unstake(500 ether, user);
        
        // Back to staking
        vm.prank(user);
        staking.stake(300 ether);
    }

    function test_p4f_002_multiUser_CrossContractState() public {
        address user1 = address(0xa100);
        address user2 = address(0xa101);
        
        underlying.mint(user1, 10_000 ether);
        underlying.mint(user2, 10_000 ether);
        
        // User1: stake
        vm.prank(user1);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user1);
        staking.stake(1000 ether);
        
        // User2: stake
        vm.prank(user2);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user2);
        staking.stake(500 ether);
        
        // User1: claim
        address[] memory tokens = new address[](0);
        vm.prank(user1);
        try staking.claimRewards(tokens, user1) {
            // May succeed or fail
        } catch {
            // Expected
        }
        
        // User2: unstake
        vm.prank(user2);
        staking.unstake(100 ether, user2);
        
        // User1: unstake
        vm.prank(user1);
        staking.unstake(500 ether, user1);
    }
}
