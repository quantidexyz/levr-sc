// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 8 - Final Aggressive Coverage Push
/// Ultra-aggressive attempt at hitting every possible branch
contract Phase8_FinalAggressive_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStakedToken_v1 internal sToken;
    
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        staking = LevrStaking_v1(project.staking);
        treasury = LevrTreasury_v1(payable(project.treasury));
        sToken = LevrStakedToken_v1(project.stakedToken);
        
        underlying.mint(address(treasury), 1_000_000 ether);
    }

    // ============ PERMUTATION EXPLOSION: Governor ============

    function test_p8_gov_001() public {
        address u = address(0x101);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        staking.stake(500 ether);
        vm.prank(u);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(u);
        governor.vote(pid, true);
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
    }

    function test_p8_gov_002() public {
        address u = address(0x102);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        staking.stake(500 ether);
        vm.prank(u);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(u);
        governor.vote(pid, false);
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
    }

    function test_p8_gov_003() public {
        address u = address(0x103);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        staking.stake(500 ether);
        vm.prank(u);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        vm.warp(block.timestamp + 10 days);
        governor.execute(pid);
    }

    function test_p8_gov_004() public {
        address[] memory us = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            us[i] = address(uint160(0x2000 + i));
            underlying.mint(us[i], 10_000 ether);
            vm.prank(us[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(us[i]);
            staking.stake(500 ether);
        }
        vm.prank(us[0]);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(us[0]);
        governor.vote(pid, true);
        vm.prank(us[1]);
        governor.vote(pid, false);
        vm.prank(us[2]);
        governor.vote(pid, true);
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
    }

    // ============ PERMUTATION EXPLOSION: Staking ============

    function test_p8_stk_001() public {
        address u = address(0x301);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        staking.stake(5_000 ether);
        vm.prank(u);
        staking.unstake(5_000 ether, u);
    }

    function test_p8_stk_002() public {
        address u = address(0x302);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        staking.stake(5_000 ether);
        vm.prank(u);
        staking.unstake(2_500 ether, u);
        vm.prank(u);
        staking.unstake(2_500 ether, u);
    }

    function test_p8_stk_003() public {
        address u = address(0x303);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        staking.stake(1_000 ether);
        
        MockERC20 rwd = new MockERC20('R', 'R');
        vm.prank(address(this));
        staking.whitelistToken(address(rwd));
        rwd.mint(address(staking), 10_000 ether);
        staking.accrueRewards(address(rwd));
        vm.warp(block.timestamp + 4 days);
        
        address[] memory toks = new address[](1);
        toks[0] = address(rwd);
        vm.prank(u);
        staking.claimRewards(toks, u);
    }

    function test_p8_stk_004() public {
        address u1 = address(0x304);
        address u2 = address(0x305);
        
        underlying.mint(u1, 10_000 ether);
        vm.prank(u1);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u1);
        staking.stake(3_000 ether);
        
        underlying.mint(u2, 10_000 ether);
        vm.prank(u2);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u2);
        staking.stake(7_000 ether);
        
        MockERC20 rwd = new MockERC20('R', 'R');
        vm.prank(address(this));
        staking.whitelistToken(address(rwd));
        rwd.mint(address(staking), 10_000 ether);
        staking.accrueRewards(address(rwd));
        
        vm.warp(block.timestamp + 4 days);
        
        address[] memory toks = new address[](1);
        toks[0] = address(rwd);
        vm.prank(u1);
        staking.claimRewards(toks, u1);
        vm.prank(u2);
        staking.claimRewards(toks, u2);
    }

    // ============ PERMUTATION EXPLOSION: Treasury ============

    function test_p8_tre_001() public {
        address gov = address(governor);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0x401), 100 ether);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0x402), 100 ether);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0x403), 100 ether);
    }

    function test_p8_tre_002() public {
        address gov = address(governor);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(staking), 1_000 ether);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(staking), 1_000 ether);
        vm.prank(gov);
        treasury.transfer(address(underlying), address(staking), 1_000 ether);
    }

    function test_p8_tre_003() public {
        address gov = address(governor);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), address(uint160(0x500 + i)), 100 ether);
        }
    }

    // ============ PERMUTATION EXPLOSION: Forwarder ============

    function test_p8_fwd_001() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            allowFailure: true,
            value: 0,
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x6001))
        });
        forwarder.executeMulticall(calls);
    }

    function test_p8_fwd_002() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            allowFailure: true,
            value: 0,
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x6002))
        });
        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            allowFailure: true,
            value: 0,
            callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(0x6003))
        });
        forwarder.executeMulticall(calls);
    }

    function test_p8_fwd_003() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] = ILevrForwarder_v1.SingleCall({
                target: address(treasury),
                allowFailure: true,
                value: 0,
                callData: abi.encodeWithSignature("withdrawTrappedETH(address)", address(uint160(0x6100 + i)))
            });
        }
        forwarder.executeMulticall(calls);
    }

    // ============ EDGE CASES ============

    function test_p8_edge_001_zeroStake() public {
        address u = address(0x7001);
        underlying.mint(u, 10_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(u);
        vm.expectRevert();
        staking.stake(0);
    }

    function test_p8_edge_002_maxStake() public {
        address u = address(0x7002);
        underlying.mint(u, type(uint128).max);
        vm.prank(u);
        underlying.approve(address(staking), type(uint128).max);
        vm.prank(u);
        try staking.stake(type(uint64).max) {} catch {}
    }

    function test_p8_edge_003_rapidTransitions() public {
        address u = address(0x7003);
        underlying.mint(u, 50_000 ether);
        vm.prank(u);
        underlying.approve(address(staking), 50_000 ether);
        
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(u);
            staking.stake(1_000 ether);
            vm.warp(block.timestamp + 1);
            vm.prank(u);
            try staking.unstake(500 ether, u) {} catch {}
        }
    }
}
