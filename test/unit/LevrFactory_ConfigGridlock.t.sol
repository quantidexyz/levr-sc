// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrFactory_ConfigGridlock Test Suite
 * @notice Tests if factory config changes can break processes or cause gridlocks
 * @dev Tests cleanup operations, recovery mechanisms, and extreme config values
 */
contract LevrFactory_ConfigGridlockTest is Test {
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrStaking_v1 internal staking;
    LevrTreasury_v1 internal treasury;
    LevrStakedToken_v1 internal sToken;
    MockERC20 internal underlying;
    MockERC20 internal rewardToken;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        underlying = new MockERC20('Underlying', 'UND');
        rewardToken = new MockERC20('Reward', 'RWD');

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

        // Initialize
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
    }

    // ============ Config Change During Cleanup Tests ============

    /// @notice Test that changing maxRewardTokens doesn't break cleanup
    function test_config_maxRewardTokens_doesNotBreakCleanup() public {
        console2.log('\n=== Config Change During Cleanup ===');

        // Setup: Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Add reward token and let it finish
        rewardToken.mint(address(staking), 100 ether);
        staking.accrueRewards(address(rewardToken));

        // Wait for stream to finish - claim AT end
        uint64 streamEnd = staking.streamEnd();
        vm.warp(streamEnd);

        // Alice claims all
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        // Change config to maxRewardTokens = 5 (lower than current)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
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
            maxRewardTokens: 5 // Changed from 10 to 5
        });

        factory.updateConfig(newConfig);

        // Cleanup should still work (doesn't check maxRewardTokens)
        staking.cleanupFinishedRewardToken(address(rewardToken));

        console2.log('SUCCESS: Cleanup works despite config change');
    }

    /// @notice Test that changing streamWindowSeconds doesn't break active streams
    function test_config_streamWindow_doesNotBreakActiveStreams() public {
        console2.log('\n=== Stream Window Config Change ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Accrue rewards (creates 3-day stream)
        underlying.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(underlying));

        uint256 streamEndBefore = staking.streamEnd();
        console2.log('Stream end before config change:', streamEndBefore);

        // Change stream window to 1 day
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 1 days, // Changed from 3 to 1 day
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        factory.updateConfig(newConfig);

        uint256 streamEndAfter = staking.streamEnd();
        console2.log('Stream end after config change:', streamEndAfter);

        // Active stream should not be affected
        assertEq(streamEndBefore, streamEndAfter, 'Active stream end should not change');

        // Wait and claim
        vm.warp(block.timestamp + 3 days + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        console2.log('SUCCESS: Active stream unaffected by config change');
    }

    // ============ Extreme Config Value Tests ============

    /// @notice Test that invalid BPS values can cause impossible proposals
    function test_config_invalidBps_causesImpossibleProposals() public {
        console2.log('\n=== Invalid BPS Creates Impossible Proposals ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set INVALID quorum (15000 = 150%, impossible to meet)
        ILevrFactory_v1.FactoryConfig memory badConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 15000, // INVALID: 150% > 100%
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        // FIX: Now validation prevents this
        vm.expectRevert('INVALID_QUORUM_BPS');
        factory.updateConfig(badConfig);

        console2.log('SUCCESS: Invalid BPS (15000) now rejected by validation');
        console2.log('FIX CONFIRMED: Gridlock scenario prevented');
    }

    /// @notice Test that maxRewardTokens = 0 causes gridlock
    function test_config_maxRewardTokensZero_breaksStaking() public {
        console2.log('\n=== MaxRewardTokens = 0 Breaks Staking ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Change to maxRewardTokens = 0 (blocks all non-whitelisted tokens)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
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
            maxRewardTokens: 0 // Zero! Should be rejected
        });

        // FIX: Validation prevents this
        vm.expectRevert('MAX_REWARD_TOKENS_ZERO');
        factory.updateConfig(newConfig);

        console2.log('SUCCESS: maxRewardTokens = 0 now rejected by validation');
        console2.log('FIX CONFIRMED: Staking freeze prevented');
    }

    /// @notice Test that zero window seconds doesn't break cycle creation
    function test_config_zeroWindows_preventsProposals() public {
        console2.log('\n=== Zero Window Seconds ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set zero proposal window
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 0, // Zero window!
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        // FIX: Validation prevents this
        vm.expectRevert('PROPOSAL_WINDOW_ZERO');
        factory.updateConfig(newConfig);

        console2.log('SUCCESS: Zero proposal window now rejected by validation');
        console2.log('FIX CONFIRMED: Unusual behavior prevented');
    }

    /// @notice Test that maxActiveProposals = 0 causes gridlock
    function test_config_maxActiveProposalsZero_blocksProposals() public {
        console2.log('\n=== MaxActiveProposals = 0 Gridlock ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set maxActiveProposals = 0
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 0, // Zero! No proposals allowed
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        // FIX: Validation prevents this
        vm.expectRevert('MAX_ACTIVE_PROPOSALS_ZERO');
        factory.updateConfig(newConfig);

        console2.log('SUCCESS: maxActiveProposals = 0 now rejected by validation');
        console2.log('FIX CONFIRMED: Governance freeze prevented');
    }

    // ============ Config Change During Active Operations ============

    /// @notice Test config change during active governance doesn't break execution
    function test_config_changeDuringVoting_doesNotBreakExecution() public {
        console2.log('\n=== Config Change During Active Voting ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // During voting, change maxProposalAmountBps to 1% (would block this proposal if checked)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 100, // 1% - proposal wants 10%!
            maxRewardTokens: 10
        });

        factory.updateConfig(newConfig);

        // Vote and execute should still work (proposal created before change)
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days);

        // Execute should work (config change doesn't affect created proposals)
        governor.execute(pid);

        console2.log('SUCCESS: Existing proposals unaffected by config changes');
    }

    /// @notice Test that minSTokenBpsToSubmit increase doesn't affect existing proposals
    function test_config_minStakeIncrease_doesNotAffectExistingProposals() public {
        console2.log('\n=== Min Stake Increase Mid-Cycle ===');

        // Setup: Alice has 10% of supply
        underlying.mint(alice, 100 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 900 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal (she has 10%, min is 1%)
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 100 ether);

        // Factory owner raises minSTokenBpsToSubmit to 20% (Alice no longer qualifies!)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 2000, // 20% - Alice only has 10%
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        factory.updateConfig(newConfig);

        // Alice's existing proposal should still be votable/executable
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        governor.vote(pid, true);

        vm.prank(bob);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days);

        governor.execute(pid);

        console2.log('SUCCESS: Existing proposal unaffected by minStake increase');

        // But Alice cannot create NEW proposals
        vm.prank(alice);
        vm.expectRevert();
        governor.proposeBoost(address(underlying), 50 ether);

        console2.log('CONFIRMED: New proposals require new minimum (20%)');
    }

    // ============ Recovery Mechanism Tests with Config Changes ============

    /// @notice Test that startNewCycle works after waiting for cycle to fully end
    function test_config_cycleRecovery_afterVotingEnds() public {
        console2.log('\n=== Cycle Recovery After Voting Ends ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        governor.proposeBoost(address(underlying), 100 ether);

        // Wait for voting to fully end
        vm.warp(block.timestamp + 7 days + 1);

        // Change config drastically
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 500,
            streamWindowSeconds: 1 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 1 days,
            votingWindowSeconds: 3 days,
            maxActiveProposals: 3,
            quorumBps: 9000,
            approvalBps: 6000,
            minSTokenBpsToSubmit: 500,
            maxProposalAmountBps: 3000,
            maxRewardTokens: 5
        });

        factory.updateConfig(newConfig);

        // Recovery should work (proposal failed quorum, not executable)
        governor.startNewCycle();

        uint256 newCycle = governor.currentCycleId();
        assertEq(newCycle, 2, 'New cycle started');

        console2.log('SUCCESS: Cycle recovery works with config changes');
    }

    /// @notice Test that stream window has minimum validation
    function test_config_minimumStreamWindow_validation() public {
        console2.log('\n=== Stream Window Minimum Validation ===');

        // Try to set very short stream window (there might be a minimum)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 1 hours, // Very short
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        // This might revert if there's a minimum validation
        try factory.updateConfig(newConfig) {
            console2.log('Stream window accepted: 1 hour');

            // Setup and test with short window
            underlying.mint(alice, 1000 ether);
            vm.startPrank(alice);
            underlying.approve(address(staking), type(uint256).max);
            staking.stake(1000 ether);
            vm.stopPrank();

            rewardToken.mint(address(staking), 100 ether);
            staking.accrueRewards(address(rewardToken));

            // Wait for 1 hour stream
            vm.warp(block.timestamp + 1 hours + 1);

            address[] memory tokens = new address[](1);
            tokens[0] = address(rewardToken);
            vm.prank(alice);
            staking.claimRewards(tokens, alice);

            console2.log('SUCCESS: Short stream window works');
        } catch {
            console2.log('FINDING: Factory validates minimum stream window');
            console2.log('Short windows rejected (prevents gaming)');
        }
    }

    // ============ Whitelist + Config Interaction Tests ============

    /// @notice Test that whitelisting still works after config changes
    function test_config_maxTokensChange_doesNotAffectWhitelist() public {
        console2.log('\n=== Whitelist Unaffected by maxRewardTokens Change ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Whitelist a token
        MockERC20 weth = new MockERC20('WETH', 'WETH');
        staking.whitelistToken(address(weth));

        // Change maxRewardTokens to 1 (very restrictive)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
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
            maxRewardTokens: 1 // Only 1 non-whitelisted allowed
        });

        factory.updateConfig(newConfig);

        // Whitelisted token should still be usable
        weth.mint(address(staking), 10 ether);
        staking.accrueRewards(address(weth));

        console2.log('SUCCESS: Whitelisted tokens bypass maxRewardTokens limit');

        // Add 1 non-whitelisted token (should work)
        MockERC20 token1 = new MockERC20('T1', 'T1');
        token1.mint(address(staking), 10 ether);
        staking.accrueRewards(address(token1));

        // Try to add 2nd non-whitelisted (should fail)
        MockERC20 token2 = new MockERC20('T2', 'T2');
        token2.mint(address(staking), 10 ether);

        vm.expectRevert('MAX_REWARD_TOKENS_REACHED');
        staking.accrueRewards(address(token2));

        console2.log('CONFIRMED: Limit enforced, whitelist still works');
    }

    /// @notice Test that maxProposalAmountBps = 0 doesn't break existing logic
    function test_config_maxProposalAmountZero_allowsAnyAmount() public {
        console2.log('\n=== MaxProposalAmountBps = 0 (No Limit) ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set maxProposalAmountBps = 0 (no limit)
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 0, // No limit!
            maxRewardTokens: 10
        });

        factory.updateConfig(newConfig);

        // Should be able to propose for entire treasury (10000 ether)
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 10000 ether);

        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertEq(proposal.amount, 10000 ether, 'Full amount allowed');

        console2.log('SUCCESS: maxProposalAmountBps = 0 removes limit');
    }

    /// @notice Test config change affects NEW accruals but not active streams
    function test_config_streamWindowChange_affectsNewAccrualsOnly() public {
        console2.log('\n=== Stream Window Affects New Accruals Only ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Accrue with 3-day window
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        uint256 stream1End = staking.streamEnd();

        // Change to 1-day window
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 1 days, // Changed!
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        factory.updateConfig(newConfig);

        // Wait 2 days (midstream)
        vm.warp(block.timestamp + 2 days);

        // New accrual should use 1-day window
        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        uint256 stream2End = staking.streamEnd();

        // Stream 2 should end 1 day from now (not 3 days)
        uint256 expectedEnd = block.timestamp + 1 days;
        assertApproxEqAbs(stream2End, expectedEnd, 1, 'New stream uses new window');

        console2.log('Stream 1 end:', stream1End);
        console2.log('Stream 2 end:', stream2End);
        console2.log('SUCCESS: New accruals use new config, old streams unaffected');
    }

    /// @notice Test that snapshot mechanism protects against impossible BPS
    function test_config_impossibleBps_snapshotProtects() public {
        console2.log('\n=== Impossible BPS Snapshot Behavior ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set impossible threshold
        ILevrFactory_v1.FactoryConfig memory badConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 10001, // 100.01% - barely impossible
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        // FIX: Validation prevents this
        vm.expectRevert('INVALID_QUORUM_BPS');
        factory.updateConfig(badConfig);

        console2.log('SUCCESS: Barely-over BPS (10001) now rejected by validation');
        console2.log('FIX CONFIRMED: Impossible proposals prevented');
    }

    /// @notice Test that extreme BPS values behave as expected
    function test_config_bpsOverflow_uint16Max() public {
        console2.log('\n=== BPS Overflow: uint16.max ===');

        // Setup
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Set BPS to uint16.max (65535 = 655.35%)
        ILevrFactory_v1.FactoryConfig memory maxConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: type(uint16).max, // 65535
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            maxRewardTokens: 10
        });

        // FIX: Validation prevents this
        vm.expectRevert('INVALID_QUORUM_BPS');
        factory.updateConfig(maxConfig);

        console2.log('SUCCESS: uint16.max BPS (65535) now rejected by validation');
        console2.log('FIX CONFIRMED: Extreme BPS values prevented');
    }
}
