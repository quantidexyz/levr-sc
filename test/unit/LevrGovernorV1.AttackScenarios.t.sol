// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Governance Attack Scenarios Unit Tests
/// @notice Tests coordinated attacks where quorum/approval are met but treasury is maliciously drained
/// @dev Focuses on TransferToAddress proposals with realistic VP accumulation (30+ days)
contract LevrGovernorV1_AttackScenarios is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    address internal protocolTreasury = address(0xDEAD);

    // Test actors
    address internal jonny = address(0x1111);
    address internal memo = address(0x2222);
    address internal attacker1 = address(0x3333);
    address internal attacker2 = address(0x4444);
    address internal attacker3 = address(0x5555);
    address internal attacker4 = address(0x6666);
    address internal honest1 = address(0x7777);
    address internal honest2 = address(0x8888);
    address internal honest3 = address(0x9999);
    address internal maliciousRecipient = address(0xBAD);

    uint256 internal constant TOTAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        // Realistic config: 70% quorum, 51% approval, 1% min stake
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        cfg.quorumBps = 7000; // 70% participation required
        cfg.approvalBps = 5100; // 51% approval required
        cfg.minSTokenBpsToSubmit = 100; // 1% stake to propose

        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        // Prepare infrastructure before registering
        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        // Fund treasury with substantial balance for attack tests
        underlying.mint(address(treasury), TOTAL_SUPPLY * 2);
    }

    /// @dev Helper to stake tokens for a user and warp time for VP accumulation
    function _stakeAndAccumulateVP(address user, uint256 amount, uint256 daysToWarp) internal {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        if (daysToWarp > 0) {
            vm.warp(block.timestamp + daysToWarp * 1 days);
        }
    }

    /// @dev Helper to calculate expected VP (balance * days staked)
    function _calculateExpectedVP(
        uint256 balance,
        uint256 daysStaked
    ) internal pure returns (uint256) {
        return balance * daysStaked;
    }

    /// @dev Helper to get percentage with 2 decimals (e.g., 7000 = 70.00%)
    function _getPercentage(uint256 part, uint256 whole) internal pure returns (uint256) {
        return (part * 10_000) / whole;
    }

    // ============================================================================
    // Attack Scenario 1: Minority Abstention Attack
    // ============================================================================
    /// @notice Jonny (5%) and Memo (3%) unavailable → attackers drain treasury
    /// @dev Despite 8% being absent, attackers coordinate 60% to overcome 32% honest votes
    function test_attack_minority_abstention_allows_treasury_drain() public {
        console2.log('\n=== ATTACK 1: Minority Abstention ===');

        // SETUP: Distribute tokens realistically
        uint256 jonnyAmount = (TOTAL_SUPPLY * 5) / 100; // 5%
        uint256 memoAmount = (TOTAL_SUPPLY * 3) / 100; // 3%
        uint256 attacker1Amount = (TOTAL_SUPPLY * 20) / 100; // 20%
        uint256 attacker2Amount = (TOTAL_SUPPLY * 20) / 100; // 20%
        uint256 attacker3Amount = (TOTAL_SUPPLY * 20) / 100; // 20%
        uint256 honest1Amount = (TOTAL_SUPPLY * 16) / 100; // 16%
        uint256 honest2Amount = (TOTAL_SUPPLY * 16) / 100; // 16%

        // Everyone stakes at T0
        _stakeAndAccumulateVP(jonny, jonnyAmount, 0);
        _stakeAndAccumulateVP(memo, memoAmount, 0);
        _stakeAndAccumulateVP(attacker1, attacker1Amount, 0);
        _stakeAndAccumulateVP(attacker2, attacker2Amount, 0);
        _stakeAndAccumulateVP(attacker3, attacker3Amount, 0);
        _stakeAndAccumulateVP(honest1, honest1Amount, 0);
        _stakeAndAccumulateVP(honest2, honest2Amount, 0);

        // Accumulate VP over 30 days
        vm.warp(block.timestamp + 30 days);

        console2.log('Stake Distribution:');
        console2.log('  Jonny (unavailable):', jonnyAmount / 1e18, 'tokens (5%)');
        console2.log('  Memo (unavailable):', memoAmount / 1e18, 'tokens (3%)');
        console2.log(
            '  Attacker coalition:',
            (attacker1Amount + attacker2Amount + attacker3Amount) / 1e18,
            'tokens (60%)'
        );
        console2.log('  Honest users:', (honest1Amount + honest2Amount) / 1e18, 'tokens (32%)');

        // ATTACK: Attacker1 creates malicious proposal to drain treasury
        uint256 drainAmount = 50_000 ether;
        vm.prank(attacker1);
        uint256 pid = governor.proposeTransfer(address(underlying), maliciousRecipient, drainAmount, 'Malicious drain');

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Attackers vote YES (60% of tokens voting)
        vm.prank(attacker1);
        governor.vote(pid, true);
        vm.prank(attacker2);
        governor.vote(pid, true);
        vm.prank(attacker3);
        governor.vote(pid, true);

        // Honest users vote NO (32% of tokens voting)
        vm.prank(honest1);
        governor.vote(pid, false);
        vm.prank(honest2);
        governor.vote(pid, false);

        // Jonny and Memo are ABSENT (8% not voting)

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // VERIFY ATTACK SUCCESS
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);

        // Check quorum: 60% + 32% = 92% participation
        uint256 totalSupply = sToken.totalSupply();
        uint256 quorumPct = _getPercentage(proposal.totalBalanceVoted, totalSupply);
        console2.log('\nQuorum Check:');
        console2.log('  Total voted:', proposal.totalBalanceVoted / 1e18, 'tokens');
        console2.log('  Participation: %d.%02d%%', quorumPct / 100, quorumPct % 100);
        assertGt(quorumPct, 7000, 'Should meet 70% quorum');
        assertTrue(governor.meetsQuorum(pid), 'Quorum met');

        // Check approval: Attackers 60% vs Honest 32% → 60/(60+32) = 65.2% approval
        uint256 approvalPct = _getPercentage(
            proposal.yesVotes,
            proposal.yesVotes + proposal.noVotes
        );
        console2.log('\nApproval Check:');
        console2.log('  YES votes (VP):', proposal.yesVotes / 1e18);
        console2.log('  NO votes (VP):', proposal.noVotes / 1e18);
        console2.log('  Approval: %d.%02d%%', approvalPct / 100, approvalPct % 100);
        assertGt(approvalPct, 5100, 'Should meet 51% approval');
        assertTrue(governor.meetsApproval(pid), 'Approval met');

        // Execute attack
        uint256 treasuryBalanceBefore = underlying.balanceOf(address(treasury));
        uint256 recipientBalanceBefore = underlying.balanceOf(maliciousRecipient);

        governor.execute(pid);

        uint256 treasuryBalanceAfter = underlying.balanceOf(address(treasury));
        uint256 recipientBalanceAfter = underlying.balanceOf(maliciousRecipient);

        console2.log('\n[ATTACK SUCCESS] Treasury drained:');
        console2.log(
            '  Treasury lost:',
            (treasuryBalanceBefore - treasuryBalanceAfter) / 1e18,
            'tokens'
        );
        console2.log(
            '  Attacker gained:',
            (recipientBalanceAfter - recipientBalanceBefore) / 1e18,
            'tokens'
        );

        assertEq(
            treasuryBalanceBefore - treasuryBalanceAfter,
            drainAmount,
            'Treasury should lose exact amount'
        );
        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            drainAmount,
            'Recipient should gain exact amount'
        );

        // Verify proposal is marked as executed
        ILevrGovernor_v1.Proposal memory proposalAfter = governor.getProposal(pid);
        assertTrue(proposalAfter.executed, 'Malicious proposal executed');
    }

    // ============================================================================
    // Attack Scenario 2: Early Staker Whale Attack
    // ============================================================================
    /// @notice Early stakers (35% tokens, 60 days) have majority VP over late majority (65% tokens, 7 days)
    /// @dev Time-weighting allows minority token holders to control governance
    function test_attack_early_staker_whales_control_via_vp() public {
        console2.log('\n=== ATTACK 2: Early Staker Whale Attack ===');

        // SETUP: Early whales stake and accumulate VP
        uint256 whale1Amount = (TOTAL_SUPPLY * 12) / 100; // 12%
        uint256 whale2Amount = (TOTAL_SUPPLY * 12) / 100; // 12%
        uint256 whale3Amount = (TOTAL_SUPPLY * 11) / 100; // 11%
        // Total whales: 35%

        _stakeAndAccumulateVP(attacker1, whale1Amount, 60); // 60 days early
        _stakeAndAccumulateVP(attacker2, whale2Amount, 60);
        _stakeAndAccumulateVP(attacker3, whale3Amount, 60);

        console2.log('Early Whales (60 days staking):');
        console2.log(
            '  Total tokens:',
            (whale1Amount + whale2Amount + whale3Amount) / 1e18,
            '(35%)'
        );
        uint256 whaleVP = _calculateExpectedVP(whale1Amount + whale2Amount + whale3Amount, 60);
        console2.log('  Expected VP:', whaleVP / 1e18, 'token-days');

        // Late majority stakes recently (warp back, then forward)
        vm.warp(block.timestamp - 53 days); // Back to 7 days after whales

        // Distribute 65% among late majority (10 wallets)
        address[] memory lateMajority = new address[](10);
        uint256 lateStakeEach = (TOTAL_SUPPLY * 65) / 1000; // 6.5% each
        uint256 totalLateStake = 0;

        for (uint256 i = 0; i < 10; i++) {
            lateMajority[i] = address(uint160(0xAAAA + i));
            _stakeAndAccumulateVP(lateMajority[i], lateStakeEach, 0);
            totalLateStake += lateStakeEach;
        }

        // Warp forward 7 days (late majority has 7 days VP, whales have 60 days)
        vm.warp(block.timestamp + 7 days);

        console2.log('Late Majority (7 days staking):');
        console2.log('  Total tokens:', totalLateStake / 1e18, '(65%)');
        uint256 lateVP = _calculateExpectedVP(totalLateStake, 7);
        console2.log('  Expected VP:', lateVP / 1e18, 'token-days');

        console2.log('\nVP Comparison:');
        console2.log('  Whale VP:', whaleVP / 1e18, 'token-days (35% tokens, 60 days)');
        console2.log('  Late VP:', lateVP / 1e18, 'token-days (65% tokens, 7 days)');
        console2.log('  Whale advantage:', (whaleVP * 100) / lateVP, '%');

        // ATTACK: Whales propose malicious transfer
        uint256 drainAmount = 50_000 ether;
        vm.prank(attacker1);
        uint256 pid = governor.proposeTransfer(address(underlying), maliciousRecipient, drainAmount, 'Whale attack');

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // All whales vote YES
        vm.prank(attacker1);
        governor.vote(pid, true);
        vm.prank(attacker2);
        governor.vote(pid, true);
        vm.prank(attacker3);
        governor.vote(pid, true);

        // 8 out of 10 late majority vote NO (52% of total tokens voting NO)
        for (uint256 i = 0; i < 8; i++) {
            vm.prank(lateMajority[i]);
            governor.vote(pid, false);
        }
        // 2 abstain

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // VERIFY ATTACK SUCCESS
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);

        // Quorum: 35% (whales) + 52% (8/10 late) = 87%
        uint256 totalSupply = sToken.totalSupply();
        uint256 quorumPct = _getPercentage(proposal.totalBalanceVoted, totalSupply);
        console2.log('\nQuorum: %d.%02d%% [PASS]', quorumPct / 100, quorumPct % 100);
        assertTrue(governor.meetsQuorum(pid), 'Quorum met');

        // Approval: Despite 35% vs 52% token split, whales have MORE VP (60 days vs 7 days)
        uint256 approvalPct = _getPercentage(
            proposal.yesVotes,
            proposal.yesVotes + proposal.noVotes
        );
        console2.log('Approval: %d.%02d%% [PASS]', approvalPct / 100, approvalPct % 100);

        console2.log('\n[CRITICAL] Whales (35% tokens) override Late Majority (52% tokens) via VP');
        assertGt(proposal.yesVotes, proposal.noVotes, 'Whales have more VP despite fewer tokens');
        assertTrue(governor.meetsApproval(pid), 'Approval met via time-weighting');

        // Execute attack
        uint256 treasuryBalanceBefore = underlying.balanceOf(address(treasury));
        governor.execute(pid);
        uint256 treasuryBalanceAfter = underlying.balanceOf(address(treasury));

        console2.log(
            '\n[ATTACK SUCCESS] Early staker whales drained:',
            (treasuryBalanceBefore - treasuryBalanceAfter) / 1e18,
            'tokens'
        );
        assertEq(treasuryBalanceBefore - treasuryBalanceAfter, drainAmount, 'Treasury drained');
    }

    // ============================================================================
    // Attack Scenario 3: Strategic Low Participation Attack
    // ============================================================================
    /// @notice Attackers (37%) coordinate to barely meet quorum with 35% honest opposition
    /// @dev 72% participation (just above 70%) with 51.4% approval → malicious execution
    function test_attack_strategic_low_participation_bare_quorum() public {
        console2.log('\n=== ATTACK 3: Strategic Low Participation Attack ===');

        // SETUP: Distribute tokens for bare quorum attack
        uint256 attackerAmount = (TOTAL_SUPPLY * 37) / 100; // 37%
        uint256 honestAmount = (TOTAL_SUPPLY * 35) / 100; // 35%
        uint256 apatheticAmount = (TOTAL_SUPPLY * 28) / 100; // 28% won't vote

        _stakeAndAccumulateVP(attacker1, attackerAmount, 0);
        _stakeAndAccumulateVP(honest1, honestAmount, 0);
        _stakeAndAccumulateVP(honest2, apatheticAmount, 0); // Will not participate

        // Accumulate VP over 30 days (equal for all)
        vm.warp(block.timestamp + 30 days);

        console2.log('Token Distribution:');
        console2.log('  Attackers:', attackerAmount / 1e18, 'tokens (37%)');
        console2.log('  Honest (active):', honestAmount / 1e18, 'tokens (35%)');
        console2.log('  Apathetic (inactive):', apatheticAmount / 1e18, 'tokens (28%)');
        console2.log('  Expected participation: 37% + 35% = 72% (just above 70% quorum)');

        // ATTACK: Create malicious proposal
        uint256 drainAmount = 50_000 ether;
        vm.prank(attacker1);
        uint256 pid = governor.proposeTransfer(address(underlying), 
            maliciousRecipient,
            drainAmount,
            'Barely meets quorum'
        );

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // Attacker votes YES (37%)
        vm.prank(attacker1);
        governor.vote(pid, true);

        // Honest user votes NO (35%)
        vm.prank(honest1);
        governor.vote(pid, false);

        // Apathetic does NOT vote (28%)

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // VERIFY ATTACK SUCCESS
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);

        // Quorum: 37% + 35% = 72% (just above 70% threshold)
        uint256 totalSupply = sToken.totalSupply();
        uint256 quorumPct = _getPercentage(proposal.totalBalanceVoted, totalSupply);
        console2.log('\nQuorum Analysis:');
        console2.log('  Participation: %d.%02d%%', quorumPct / 100, quorumPct % 100);
        console2.log('  Required: 70.00%');
        console2.log(
            '  Margin: %d.%02d%% above minimum',
            (quorumPct - 7000) / 100,
            (quorumPct - 7000) % 100
        );
        assertEq(quorumPct, 7200, 'Should be exactly 72%');
        assertTrue(governor.meetsQuorum(pid), 'Barely meets quorum');

        // Approval: 37/(37+35) = 51.4% (just above 51% threshold)
        uint256 approvalPct = _getPercentage(
            proposal.yesVotes,
            proposal.yesVotes + proposal.noVotes
        );
        console2.log('\nApproval Analysis:');
        console2.log('  YES votes: %d.%02d%%', approvalPct / 100, approvalPct % 100);
        console2.log('  Required: 51.00%');
        console2.log(
            '  Margin: %d.%02d%% above minimum',
            (approvalPct - 5100) / 100,
            (approvalPct - 5100) % 100
        );
        assertGt(approvalPct, 5100, 'Barely meets approval');
        assertTrue(governor.meetsApproval(pid), 'Barely meets approval');

        console2.log('\n[CRITICAL] Attack succeeds with minimal participation');
        console2.log('  - ALL active honest users voted NO');
        console2.log('  - Yet proposal passes due to apathy (28% inactive)');

        // Execute attack
        uint256 treasuryBalanceBefore = underlying.balanceOf(address(treasury));
        governor.execute(pid);
        uint256 treasuryBalanceAfter = underlying.balanceOf(address(treasury));

        console2.log(
            '\n[ATTACK SUCCESS] Treasury drained:',
            (treasuryBalanceBefore - treasuryBalanceAfter) / 1e18,
            'tokens'
        );
        assertEq(treasuryBalanceBefore - treasuryBalanceAfter, drainAmount, 'Treasury drained');
    }

    // ============================================================================
    // Attack Scenario 4: Competitive Proposal Winner Manipulation
    // ============================================================================
    /// @notice Multiple proposals in cycle, attackers manipulate winner selection
    /// @dev 3 proposals all meet quorum/approval, but malicious P2 wins with highest YES votes
    function test_attack_competitive_proposal_winner_manipulation() public {
        console2.log('\n=== ATTACK 4: Competitive Proposal Winner Manipulation ===');

        // SETUP: Distribute tokens
        uint256 attackerAmount = (TOTAL_SUPPLY * 40) / 100; // 40% attacker coalition
        uint256 honest1Amount = (TOTAL_SUPPLY * 25) / 100; // 25%
        uint256 honest2Amount = (TOTAL_SUPPLY * 20) / 100; // 20%
        uint256 honest3Amount = (TOTAL_SUPPLY * 15) / 100; // 15%

        _stakeAndAccumulateVP(attacker1, attackerAmount, 0);
        _stakeAndAccumulateVP(honest1, honest1Amount, 0);
        _stakeAndAccumulateVP(honest2, honest2Amount, 0);
        _stakeAndAccumulateVP(honest3, honest3Amount, 0);

        // Accumulate VP over 30 days
        vm.warp(block.timestamp + 30 days);

        console2.log('Stake Distribution:');
        console2.log('  Attacker coalition:', attackerAmount / 1e18, 'tokens (40%)');
        console2.log('  Honest users: 25% + 20% + 15% = 60%');

        // CREATE 3 PROPOSALS IN SAME CYCLE
        // P1: Benign boost proposal (decoy)
        vm.prank(honest1);
        uint256 pid1 = governor.proposeBoost(address(underlying), 100_000 ether);

        // P2: Malicious transfer to attacker (REAL TARGET)
        vm.prank(attacker1);
        uint256 pid2 = governor.proposeTransfer(address(underlying), 
            maliciousRecipient,
            50_000 ether,
            'Malicious proposal disguised'
        );

        // P3: Benign transfer to legitimate address (another decoy)
        address legitimateRecipient = address(0x1E617);
        vm.prank(honest2);
        uint256 pid3 = governor.proposeTransfer(address(underlying), 
            legitimateRecipient,
            50_000 ether,
            'Legitimate ops'
        );

        console2.log('\n3 Proposals Created:');
        console2.log('  P1: Boost staking (benign decoy)');
        console2.log('  P2: Transfer to attacker (MALICIOUS)');
        console2.log('  P3: Transfer to legit address (benign)');

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // STRATEGIC VOTING: Attackers manipulate to make P2 the winner

        // P1 voting: Honest users like it, attackers vote NO strategically
        vm.prank(honest1);
        governor.vote(pid1, true); // 25% YES
        vm.prank(honest2);
        governor.vote(pid1, true); // 20% YES
        vm.prank(honest3);
        governor.vote(pid1, true); // 15% YES
        vm.prank(attacker1);
        governor.vote(pid1, false); // 40% NO
        // P1: 60% YES, 40% NO (meets approval) - Total: 100% quorum

        // P2 voting: Attackers go ALL IN, some honest users fooled or vote NO
        vm.prank(attacker1);
        governor.vote(pid2, true); // 40% YES
        vm.prank(honest1);
        governor.vote(pid2, true); // 25% YES (fooled by description)
        vm.prank(honest2);
        governor.vote(pid2, false); // 20% NO (recognized threat)
        vm.prank(honest3);
        governor.vote(pid2, false); // 15% NO
        // P2: 65% YES, 35% NO (meets approval) - Total: 100% quorum

        // P3 voting: Honest users support, attackers vote NO to reduce its YES votes
        vm.prank(honest1);
        governor.vote(pid3, true); // 25% YES
        vm.prank(honest2);
        governor.vote(pid3, true); // 20% YES
        vm.prank(honest3);
        governor.vote(pid3, true); // 15% YES
        vm.prank(attacker1);
        governor.vote(pid3, false); // 40% NO
        // P3: 60% YES, 40% NO (meets approval) - Total: 100% quorum

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // VERIFY ALL PROPOSALS MEET REQUIREMENTS
        console2.log('\nProposal Results:');

        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        console2.log('  P1 (Boost): YES=', p1.yesVotes / 1e18, 'NO=', p1.noVotes / 1e18);
        assertTrue(governor.meetsQuorum(pid1), 'P1 meets quorum');
        assertTrue(governor.meetsApproval(pid1), 'P1 meets approval');

        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);
        console2.log(
            '  P2 (Malicious): YES=%d NO=%d [HIGHEST YES]',
            p2.yesVotes / 1e18,
            p2.noVotes / 1e18
        );
        assertTrue(governor.meetsQuorum(pid2), 'P2 meets quorum');
        assertTrue(governor.meetsApproval(pid2), 'P2 meets approval');

        ILevrGovernor_v1.Proposal memory p3 = governor.getProposal(pid3);
        console2.log('  P3 (Legit): YES=%d NO=%d', p3.yesVotes / 1e18, p3.noVotes / 1e18);
        assertTrue(governor.meetsQuorum(pid3), 'P3 meets quorum');
        assertTrue(governor.meetsApproval(pid3), 'P3 meets approval');

        // VERIFY P2 WINS (highest YES votes)
        uint256 winner = governor.getWinner(1);
        console2.log('\n[CRITICAL] Winner is P2 (malicious) despite 60% honest majority');
        assertEq(winner, pid2, 'P2 should be winner');
        assertGt(p2.yesVotes, p1.yesVotes, 'P2 has more YES votes than P1');
        assertGt(p2.yesVotes, p3.yesVotes, 'P2 has more YES votes than P3');

        // Execute attack
        uint256 treasuryBalanceBefore = underlying.balanceOf(address(treasury));
        governor.execute(pid2);
        uint256 treasuryBalanceAfter = underlying.balanceOf(address(treasury));

        console2.log(
            '\n[ATTACK SUCCESS] Malicious proposal won and drained:',
            (treasuryBalanceBefore - treasuryBalanceAfter) / 1e18,
            'tokens'
        );
        assertEq(treasuryBalanceBefore - treasuryBalanceAfter, 50_000 ether, 'Treasury drained');
        assertEq(underlying.balanceOf(maliciousRecipient), 50_000 ether, 'Attacker received funds');

        // Verify other proposals CANNOT execute (cycle advanced after winner executed)
        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(pid1);

        vm.expectRevert(ILevrGovernor_v1.ProposalNotInCurrentCycle.selector);
        governor.execute(pid3);
    }

    // ============================================================================
    // Attack Scenario 5: Sybil Multi-Wallet Treasury Drain
    // ============================================================================
    /// @notice Single entity controls 75%+ via multiple wallets → guaranteed drain
    /// @dev Entity controls both quorum (75% > 70%) and approval (75% > 51%)
    function test_attack_sybil_multi_wallet_guaranteed_drain() public {
        console2.log('\n=== ATTACK 5: Sybil Multi-Wallet Treasury Drain ===');

        // SETUP: Single entity distributes 75% across 10 wallets
        address[] memory sybilWallets = new address[](10);
        uint256 sybilPerWallet = (TOTAL_SUPPLY * 75) / 1000; // 7.5% each = 75% total
        uint256 totalSybilStake = 0;

        console2.log('Sybil Entity Setup:');
        for (uint256 i = 0; i < 10; i++) {
            sybilWallets[i] = address(uint160(0xBAD1 + i));
            // Stake at slightly different times (25-35 days range)
            uint256 daysStaked = 25 + i;
            _stakeAndAccumulateVP(sybilWallets[i], sybilPerWallet, daysStaked);
            totalSybilStake += sybilPerWallet;
            console2.log(
                '  Wallet %d: %d tokens, %d days',
                i + 1,
                sybilPerWallet / 1e18,
                daysStaked
            );
        }

        // Honest users (25% total, 20 days staking)
        vm.warp(block.timestamp - 15 days); // Back to get 20 days from present
        uint256 honestAmount = (TOTAL_SUPPLY * 25) / 100;
        _stakeAndAccumulateVP(honest1, honestAmount, 20);

        console2.log('\nHonest Users:');
        console2.log('  Total:', honestAmount / 1e18, 'tokens (25%), 20 days staking');

        console2.log('\nControl Analysis:');
        console2.log('  Sybil entity: 75% of tokens (guaranteed quorum)');
        console2.log('  Sybil entity: 75% of VP (guaranteed approval)');
        console2.log('  Honest minority: 25% (cannot stop attack)');

        // ATTACK: Entity proposes MAXIMUM treasury drain
        vm.prank(sybilWallets[0]);
        uint256 pid = governor.proposeTransfer(address(underlying), 
            maliciousRecipient,
            50_000 ether,
            'Complete treasury takeover'
        );

        // Warp to voting window
        vm.warp(block.timestamp + 2 days + 1);

        // All sybil wallets vote YES (75% guaranteed)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(sybilWallets[i]);
            governor.vote(pid, true);
        }

        // Honest user votes NO (25% - futile)
        vm.prank(honest1);
        governor.vote(pid, false);

        // Warp to end of voting
        vm.warp(block.timestamp + 5 days + 1);

        // Execute: Sybil entity drains treasury
        uint256 treasuryBalanceBefore = underlying.balanceOf(address(treasury));
        governor.execute(pid);
        uint256 treasuryBalanceAfter = underlying.balanceOf(address(treasury));

        console2.log('\nAttack Outcome:');
        console2.log('  Treasury drained:', treasuryBalanceBefore - treasuryBalanceAfter, 'tokens');
        console2.log('  Attack succeeded: Treasury drained despite 25% opposition');

        assertEq(treasuryBalanceBefore - treasuryBalanceAfter, 50_000 ether, 'Treasury drained');
    }
}
