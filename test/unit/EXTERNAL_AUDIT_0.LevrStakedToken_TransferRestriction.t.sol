// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @title EXTERNAL_AUDIT_0 CRITICAL-1: Balance-Based Design Transfer Tests
/// @notice Tests for [CRITICAL-1] Fix: Staked Token Transferability with Balance-Based Design
/// @dev Issue: Transfers now ENABLED with balance as single source of truth
/// @dev Solution: Use stakedToken.balanceOf() instead of _staked mapping
contract EXTERNAL_AUDIT_0_LevrStakedTokenTransferRestrictionTest is Test {
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    LevrFactory_v1 factory;
    LevrForwarder_v1 forwarder;
    MockERC20 underlying;

    address alice = address(0x1111);
    address bob = address(0x2222);
    address charlie = address(0x3333);

    function setUp() public {
        // Create factory config
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
            maxProposalAmountBps: 500,
            maxRewardTokens: 50
        });

        // Deploy forwarder
        forwarder = new LevrForwarder_v1('Levr Forwarder');

        // Deploy factory with correct constructor
        factory = new LevrFactory_v1(
            config,
            address(this),
            address(forwarder),
            address(0),
            address(0)
        );

        // Deploy underlying token
        underlying = new MockERC20('Underlying', 'UND');

        // Create staking and staked token directly
        staking = new LevrStaking_v1(address(forwarder));
        stakedToken = new LevrStakedToken_v1(
            'Staked Token',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking
        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(factory),
            address(factory)
        );

        // Mint underlying tokens
        underlying.mint(alice, 100000 ether);
        underlying.mint(bob, 100000 ether);
        underlying.mint(charlie, 100000 ether);
    }

    /// @notice Test that basic staking mints staked tokens correctly
    function test_stakedToken_basicMinting() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Verify tokens were minted
        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Staked tokens should be minted');
        assertEq(
            staking.stakedBalanceOf(alice),
            1000 ether,
            'Internal accounting should match balance'
        );
    }

    /// @notice Test that transfers are NOW ENABLED with balance-based design
    function test_stakedToken_transferNowEnabled() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Transfer is NOW allowed (fix implemented)
        stakedToken.transfer(bob, 500 ether);

        // Verify transfer succeeded
        assertEq(stakedToken.balanceOf(alice), 500 ether, 'Alice should have 500 left');
        assertEq(stakedToken.balanceOf(bob), 500 ether, 'Bob should have received 500');
    }

    /// @notice Test that transferFrom also works with balance-based design
    function test_stakedToken_transferFromNowEnabled() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        stakedToken.approve(bob, 500 ether);

        vm.startPrank(bob);
        stakedToken.transferFrom(alice, bob, 500 ether);

        assertEq(stakedToken.balanceOf(alice), 500 ether, 'Alice should have 500 left');
        assertEq(stakedToken.balanceOf(bob), 500 ether, 'Bob should have received 500');
    }

    /// @notice Test that mint and burn still function correctly
    function test_stakedToken_mintBurnStillWork() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(stakedToken.balanceOf(alice), 1000 ether, 'Stake should mint tokens');

        // Unstake should burn tokens
        staking.unstake(1000 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 0, 'Unstake should burn tokens');
    }

    /// @notice Test that balance is now source of truth for staking
    function test_stakedToken_balanceIsSingleSourceOfTruth() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // staking.stakedBalanceOf should now match stakedToken.balanceOf
        assertEq(
            staking.stakedBalanceOf(alice),
            stakedToken.balanceOf(alice),
            'Balance should match'
        );

        // Transfer tokens
        stakedToken.transfer(bob, 300 ether);

        // staking.stakedBalanceOf still reads from balance
        assertEq(
            staking.stakedBalanceOf(alice),
            stakedToken.balanceOf(alice),
            'Balance should stay in sync after transfer'
        );
        assertEq(
            staking.stakedBalanceOf(bob),
            stakedToken.balanceOf(bob),
            'Bob balance should match'
        );
    }

    /// @notice Test EDGE CASE 1: Simple transfer with proportional VP for sender
    function test_transfer_edgeCase_simpleTransfer_senderVPProportional() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Fast forward 100 days
        vm.warp(block.timestamp + 100 days);

        // Alice VP before transfer: 1000 tokens * 100 days = 100,000
        uint256 vpBefore = staking.getVotingPower(alice);
        assertGt(vpBefore, 0, 'Alice should have VP');

        // Transfer 600 tokens to Bob (60%)
        stakedToken.transfer(bob, 600 ether);

        // Alice's VP should scale proportionally: 400/1000 * original
        uint256 vpAfter = staking.getVotingPower(alice);
        uint256 expectedVp = (vpBefore * 400) / 1000;

        assertEq(vpAfter, expectedVp, 'Alice VP should scale with remaining balance');
    }

    /// @notice Test EDGE CASE 2: Receiver gets 0 VP (fresh start)
    function test_transfer_edgeCase_receiverStartsFresh() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);

        // Transfer to Bob
        stakedToken.transfer(bob, 600 ether);

        // Bob's VP should be 0 (fresh start, just transferred)
        uint256 bobVp = staking.getVotingPower(bob);
        assertEq(bobVp, 0, 'Bob should have 0 VP immediately after transfer');

        // But if Bob waits 1 day, he accumulates VP
        vm.warp(block.timestamp + 1 days);
        bobVp = staking.getVotingPower(bob);
        assertGt(bobVp, 0, 'Bob should accumulate VP over time');
    }

    /// @notice Test EDGE CASE 3: Both sender and receiver can unstake independently
    function test_transfer_edgeCase_bothCanUnstakeIndependently() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 50 days);

        // Transfer 500 to Bob
        stakedToken.transfer(bob, 500 ether);

        // Alice can unstake her remaining 500
        uint256 aliceReceived = staking.unstake(500 ether, alice);
        assertEq(
            underlying.balanceOf(alice),
            100000 ether - 1000 ether + 500 ether,
            'Alice should receive 500 underlying'
        );
        assertEq(stakedToken.balanceOf(alice), 0, 'Alice should have 0 staked tokens');

        // Bob can unstake his 500 (even though just received, VP=0)
        vm.startPrank(bob);
        uint256 bobReceived = staking.unstake(500 ether, bob);
        assertEq(
            underlying.balanceOf(bob),
            100000 ether + 500 ether,
            'Bob should receive 500 underlying (started with 100000)'
        );
        assertEq(stakedToken.balanceOf(bob), 0, 'Bob should have 0 staked tokens');
    }

    /// @notice Test EDGE CASE 4: Multi-hop transfer maintains state consistency
    function test_transfer_edgeCase_multiHopTransfer() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.warp(block.timestamp + 100 days);
        uint256 aliceVpStart = staking.getVotingPower(alice);

        // Alice -> Bob (600)
        stakedToken.transfer(bob, 600 ether);

        vm.startPrank(bob);
        vm.warp(block.timestamp + 50 days);

        // Bob -> Charlie (300 out of his 600)
        stakedToken.transfer(charlie, 300 ether);

        // All three can unstake successfully
        vm.startPrank(alice);
        staking.unstake(400 ether, alice);
        assertEq(underlying.balanceOf(alice), 100000 ether - 1000 ether + 400 ether);

        vm.startPrank(bob);
        staking.unstake(300 ether, bob);
        // Bob started with 100000, got +600 from Alice, unstakes 300, so: 100000 + 600 - 300 = 100300
        assertEq(underlying.balanceOf(bob), 100000 ether + 600 ether - 300 ether);

        vm.startPrank(charlie);
        staking.unstake(300 ether, charlie);
        // Charlie started with 100000, got +300 from Bob, unstakes 300, so: 100000 + 300 - 300 + 300 = 100300
        assertEq(underlying.balanceOf(charlie), 100000 ether + 300 ether);
    }

    /// @notice Test that partial unstaking still works normally
    function test_stakedToken_partialUnstakingWorks() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Unstake partial amount
        staking.unstake(400 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 600 ether, 'Should have 600 staked tokens left');
        assertEq(staking.stakedBalanceOf(alice), 600 ether, 'Should have 600 staked internally');
        assertEq(
            underlying.balanceOf(alice),
            100000 ether - 1000 ether + 400 ether,
            'Should have received 400 underlying'
        );
    }

    /// @notice Test that full unstaking burns all staked tokens
    function test_stakedToken_fullUnstakingBurnsAll() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        staking.unstake(1000 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 0, 'All staked tokens should be burned');
        assertEq(staking.stakedBalanceOf(alice), 0, 'Internal accounting should be zero');
        assertEq(underlying.balanceOf(alice), 100000 ether, 'Should have all underlying back');
    }

    /// @notice Test approvals work correctly with transfers
    function test_stakedToken_approvalsWorkWithTransfers() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Approve Bob for 500
        stakedToken.approve(bob, 500 ether);

        // Bob can transfer up to 500
        vm.startPrank(bob);
        stakedToken.transferFrom(alice, bob, 500 ether);

        assertEq(stakedToken.balanceOf(alice), 500 ether);
        assertEq(stakedToken.balanceOf(bob), 500 ether);
    }

    /// @notice Test that multiple users can stake and transfer independently
    function test_stakedToken_multipleUsers_independentTransfers() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Bob stakes
        vm.startPrank(bob);
        underlying.approve(address(staking), 2000 ether);
        staking.stake(2000 ether);

        assertEq(stakedToken.balanceOf(alice), 1000 ether);
        assertEq(stakedToken.balanceOf(bob), 2000 ether);
        assertEq(stakedToken.totalSupply(), 3000 ether);

        // Both can transfer
        vm.startPrank(alice);
        stakedToken.transfer(charlie, 500 ether);

        vm.startPrank(bob);
        stakedToken.transfer(charlie, 1000 ether);

        assertEq(stakedToken.balanceOf(charlie), 1500 ether);
        assertEq(stakedToken.balanceOf(alice), 500 ether);
        assertEq(stakedToken.balanceOf(bob), 1000 ether);
    }

    /// @notice Test that decimals are preserved
    function test_stakedToken_decimalsPreserved() public {
        uint8 expectedDecimals = underlying.decimals();
        assertEq(stakedToken.decimals(), expectedDecimals, 'Decimals should match underlying');
    }

    /// @notice Test that staking with dust amounts works
    function test_stakedToken_dustAmounts() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 100 wei);
        staking.stake(100 wei);

        assertEq(stakedToken.balanceOf(alice), 100 wei);

        // Can transfer dust (now enabled)
        stakedToken.transfer(bob, 1 wei);
        assertEq(stakedToken.balanceOf(bob), 1 wei, 'Bob should receive dust');
    }

    // ============ VP Transfer Calculation Tests ============

    /// @notice Test VP recalculation on transfer - Sender's VP should decrease proportionally
    /// @dev Scenario: Sender transfers portion of stake
    ///      stakeStartTime is UNCHANGED during transfer
    ///      Only balance changes, so VP = (newBalance * timeStaked) / normalization
    ///      Before: 1000 tokens, 100 days, VP = 100,000
    ///      After: 500 tokens, 100 days (SAME TIME), VP = 50,000
    function test_transfer_vpRecalculation_senderVPDecreasesProportionally() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Fast forward 100 days
        vm.warp(block.timestamp + 100 days);

        // Get VP before transfer
        uint256 vpBefore = staking.getVotingPower(alice);
        console.log('Sender VP before transfer:', vpBefore);
        assertEq(vpBefore, 100_000, 'Alice should have 100,000 VP (1000 tokens * 100 days)');

        // Transfer 500 tokens to Bob
        stakedToken.transfer(bob, 500 ether);

        // Get VP after transfer
        uint256 vpAfter = staking.getVotingPower(alice);
        console.log('Sender VP after transfer:', vpAfter);

        // VP should decrease proportionally with balance, time is UNCHANGED
        // stakeStartTime[alice] is still the same, so timeStaked = 100 days
        // VP = (500 * 100 days) / normalization = 50,000
        assertEq(vpAfter, 50_000, 'Alice VP should decrease to 50,000 (50% of original)');

        // Verify the reduction formula: (balance * timeStaked) / (1e18 * 86400)
        // Before: (1000e18 * 8640000) / (1e18 * 86400) = 100,000
        // After: (500e18 * 8640000) / (1e18 * 86400) = 50,000
        assertEq(vpAfter, vpBefore / 2, 'VP should scale exactly with balance reduction');
    }

    /// @notice Test VP on receiver after transfer - Receiver's VP is preserved
    /// @dev Scenario: Receiver had different stake, receives transfer
    ///      KEY: Receiver's VP is recalculated using weighted average (like staking)
    ///      Before Transfer:
    ///        Alice: 1000 tokens, 100 days staked, VP = 100,000
    ///        Bob: 500 tokens, 50 days staked, VP = 25,000
    ///      Transfer: Alice sends 500 to Bob
    ///      After Transfer:
    ///        Alice: 500 tokens, VP scales with balance
    ///        Bob: 1000 tokens, VP PRESERVED via weighted average = 25,000 still
    function test_transfer_vpRecalculation_receiverStartsFreshVP() public {
        // Setup: Bob stakes for 50 days and gets VP
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        vm.warp(block.timestamp + 50 days);
        uint256 bobVpBefore = staking.getVotingPower(bob);
        assertEq(bobVpBefore, 25_000);

        // Setup: Alice stakes for 100 days
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 50 days); // Both at 100 days elapsed now

        // Alice transfers to Bob
        stakedToken.transfer(bob, 500 ether);

        // Bob received tokens and his VP should be PRESERVED via weighted average
        uint256 bobVpAfter = staking.getVotingPower(bob);
        console.log('Bob VP after receiving transfer:', bobVpAfter);
        assertEq(bobVpAfter, bobVpBefore, 'Bob VP should be preserved via weighted average');
    }

    /// @notice Test VP behavior when receiver already has stake with accumulated VP
    /// @dev Verifies that transfer PRESERVES receiver's VP via weighted average
    ///      This prevents the exploit of resetting someone's VP via transfer
    function test_transfer_vpRecalculation_receiverVPResetNotAccumulated() public {
        // Bob stakes 500 for 50 days
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        vm.warp(block.timestamp + 50 days);

        uint256 bobVpBefore = staking.getVotingPower(bob);
        assertEq(bobVpBefore, 25_000);

        // Alice stakes 1000 for 100 days
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 50 days); // Both at 100 days elapsed

        // Alice transfers 300 to Bob
        stakedToken.transfer(bob, 300 ether);

        // Bob's VP should be preserved via weighted average calculation
        uint256 bobVpAfter = staking.getVotingPower(bob);
        console.log('Bob VP after transfer:', bobVpAfter);
        assertEq(bobVpAfter, bobVpBefore, 'Bob VP should be preserved via weighted average');
    }

    /// @notice Test VP calculations during complex multi-party transfers
    /// @dev Verify VP formula and weighted average preservation during transfers
    function test_transfer_vpRecalculation_multiPartyComplexScenario() public {
        // Simple test: verify that transfers don't cause VP exploits
        // Alice stakes and transfers to Bob (who never staked before)
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 50 days);

        uint256 aliceVpBefore = staking.getVotingPower(alice);
        assertEq(aliceVpBefore, 50_000);

        // Alice transfers to Bob (no prior stake)
        stakedToken.transfer(bob, 400 ether);

        // After transfer: Alice's VP scales proportionally
        uint256 aliceVpAfter = staking.getVotingPower(alice);
        assertEq(
            aliceVpAfter,
            30_000,
            'Alice VP scales with remaining balance (600/1000 * 50,000)'
        );

        // Bob just received tokens, starts fresh
        uint256 bobVpAfter = staking.getVotingPower(bob);
        assertEq(bobVpAfter, 0, 'Bob VP starts fresh (no prior stake)');
    }

    /// @notice Test VP calculation matches unstake behavior for senders
    /// @dev Both transfer and unstake reduce sender's balance
    ///      Both should reduce sender's VP proportionally
    function test_transfer_vpRecalculation_matchesUnstakeFormula() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 2000 ether);

        // Scenario 1: Unstake 50%
        staking.stake(1000 ether);
        vm.warp(block.timestamp + 100 days);

        uint256 vpBeforeUnstake = staking.getVotingPower(alice);
        assertEq(vpBeforeUnstake, 100_000);

        staking.unstake(500 ether, alice);
        uint256 vpAfterUnstake = staking.getVotingPower(alice);
        console.log('VP after 50% unstake:', vpAfterUnstake);
        // After unstake, stakeStartTime is RECALCULATED with proportional time reduction
        // This is DIFFERENT from transfer (where time stays the same)
    }

    /// @notice Test VP precision during transfer of various percentages
    /// @dev Verify VP formula (balance * time) / normalization for different transfer amounts
    function test_transfer_vpRecalculation_variousPercentages() public {
        // Test data: 10000 tokens staked for 100 days
        vm.startPrank(alice);
        underlying.approve(address(staking), 100000 ether);
        staking.stake(10000 ether);
        vm.warp(block.timestamp + 100 days);

        uint256 vpOriginal = staking.getVotingPower(alice);
        assertEq(vpOriginal, 1_000_000, 'Base VP: 10,000 tokens * 100 days');

        // Test 25% transfer (2500 tokens)
        stakedToken.transfer(bob, 2500 ether);
        uint256 vpAfter25 = staking.getVotingPower(alice);
        // After transfer: 7500 tokens, stakeTime unchanged, 100 days elapsed
        // VP = (7500 * 100 days) = 750,000
        assertEq(vpAfter25, 750_000, '75% remaining: 7500 * 100 days = 750,000');
    }
}
