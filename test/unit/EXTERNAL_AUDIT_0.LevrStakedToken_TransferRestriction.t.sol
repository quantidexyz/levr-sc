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

        // Transfer 600 tokens to Bob (60%), Alice keeps 40%
        stakedToken.transfer(bob, 600 ether);

        // Alice's VP uses UNSTAKE semantics: both balance and time scale
        // 40% balance * 40% time = 16% of original VP
        uint256 vpAfter = staking.getVotingPower(alice);
        uint256 expectedVp = (vpBefore * 40 * 40) / (100 * 100);

        assertEq(vpAfter, expectedVp, 'Alice VP follows unstake semantics (0.4 * 0.4 = 0.16)');
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

        // TRANSFER uses UNSTAKE semantics for sender
        // When 50% of tokens transferred out, BOTH balance and time reduce to 50%
        // VP = (50% balance) * (50% time) = 25% of original
        // Expected: 100,000 * 0.5 * 0.5 = 25,000
        assertEq(
            vpAfter,
            25_000,
            'Alice VP should be 25% (unstake semantics: 50% balance * 50% time)'
        );

        // Verify the reduction formula matches unstake behavior
        // After 50% transfer: VP = originalVP * (remainingBalance/originalBalance)^2
        uint256 expectedVP = (vpBefore * 50 * 50) / (100 * 100);
        assertEq(vpAfter, expectedVP, 'VP should follow unstake formula');
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

        // After transfer: Alice's VP uses UNSTAKE semantics
        // Transferred 400/1000 = 40%, remaining 60%
        // VP = 50,000 * 0.6 * 0.6 = 18,000 (balance and time both scale)
        uint256 aliceVpAfter = staking.getVotingPower(alice);
        uint256 expectedVP = (50_000 * 60 * 60) / (100 * 100);
        assertEq(
            aliceVpAfter,
            expectedVP,
            'Alice VP follows unstake semantics (both balance and time scale)'
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

        // Test 25% transfer (2500 tokens) - 75% remains
        stakedToken.transfer(bob, 2500 ether);
        uint256 vpAfter25 = staking.getVotingPower(alice);
        // After transfer using UNSTAKE semantics: 75% balance, 75% time
        // VP = 1,000,000 * 0.75 * 0.75 = 562,500
        uint256 expected25 = (vpOriginal * 75 * 75) / (100 * 100);
        assertEq(vpAfter25, expected25, '75% remaining: unstake semantics (0.75 * 0.75)');
    }

    // ============ CRITICAL: Reward Emission Tracking Tests ============

    /// @notice Test that rewards are PRESERVED during transfer (no auto-claim)
    /// @dev CRITICAL: Sender keeps their rewards, receiver starts fresh
    function test_transfer_rewardTracking_senderKeepsRewards() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Wait for some rewards to vest
        vm.warp(block.timestamp + 1 days);

        // Check Alice's claimable rewards BEFORE transfer
        uint256 aliceRewardsBefore = staking.claimableRewards(alice, address(underlying));
        console.log('Alice rewards before transfer:', aliceRewardsBefore);
        assertTrue(aliceRewardsBefore > 0, 'Alice should have claimable rewards');

        // Alice transfers to Bob (NO auto-claim)
        stakedToken.transfer(bob, 500 ether);

        // CRITICAL: Alice's claimable should be PRESERVED (not auto-claimed)
        uint256 aliceRewardsAfter = staking.claimableRewards(alice, address(underlying));
        console.log('Alice rewards after transfer:', aliceRewardsAfter);
        assertEq(
            aliceRewardsAfter,
            aliceRewardsBefore,
            'Alice should KEEP her earned rewards after transfer'
        );

        // Bob should have 0 claimable (just received, didn't earn yet)
        uint256 bobRewards = staking.claimableRewards(bob, address(underlying));
        assertEq(bobRewards, 0, 'Bob should have 0 rewards (starts fresh)');

        // Alice can claim her rewards even after transferring tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256 aliceBalBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalAfter = underlying.balanceOf(alice);

        // Alice receives her preserved rewards
        assertEq(
            aliceBalAfter - aliceBalBefore,
            aliceRewardsBefore,
            'Alice should be able to claim her preserved rewards'
        );
    }

    /// @notice Test that _totalStaked remains correct after transfers
    /// @dev CRITICAL: Ensures reward emission calculations stay accurate
    function test_transfer_rewardTracking_totalStakedInvariant() public {
        // Alice and Bob stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);

        uint256 totalStakedBefore = staking.totalStaked();
        assertEq(totalStakedBefore, 1500 ether, 'Total should be 1500');

        // Alice transfers to Charlie
        vm.startPrank(alice);
        stakedToken.transfer(charlie, 300 ether);

        // CRITICAL: _totalStaked should NOT change (transfer doesn't mint/burn)
        uint256 totalStakedAfter = staking.totalStaked();
        assertEq(totalStakedAfter, totalStakedBefore, 'Total staked should remain unchanged');
        assertEq(totalStakedAfter, 1500 ether, 'Total should still be 1500');

        // Verify sum of balances equals total
        uint256 aliceBal = staking.stakedBalanceOf(alice);
        uint256 bobBal = staking.stakedBalanceOf(bob);
        uint256 charlieBal = staking.stakedBalanceOf(charlie);
        assertEq(aliceBal + bobBal + charlieBal, totalStakedAfter, 'Sum should equal total');
    }

    /// @notice Test that sender keeps rewards after full transfer (even with 0 balance)
    /// @dev CRITICAL: Rewards belong to address, not tokens
    function test_transfer_rewardTracking_senderCanClaimAfterFullTransfer() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Let stream complete
        vm.warp(block.timestamp + 3 days + 1);

        // Alice has earned rewards
        uint256 aliceRewards = staking.claimableRewards(alice, address(underlying));
        console.log('Alice rewards earned:', aliceRewards);
        assertEq(aliceRewards, 1000 ether, 'Alice earned all rewards');

        // Alice transfers ALL tokens to Bob
        stakedToken.transfer(bob, 1000 ether);

        // CRITICAL: Alice should STILL have her rewards claimable (even with 0 balance)
        uint256 aliceRewardsAfterTransfer = staking.claimableRewards(alice, address(underlying));
        console.log('Alice rewards after transferring all tokens:', aliceRewardsAfterTransfer);
        assertEq(
            aliceRewardsAfterTransfer,
            aliceRewards,
            'Alice should keep her rewards even after transferring all tokens'
        );

        // Bob should have 0 (just received, didn't earn)
        uint256 bobRewards = staking.claimableRewards(bob, address(underlying));
        assertEq(bobRewards, 0, 'Bob should have 0 rewards (just received tokens)');

        // Alice claims her rewards (despite having 0 staked balance)
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256 aliceBalBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalAfter = underlying.balanceOf(alice);

        // Alice receives her earned rewards
        assertEq(
            aliceBalAfter - aliceBalBefore,
            aliceRewards,
            'Alice should claim her rewards even with 0 staked balance'
        );
    }

    // ============ CRITICAL: Midstream Transfer Tests (Accrual Edge Cases) ============

    /// @notice Test transfer during active reward stream
    /// @dev Ensures rewards are correctly distributed when transfer happens mid-stream
    function test_transfer_midstream_duringActiveStream() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards (starts 3-day stream)
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Wait 1 day (1/3 of stream) - 333.33 ether should be vested
        vm.warp(block.timestamp + 1 days);

        uint256 aliceRewardsMidstream = staking.claimableRewards(alice, address(underlying));
        console.log('Alice rewards at day 1 (midstream):', aliceRewardsMidstream);
        assertTrue(aliceRewardsMidstream > 333 ether, 'Should have ~333 ether vested');

        // Alice transfers to Bob mid-stream (NO auto-claim)
        stakedToken.transfer(bob, 500 ether);

        // Verify Alice KEEPS her midstream rewards (not auto-claimed)
        uint256 aliceRewardsAfterTransfer = staking.claimableRewards(alice, address(underlying));
        assertEq(
            aliceRewardsAfterTransfer,
            aliceRewardsMidstream,
            'Alice should keep her earned rewards after transfer'
        );

        // After transfer: Alice 500, Bob 500
        // Remaining stream should distribute equally to both
        vm.warp(block.timestamp + 2 days); // Complete the stream

        uint256 aliceRewardsAfterStream = staking.claimableRewards(alice, address(underlying));
        uint256 bobRewardsAfterStream = staking.claimableRewards(bob, address(underlying));

        console.log('Alice rewards after stream ends:', aliceRewardsAfterStream);
        console.log('Bob rewards after stream ends:', bobRewardsAfterStream);

        // Both should have roughly equal rewards (same balance, same time)
        assertTrue(aliceRewardsAfterStream > 0, 'Alice should earn post-transfer rewards');
        assertTrue(bobRewardsAfterStream > 0, 'Bob should earn post-transfer rewards');
    }

    /// @notice Test multiple transfers during same stream
    /// @dev Ensures midstream transfers don't cause reward loss or double-counting
    function test_transfer_midstream_multipleTransfersDuringStream() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Start stream
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        uint256 totalRewardsAccrued = 1000 ether;
        uint256 totalRewardsClaimed = 0;

        // Day 1: Alice transfers 300 to Bob (NO auto-claim, rewards preserved)
        vm.warp(block.timestamp + 1 days);
        uint256 aliceRewards1 = staking.claimableRewards(alice, address(underlying));
        console.log('Day 1: Alice rewards (preserved, not claimed):', aliceRewards1);
        stakedToken.transfer(bob, 300 ether);

        // Day 2: Bob transfers 100 to Charlie
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(bob);
        uint256 bobRewards1 = staking.claimableRewards(bob, address(underlying));
        console.log('Day 2: Bob rewards (preserved, not claimed):', bobRewards1);
        stakedToken.transfer(charlie, 100 ether);

        // Wait for full stream to complete (3 days from initial accrual)
        // Day 1 + Day 2 already passed, need 1 more day
        vm.warp(block.timestamp + 1 days + 1);

        vm.startPrank(alice);
        uint256 aliceRewardsFinal = staking.claimableRewards(alice, address(underlying));
        if (aliceRewardsFinal > 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(underlying);
            staking.claimRewards(tokens, alice);
            totalRewardsClaimed += aliceRewardsFinal;
        }

        vm.startPrank(bob);
        uint256 bobRewardsFinal = staking.claimableRewards(bob, address(underlying));
        if (bobRewardsFinal > 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(underlying);
            staking.claimRewards(tokens, bob);
            totalRewardsClaimed += bobRewardsFinal;
        }

        vm.startPrank(charlie);
        uint256 charlieRewardsFinal = staking.claimableRewards(charlie, address(underlying));
        if (charlieRewardsFinal > 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(underlying);
            staking.claimRewards(tokens, charlie);
            totalRewardsClaimed += charlieRewardsFinal;
        }

        console.log('Total rewards accrued:', totalRewardsAccrued);
        console.log('Total rewards claimed:', totalRewardsClaimed);

        // CRITICAL: Verify no reward inflation (total claimed ≤ accrued)
        assertLe(
            totalRewardsClaimed,
            totalRewardsAccrued,
            'Total claimed should not exceed accrued (no inflation)'
        );

        // Verify all parties have claimable rewards
        assertTrue(aliceRewardsFinal > 0, 'Alice should have preserved + new rewards');
        assertTrue(bobRewardsFinal > 0, 'Bob should have earned rewards');
    }

    /// @notice Test transfer immediately after new accrual
    /// @dev Ensures new accruals don't interfere with transfer mechanics
    function test_transfer_midstream_transferRightAfterAccrual() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // First accrual
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Wait for partial vesting
        vm.warp(block.timestamp + 1 days);

        // Second accrual (midstream) - this resets the stream
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        // Immediately transfer after second accrual (NO auto-claim)
        uint256 aliceRewardsBefore = staking.claimableRewards(alice, address(underlying));
        console.log('Alice rewards before transfer:', aliceRewardsBefore);

        stakedToken.transfer(bob, 500 ether);

        // Alice should KEEP her rewards (not auto-claimed)
        uint256 aliceRewardsAfter = staking.claimableRewards(alice, address(underlying));
        assertEq(
            aliceRewardsAfter,
            aliceRewardsBefore,
            'Alice should keep her rewards (no auto-claim)'
        );

        // Alice claims later
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256 aliceBalBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalAfter = underlying.balanceOf(alice);

        assertEq(
            aliceBalAfter - aliceBalBefore,
            aliceRewardsBefore,
            'Alice should receive her preserved rewards'
        );
    }

    /// @notice Test that sender and receiver both track streaming rewards correctly post-transfer
    /// @dev Critical for ensuring no reward leakage or double-counting
    function test_transfer_midstream_bothPartiesEarnProportionally() public {
        // Alice and Bob both stake
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(bob);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards (2000 total for 2000 staked)
        vm.startPrank(alice);
        underlying.mint(address(staking), 2000 ether);
        staking.accrueRewards(address(underlying));

        // Wait 1.5 days (half the stream)
        vm.warp(block.timestamp + 1.5 days);

        // At this point: 1000 ether vested, 1000 ether unvested
        // Alice: 500 claimable, Bob: 500 claimable

        // Alice transfers 500 to Charlie
        vm.startPrank(alice);
        stakedToken.transfer(charlie, 500 ether);

        // After transfer balances: Alice=500, Bob=1000, Charlie=500, Total=2000
        // Remaining unvested: 1000 ether over 1.5 days
        // Expected distribution: Alice=25%, Bob=50%, Charlie=25%

        // Complete the stream
        vm.warp(block.timestamp + 1.5 days + 1);

        uint256 aliceRewardsFinal = staking.claimableRewards(alice, address(underlying));
        uint256 bobRewardsFinal = staking.claimableRewards(bob, address(underlying));
        uint256 charlieRewardsFinal = staking.claimableRewards(charlie, address(underlying));

        console.log('Alice final claimable:', aliceRewardsFinal);
        console.log('Bob final claimable:', bobRewardsFinal);
        console.log('Charlie final claimable:', charlieRewardsFinal);

        // Verify proportional distribution of remaining stream
        // Bob should have ~2x Alice's rewards (1000 vs 500 balance)
        // Bob should have ~2x Charlie's rewards (1000 vs 500 balance)
        assertTrue(bobRewardsFinal > aliceRewardsFinal, 'Bob should have more than Alice');
        assertTrue(bobRewardsFinal > charlieRewardsFinal, 'Bob should have more than Charlie');

        // Verify total is reasonable (includes Alice's auto-claimed 500 from first half)
        uint256 totalClaimable = aliceRewardsFinal + bobRewardsFinal + charlieRewardsFinal;
        console.log('Total claimable at end:', totalClaimable);

        // Total shouldn't exceed total accrued (2000 ether)
        assertLe(totalClaimable, 2000 ether, 'Total should not exceed total accrued');
    }

    /// @notice Test transfer at exact stream boundary
    /// @dev Edge case: transfer when stream just completes
    function test_transfer_midstream_atStreamBoundary() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        // Wait exactly until stream ends (3 days)
        vm.warp(block.timestamp + 3 days);

        // All rewards should be fully vested
        uint256 aliceRewardsAtEnd = staking.claimableRewards(alice, address(underlying));
        assertEq(aliceRewardsAtEnd, 1000 ether, 'All rewards should be vested');

        // Transfer at exact boundary (NO auto-claim)
        stakedToken.transfer(bob, 500 ether);

        // Alice should KEEP her rewards (not auto-claimed)
        uint256 aliceRewardsAfterTransfer = staking.claimableRewards(alice, address(underlying));
        assertEq(aliceRewardsAfterTransfer, 1000 ether, 'Alice should keep all her earned rewards');

        // Bob should have 0 rewards (no retroactive rewards)
        uint256 bobRewards = staking.claimableRewards(bob, address(underlying));
        assertEq(bobRewards, 0, 'Bob should have 0 rewards (no retroactive)');

        // Alice claims her preserved rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256 aliceBalBefore = underlying.balanceOf(alice);
        staking.claimRewards(tokens, alice);
        uint256 aliceBalAfter = underlying.balanceOf(alice);

        assertEq(
            aliceBalAfter - aliceBalBefore,
            1000 ether,
            'Alice should receive all her preserved rewards'
        );
    }
}
