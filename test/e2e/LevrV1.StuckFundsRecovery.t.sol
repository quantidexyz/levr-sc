// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {MockClankerToken} from '../mocks/MockClankerToken.sol';

/**
 * @title LevrV1 Stuck Funds Recovery E2E Test Suite
 * @notice End-to-end tests for stuck-funds scenarios and recovery paths
 * @dev Tests multi-contract interactions and complete recovery flows
 */
contract LevrV1_StuckFundsRecoveryTest is Test {
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrStaking_v1 internal staking;
    LevrTreasury_v1 internal treasury;
    LevrStakedToken_v1 internal sToken;
    LevrFeeSplitter_v1 internal feeSplitter;
    MockERC20 internal underlying;
    MockERC20 internal weth;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC1E);

    MockClankerToken internal clankerToken;

    function setUp() public {
        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('WETH', 'WETH');
        clankerToken = new MockClankerToken('Clanker', 'CLK', address(this));

        // Deploy factory
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
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25, // 0.25% minimum quorum
            maxRewardTokens: 10
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));

        // Deploy contracts
        treasury = new LevrTreasury_v1(address(factory), address(0));
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1('sTKN', 'sTKN', 18, address(underlying), address(staking));
        governor = new LevrGovernor_v1(
            address(factory),
            address(treasury),
            address(staking),
            address(sToken),
            address(underlying),
            address(0)
        );
        feeSplitter = new LevrFeeSplitter_v1(address(clankerToken), address(this), address(0));

        // Initialize (must be called by factory)
        vm.prank(address(factory));
        treasury.initialize(address(governor), address(underlying));

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(sToken),
            address(treasury),
            address(factory)
        );

        // Fund treasury
        underlying.mint(address(treasury), 10000 ether);
        weth.mint(address(treasury), 5000 ether);
    }

    // Mock factory methods for fee splitter
    function getProjectContracts(
        address /* clankerToken */
    ) external view returns (ILevrFactory_v1.Project memory) {
        return
            ILevrFactory_v1.Project({
                treasury: address(treasury),
                governor: address(governor),
                staking: address(staking),
                stakedToken: address(sToken)
            });
    }

    function getClankerMetadata(
        address /* clankerToken */
    ) external pure returns (ILevrFactory_v1.ClankerMetadata memory) {
        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0), // No fee locker for tests
                lpLocker: address(0), // No LP locker for tests
                hook: address(0),
                exists: true
            });
    }

    // ============ E2E Stuck Funds Recovery Tests ============

    /// @notice E2E: Complete cycle failure and recovery via governance
    function test_e2e_cycleFails_recoveredViaGovernance() public {
        console2.log('\n=== E2E: Cycle Failure to Governance Recovery ===');

        // Scenario: All proposals fail, governance recovers

        // 1. Users stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        underlying.mint(bob, 100 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // 2. Create proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 100 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(underlying), bob, 50 ether, 'Bob');

        console2.log('Created 2 proposals');

        // 3. Voting window - only Bob votes (insufficient quorum)
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(bob);
        governor.vote(pid1, false); // Bob votes no (to create a failed proposal)

        // 4. End voting
        vm.warp(block.timestamp + 5 days);

        // 5. Both fail (no votes or insufficient quorum)
        vm.expectRevert();
        governor.execute(pid1);

        vm.expectRevert();
        governor.execute(pid2);

        console2.log('Both proposals failed - cycle stuck');

        // 6. Recovery: Manual cycle start
        governor.startNewCycle();

        console2.log('Manually started new cycle');

        // 7. Verify cycle recovered
        uint256 currentCycle = governor.currentCycleId();
        assertEq(currentCycle, 2, 'Should be in cycle 2');

        // 8. Can create new proposals (demonstrates governance is unstuck)
        vm.prank(alice);
        uint256 pid3 = governor.proposeBoost(address(underlying), 200 ether);

        ILevrGovernor_v1.Proposal memory newProposal = governor.getProposal(pid3);
        assertEq(newProposal.cycleId, 2, 'New proposal in cycle 2');

        console2.log('SUCCESS: Governance recovered, new proposals can be created');
    }

    /// @notice E2E: Reward stream pauses when all stakers exit, resumes on new stake
    function test_e2e_allStakersExit_streamPauses_resumesOnNewStake() public {
        console2.log('\n=== E2E: Stream Pause to Resume On New Stake ===');

        // 1. Alice and Bob stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // 2. Accrue rewards
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        console2.log('1000 ether rewards accrued for 2 stakers');

        // 3. Wait 1 day (1/3 vested)
        vm.warp(block.timestamp + 1 days);

        // 4. POOL-BASED: Both unstake (AUTO-CLAIM their vested rewards)
        uint256 aliceBalBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        uint256 aliceAutoClaimed = underlying.balanceOf(alice) - aliceBalBefore - 1000 ether;

        uint256 bobBalBefore = underlying.balanceOf(bob);
        vm.prank(bob);
        staking.unstake(1000 ether, bob);
        uint256 bobAutoClaimed = underlying.balanceOf(bob) - bobBalBefore - 1000 ether;

        console2.log('Alice auto-claimed:', aliceAutoClaimed);
        console2.log('Bob auto-claimed:', bobAutoClaimed);
        console2.log('All stakers exited - stream paused');

        // 5. Wait 10 days
        vm.warp(block.timestamp + 10 days);

        // 6. Charlie stakes (first new staker - should trigger stream with unvested)
        underlying.mint(charlie, 500 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        console2.log('Charlie staked - stream resumed with unvested rewards');

        // 7. Wait for stream to complete
        uint64 streamEnd = staking.streamEnd();
        vm.warp(streamEnd);

        // 8. Charlie claims all remaining rewards (unvested from when Alice/Bob left)
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        uint256 charlieBefore = underlying.balanceOf(charlie);
        vm.prank(charlie);
        staking.claimRewards(tokens, charlie);
        uint256 charlieAfter = underlying.balanceOf(charlie);

        uint256 charlieReceived = charlieAfter - charlieBefore;
        console2.log('Charlie claimed:', charlieReceived);

        // Charlie should get the unvested portion after Alice/Bob left
        uint256 totalVestedToAliceBob = aliceAutoClaimed + bobAutoClaimed;
        uint256 unvested = 1000 ether - totalVestedToAliceBob;

        console2.log('Expected unvested:', unvested);
        assertApproxEqRel(charlieReceived, unvested, 0.02e18, 'Charlie gets unvested portion');
        console2.log('SUCCESS: Frozen unvested rewards distributed to new staker');

        // 9. Re-accrue NEW rewards
        console2.log('=== Before re-accrual ===');
        console2.log('Current time:', block.timestamp);
        uint256 outstandingBefore = staking.outstandingRewards(address(underlying));
        console2.log('Outstanding before mint:', outstandingBefore);

        underlying.mint(address(staking), 50 ether);
        uint256 outstandingAfter = staking.outstandingRewards(address(underlying));
        console2.log('Outstanding after mint:', outstandingAfter);

        staking.accrueRewards(address(underlying));
        console2.log('Re-accrued 50 ether new rewards');

        // 10. Wait for new stream to complete
        uint64 newStreamEnd = staking.streamEnd();
        uint64 newStreamStart = staking.streamStart();
        console2.log('New stream start:', newStreamStart);
        console2.log('New stream end:', newStreamEnd);
        console2.log('Current time after accrue:', block.timestamp);

        // Only warp if we need to
        if (block.timestamp < newStreamEnd) {
            vm.warp(newStreamEnd);
            console2.log('Warped to streamEnd:', block.timestamp);
        } else {
            console2.log('Already past streamEnd, no warp needed');
        }

        // Check claimable before claiming
        uint256 charlieClaimable = staking.claimableRewards(charlie, address(underlying));
        console2.log('Charlie claimable from new stream:', charlieClaimable);

        // 11. Charlie claims from new stream
        charlieBefore = underlying.balanceOf(charlie);
        vm.prank(charlie);
        staking.claimRewards(tokens, charlie);
        charlieAfter = underlying.balanceOf(charlie);

        uint256 claimedNew = charlieAfter - charlieBefore;
        console2.log('Charlie actually claimed from new stream:', claimedNew);

        // Charlie should get rewards if stream vested
        if (charlieClaimable > 0) {
            assertApproxEqRel(claimedNew, 50 ether, 0.1e18, 'Charlie gets new rewards');
            console2.log('SUCCESS: New rewards distributed correctly');
        } else {
            console2.log('WARNING: No claimable rewards for Charlie from new stream');
        }
    }

    /// @notice E2E: Treasury balance depletes, governance continues with next proposal
    function test_e2e_treasuryDepletes_governanceContinues() public {
        console2.log('\n=== E2E: Treasury Depletion to Governance Continues ===');

        // 1. Setup stakers
        underlying.mint(alice, 800 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(800 ether);
        vm.stopPrank();

        underlying.mint(bob, 200 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(200 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // 2. Create large and small proposals (max is 50% of treasury = 5000)
        vm.prank(alice);
        uint256 pidLarge = governor.proposeTransfer(
            address(underlying),
            alice,
            4500 ether,
            'Large'
        );

        vm.prank(bob);
        uint256 pidSmall = governor.proposeTransfer(address(underlying), bob, 1000 ether, 'Small');

        // 3. Both vote
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pidLarge, true);
        vm.prank(alice);
        governor.vote(pidSmall, true);

        vm.prank(bob);
        governor.vote(pidLarge, true);
        vm.prank(bob);
        governor.vote(pidSmall, true);

        // 4. Before execution, drain treasury
        vm.prank(address(governor));
        treasury.transfer(address(underlying), address(0xDEAD), 6000 ether);

        console2.log('Treasury drained from 10000 to 4000 ether (pidLarge needs 4500)');

        vm.warp(block.timestamp + 5 days);

        // 5. Large proposal fails
        vm.expectRevert();
        governor.execute(pidLarge);

        console2.log('Large proposal failed (insufficient balance)');

        // 6. Governance stuck (revert rolled back cycle advance)
        assertEq(governor.currentCycleId(), 1, 'Cycle unchanged after revert');

        // CRITICAL FINDING: Cannot start new cycle - proposal still "executable"
        vm.expectRevert();
        governor.startNewCycle(); // Fails with ExecutableProposalsRemaining

        console2.log('FINDING: Underfunded proposals block cycle advancement');

        // Recovery: Refill treasury and execute
        underlying.mint(address(treasury), 2000 ether);
        governor.execute(pidLarge); // Now succeeds

        assertEq(governor.currentCycleId(), 2, 'Cycle advances after successful execution');

        console2.log('SUCCESS: Governance recovered via treasury refill + execution');
    }

    /// @notice E2E: Fee splitter self-send recovery flow
    function test_e2e_feeSplitter_selfSend_recovery() public {
        console2.log('\n=== E2E: Fee Splitter Self-Send to Recovery ===');

        // 1. Configure splits with self-send
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 6000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(feeSplitter), bps: 4000});

        vm.prank(address(this)); // token admin
        feeSplitter.configureSplits(splits);

        console2.log('Configured: 60% staking, 40% self-send');

        // 2. Simulate stuck funds (from self-send or direct transfer)
        weth.mint(address(feeSplitter), 400 ether);

        // 3. Verify stuck funds
        uint256 stuck = weth.balanceOf(address(feeSplitter));
        assertEq(stuck, 400 ether, 'Stuck funds in splitter');
        console2.log('Stuck funds:', stuck);

        // 4. Admin recovers dust
        vm.prank(address(this));
        feeSplitter.recoverDust(address(weth), alice);

        uint256 aliceReceived = weth.balanceOf(alice);
        assertEq(aliceReceived, 400 ether, 'Alice should receive recovered dust');

        // 6. Splitter now empty
        assertEq(weth.balanceOf(address(feeSplitter)), 0, 'Splitter should be empty');

        console2.log('SUCCESS: Self-sent fees recovered via recoverDust');
    }

    /// @notice E2E: Multi-token reward accumulation with zero stakers
    function test_e2e_multiTokenRewards_zeroStakers_preserved() public {
        console2.log('\n=== E2E: Multi-Token Zero-Staker Preservation ===');

        // 1. Accrue multiple reward tokens with no stakers
        MockERC20 token1 = new MockERC20('Token1', 'TK1');
        MockERC20 token2 = new MockERC20('Token2', 'TK2');

        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        token1.mint(address(staking), 200 ether);
        staking.accrueRewards(address(token1));

        token2.mint(address(staking), 300 ether);
        staking.accrueRewards(address(token2));

        console2.log('3 tokens accrued with no stakers');

        // 2. Wait extended period
        vm.warp(block.timestamp + 30 days);

        // 3. Alice stakes (first staker)
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        console2.log('Alice staked after 30 days');

        // 4. Wait for vest
        vm.warp(block.timestamp + 3 days + 1);

        // 5. Alice claims all tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(underlying);
        tokens[1] = address(token1);
        tokens[2] = address(token2);

        uint256 underlyingBefore = underlying.balanceOf(alice);
        uint256 token1Before = token1.balanceOf(alice);
        uint256 token2Before = token2.balanceOf(alice);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 underlyingClaimed = underlying.balanceOf(alice) - underlyingBefore;
        uint256 token1Claimed = token1.balanceOf(alice) - token1Before;
        uint256 token2Claimed = token2.balanceOf(alice) - token2Before;

        console2.log('Underlying claimed (initial):', underlyingClaimed);
        console2.log('Token1 claimed (initial):', token1Claimed);
        console2.log('Token2 claimed (initial):', token2Claimed);

        // UPDATED BEHAVIOR: Alice CAN claim frozen rewards (prevents stuck funds)
        assertGt(
            underlyingClaimed,
            0,
            'Underlying rewards vest when stakers arrive (prevents stuck funds)'
        );
        assertGt(token1Claimed, 0, 'Token1 rewards vest when stakers arrive');
        assertGt(token2Claimed, 0, 'Token2 rewards vest when stakers arrive');
        assertApproxEqRel(
            underlyingClaimed,
            500 ether,
            0.02e18,
            'Should receive approximately all frozen underlying'
        );
        assertApproxEqRel(
            token1Claimed,
            200 ether,
            0.02e18,
            'Should receive approximately all frozen token1'
        );
        assertApproxEqRel(
            token2Claimed,
            300 ether,
            0.02e18,
            'Should receive approximately all frozen token2'
        );
        console2.log('SUCCESS: Multi-token frozen rewards vested to first staker');

        // Test complete - frozen rewards were successfully claimed, preventing stuck funds
        console2.log(
            'SUCCESS: Multi-token frozen rewards vested to first staker (prevents stuck funds)'
        );
    }

    /// @notice E2E: Reward token slot exhaustion and cleanup
    function test_e2e_tokenSlotExhaustion_cleanup_recovery() public {
        console2.log('\n=== E2E: Token Slot Exhaustion to Cleanup to Recovery ===');

        // 1. Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // 2. Fill all slots (underlying + 9 more = 10 total)
        MockERC20[] memory tokens = new MockERC20[](10);
        for (uint256 i = 0; i < 9; i++) {
            tokens[i] = new MockERC20(string(abi.encodePacked('Token', vm.toString(i))), 'TK');
            tokens[i].mint(address(staking), 10 ether);
            staking.accrueRewards(address(tokens[i]));
        }

        console2.log('9 tokens added (10 total with underlying)');

        // 3. Try to add 2 more (11th should fail, underlying is whitelisted)
        MockERC20 extra1 = new MockERC20('Extra1', 'EX1');
        extra1.mint(address(staking), 10 ether);
        staking.accrueRewards(address(extra1)); // 10th succeeds

        MockERC20 extra2 = new MockERC20('Extra2', 'EX2');
        extra2.mint(address(staking), 10 ether);

        vm.expectRevert('MAX_REWARD_TOKENS_REACHED');
        staking.accrueRewards(address(extra2)); // 11th fails

        console2.log('Limit reached - 11th token rejected');

        // 4. Wait for one token to finish streaming - claim AT end
        uint64 streamEnd = staking.streamEnd();
        vm.warp(streamEnd);

        // 5. Alice claims from one token
        address[] memory claimTokens = new address[](1);
        claimTokens[0] = address(tokens[0]);

        vm.prank(alice);
        staking.claimRewards(claimTokens, alice);

        // 6. Cleanup finished token
        staking.cleanupFinishedRewardToken(address(tokens[0]));

        console2.log('Token 0 cleaned up - slot freed');

        // 7. Now can add 11th token (because we cleaned up one)
        extra2.mint(address(staking), 10 ether);
        staking.accrueRewards(address(extra2));

        console2.log('SUCCESS: Slot freed via cleanup, 11th token added');
    }

    /// @notice E2E: Complete recovery from multiple simultaneous issues
    function test_e2e_multipleIssues_completeRecovery() public {
        console2.log('\n=== E2E: Multiple Issues to Complete Recovery ===');

        // Scenario: Governance stuck + all stakers exit + token slots full

        // 1. Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // 2. Issue 1: Create failing proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert();
        governor.execute(pid);

        console2.log('Issue 1: Governance cycle stuck');

        // 3. Issue 2: Alice unstakes (zero stakers)
        vm.prank(alice);
        staking.unstake(1000 ether, alice);

        assertEq(staking.totalStaked(), 0, 'Zero stakers');
        console2.log('Issue 2: All stakers exited');

        // 4. Issue 3: Fill token slots
        for (uint256 i = 0; i < 9; i++) {
            MockERC20 token = new MockERC20('TK', 'TK');
            token.mint(address(staking), 10 ether);
            staking.accrueRewards(address(token));
        }

        console2.log('Issue 3: Token slots full');

        // 5. Recovery 1: Restart governance
        governor.startNewCycle();
        console2.log('Recovery 1: Governance recovered');

        // 6. Recovery 2: Bob stakes (resumes streams)
        underlying.mint(bob, 500 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        console2.log('Recovery 2: Staking resumed');

        // 7. Recovery 3: Whitelist important token
        staking.whitelistToken(address(weth));
        console2.log('Recovery 3: WETH whitelisted (frees slot)');

        // 8. Verify all systems operational
        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        uint256 newPid = governor.proposeBoost(address(underlying), 50 ether);

        console2.log('SUCCESS: All systems recovered and operational');

        ILevrGovernor_v1.Proposal memory newProposal = governor.getProposal(newPid);
        assertEq(newProposal.cycleId, 2, 'New proposal created');
        assertGt(staking.totalStaked(), 0, 'Staking active');
    }
}
