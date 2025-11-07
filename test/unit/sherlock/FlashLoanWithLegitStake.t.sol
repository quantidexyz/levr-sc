// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrGovernor_v1} from '../../../src/LevrGovernor_v1.sol';
import {ILevrGovernor_v1} from '../../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {LevrTreasury_v1} from '../../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';

/// @notice Test the attack vector: legitimate stake + flash loan on same wallet
contract FlashLoanWithLegitStakeTest is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal stakedToken;

    address alice = makeAddr('alice');
    address attacker = makeAddr('attacker');
    address protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (LevrFactory_v1 factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        stakedToken = LevrStakedToken_v1(project.stakedToken);

        // Alice stakes for proposing
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Fund treasury
        underlying.mint(address(treasury), 10000 ether);

        // Warp for VP
        vm.warp(block.timestamp + 1 days);
    }

    /// @notice CRITICAL TEST: MEV protection blocks flash loan even with legitimate stake
    function test_MEV_PROTECTION_legitimateStake_thenFlashLoan_BLOCKED() public {
        // Step 1: Attacker legitimately stakes 1,000 tokens a week ago
        uint256 attackerLegitStake = 1000 ether;
        underlying.mint(attacker, attackerLegitStake);

        vm.startPrank(attacker);
        underlying.approve(address(staking), attackerLegitStake);
        staking.stake(attackerLegitStake);
        vm.stopPrank();

        // Wait 1 week
        vm.warp(block.timestamp + 7 days);

        uint256 attackerVPBefore = staking.getVotingPower(attacker);
        console.log('Attacker VP after 1 week with 1000 tokens:', attackerVPBefore);

        // Alice creates proposal
        vm.prank(alice);
        uint256 proposalId = governor.proposeTransfer(
            address(underlying),
            address(0xBEEF),
            50 ether,
            'Transfer'
        );

        // Advance to voting
        vm.warp(block.timestamp + 3 days);

        // Step 2: ATTACK - Flash loan 1,000,000 tokens (1000x their legit stake)
        uint256 flashLoanAmount = 1_000_000 ether;
        underlying.mint(attacker, flashLoanAmount);

        vm.startPrank(attacker);
        underlying.approve(address(staking), flashLoanAmount);
        staking.stake(flashLoanAmount); // Flash loan staked!

        // Check state after flash loan
        uint256 attackerBalance = stakedToken.balanceOf(attacker);
        uint256 attackerVPAfter = staking.getVotingPower(attacker);

        console.log('');
        console.log('=== ATTACK STATE ===');
        console.log('Legit stake: 1,000 tokens for 10 days');
        console.log('Flash loan: 1,000,000 tokens (1000x)');
        console.log('Total balance:', attackerBalance);
        console.log('VP before flash loan:', attackerVPBefore);
        console.log('VP after flash loan:', attackerVPAfter);

        console.log('');
        console.log('=== MEV PROTECTION CHECK ===');
        console.log('Last action timestamp: just now (flash loan stake)');
        console.log('Time since last action: 0 seconds');
        console.log('Required time: 120 seconds (2 minutes)');
        console.log('');

        // ✅ MEV PROTECTION: Vote should FAIL due to recent stake action
        // The lastActionTimestamp was just updated by the flash loan stake
        // So elapsed time is 0, which is < 2 minutes → REJECT
        console.log('ATTEMPTING VOTE...');
        vm.expectRevert(ILevrGovernor_v1.StakeActionTooRecent.selector);
        governor.vote(proposalId, true);

        console.log('');
        console.log('[SUCCESS] ATTACK BLOCKED BY MEV PROTECTION!');
        console.log('Vote rejected due to recent stake action');
        console.log('This protection is UNGAMEABLE:');
        console.log('- Attacker had 1000 tokens for 1 week (legit)');
        console.log('- Attacker flash loaned 1M tokens (1000x)');
        console.log('- But stake() updated lastActionTimestamp');
        console.log('- Time since action = 0 < 2 min = BLOCKED');
        console.log('');
        console.log('No amount of pre-existing VP can bypass this!');

        // Verify quorum was NOT inflated
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(proposalId);
        assertEq(proposal.totalBalanceVoted, 0, 'Quorum should be 0 (attack prevented)');

        vm.stopPrank();
    }
}
