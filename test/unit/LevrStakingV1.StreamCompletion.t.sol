// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Stream Completion Edge Case Investigation
 * @notice Diagnose why accrual after stream completion shows 16.67% loss
 */
contract LevrStakingV1StreamCompletionTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;

    address alice = address(0xA11CE);
    address treasury = address(0x1234);

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));
        underlying = new MockERC20('Underlying Token', 'UND');
        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        vm.prank(address(factory));
        staking.initialize(address(underlying), address(stakedToken), treasury, address(factory));

        // Alice stakes 10M
        underlying.mint(alice, 10_000_000 * 1e18);
        vm.startPrank(alice);
        underlying.approve(address(staking), 10_000_000 * 1e18);
        staking.stake(10_000_000 * 1e18);
        vm.stopPrank();
    }

    function test_diagnose_stream_completion_accrual() public {
        console2.log('=== DIAGNOSTIC: ACCRUAL AFTER STREAM COMPLETION ===\n');

        // First accrual: 500K
        uint256 first = 500_000 * 1e18;
        underlying.mint(address(staking), first);

        console2.log('BEFORE FIRST ACCRUAL:');
        _printState();

        staking.accrueRewards(address(underlying));

        console2.log('\nAFTER FIRST ACCRUAL:');
        _printState();
        uint256 claimable1 = staking.claimableRewards(alice, address(underlying));
        console2.log('Claimable:', claimable1 / 1e18);

        // Warp to stream end
        uint64 streamEnd1 = staking.streamEnd();
        console2.log('\nStream ends at:', streamEnd1);
        vm.warp(streamEnd1 + 1);
        console2.log('Warped to:', block.timestamp);

        console2.log('\nAFTER FIRST STREAM COMPLETE:');
        _printState();
        claimable1 = staking.claimableRewards(alice, address(underlying));
        console2.log('Claimable:', claimable1 / 1e18);

        // Try accruing second amount
        uint256 second = 100_000 * 1e18;
        underlying.mint(address(staking), second);

        console2.log('\nBEFORE SECOND ACCRUAL:');
        _printState();
        (uint256 available, ) = staking.outstandingRewards(address(underlying));
        console2.log('Outstanding available:', available / 1e18);

        staking.accrueRewards(address(underlying));

        console2.log('\nAFTER SECOND ACCRUAL:');
        _printState();
        uint256 claimable2 = staking.claimableRewards(alice, address(underlying));
        console2.log('Claimable:', claimable2 / 1e18);

        // Warp to second stream end
        uint64 streamEnd2 = staking.streamEnd();
        console2.log('\nSecond stream ends at:', streamEnd2);
        vm.warp(streamEnd2 + 1);
        console2.log('Warped to:', block.timestamp);

        console2.log('\nAFTER SECOND STREAM COMPLETE:');
        _printState();
        uint256 claimableFinal = staking.claimableRewards(alice, address(underlying));
        console2.log('Claimable:', claimableFinal / 1e18);
        console2.log('Expected:', (first + second) / 1e18);

        // Now claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 balAfter = underlying.balanceOf(alice);

        uint256 claimed = balAfter - balBefore;

        console2.log('\n=== FINAL RESULTS ===');
        console2.log('Total accrued:', (first + second) / 1e18);
        console2.log('Total claimed:', claimed / 1e18);
        console2.log('Missing:', ((first + second) - claimed) / 1e18);

        // Check what's stuck
        uint256 balanceAfter = underlying.balanceOf(address(staking));
        uint256 escrow = staking.escrowBalance(address(underlying));
        console2.log('Stuck:', (balanceAfter - escrow) / 1e18);
    }

    function _printState() internal view {
        uint256 balance = underlying.balanceOf(address(staking));
        uint256 escrow = staking.escrowBalance(address(underlying));
        console2.log('  Balance:', balance / 1e18);
        console2.log('  Escrow:', escrow / 1e18);
        console2.log('  Unaccounted:', (balance - escrow) / 1e18);
    }
}
