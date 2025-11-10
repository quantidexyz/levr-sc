// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';

import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../../../src/LevrDeployer_v1.sol';
import {LevrGovernor_v1} from '../../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title LevrGovernorDoS Test
 * @notice POC for Sherlock audit finding: Winner proposal can block governance
 * @dev Tests FAIL when vulnerability exists (current state)
 *
 * VULNERABILITY: Malicious token can permanently freeze governance via:
 * 1. balanceOf hard revert (outside try-catch)
 * 2. Gas bomb in transfer (OOG after try-catch)
 * 3. Revert data bomb (OOG during revert data copy)
 *
 * EXPECTED BEHAVIOR:
 * - Malicious proposals should be defeated gracefully
 * - Governance should continue to next cycle
 * - No permanent DoS
 *
 * ACTUAL BEHAVIOR (VULNERABLE):
 * - balanceOf revert → entire execute() reverts
 * - Gas bomb → OOG after try-catch, state rolled back
 * - Revert bomb → OOG during catch, state rolled back
 * - Proposal stays in Succeeded state
 * - Cycle cannot advance
 * - Governance permanently frozen
 */
contract LevrGovernorDoS_Test is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    MockERC20 internal underlying;
    MaliciousBalanceOfToken internal maliciousBalanceOf;
    GasBombToken internal gasBomb;
    RevertBombToken internal revertBomb;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);
    address internal protocolTreasury = address(0xDEAD);

    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        // Deploy factory with governance config
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000, // 70%
            approvalBps: 5100, // 51%
            minSTokenBpsToSubmit: 100, // 1%
            maxProposalAmountBps: 500, // 5%
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        // Register project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        // Deploy malicious tokens (mint to treasury in constructor)
        maliciousBalanceOf = new MaliciousBalanceOfToken(address(treasury), 100_000 ether);
        gasBomb = new GasBombToken(address(treasury), 100_000 ether);
        revertBomb = new RevertBombToken(address(treasury), 100_000 ether);

        // Fund users
        underlying.mint(alice, INITIAL_SUPPLY);
        underlying.mint(bob, INITIAL_SUPPLY);
        underlying.mint(attacker, INITIAL_SUPPLY);

        // Users stake to get voting power
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(50_000 ether); // 50% voting power
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(30_000 ether); // 30% voting power
        vm.stopPrank();

        vm.startPrank(attacker);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(20_000 ether); // 20% voting power
        vm.stopPrank();

        // Fund treasury with underlying token
        underlying.mint(address(treasury), 100_000 ether);

        // Label addresses
        vm.label(alice, 'Alice');
        vm.label(bob, 'Bob');
        vm.label(attacker, 'Attacker');
        vm.label(address(governor), 'Governor');
        vm.label(address(treasury), 'Treasury');
        vm.label(address(staking), 'Staking');
        vm.label(address(maliciousBalanceOf), 'MaliciousBalanceOf');
        vm.label(address(gasBomb), 'GasBomb');
        vm.label(address(revertBomb), 'RevertBomb');
    }

    /**
     * @notice Helper: Create and vote on proposal
     */
    function _createAndPassProposal(
        address token,
        uint256 amount,
        address recipient
    ) internal returns (uint256 proposalId) {
        // Attacker creates malicious proposal
        vm.prank(attacker);
        proposalId = governor.proposeTransfer(token, recipient, amount, 'Malicious Proposal');

        // Fast forward to voting period
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility

        // Alice and Bob vote FOR (51% approval)
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.prank(bob);
        governor.vote(proposalId, true);

        // Fast forward past voting period
        vm.warp(block.timestamp + 5 days + 1);

        return proposalId;
    }

    // ============================================================================
    // ATTACK VECTOR 1: balanceOf Hard Revert (DEFINITE BLOCKER)
    // ============================================================================

    /**
     * @notice TEST 1: balanceOf revert blocks governance permanently
     * @dev This test demonstrates the DEFINITE BLOCKER attack vector
     *
     * ATTACK FLOW:
     * 1. Attacker deploys MaliciousBalanceOfToken that reverts on balanceOf(treasury)
     * 2. Attacker creates proposal to transfer this token
     * 3. Proposal wins vote
     * 4. Anyone calls execute(proposalId)
     * 5. Line 175: balanceOf(treasury) REVERTS (outside try-catch)
     * 6. Entire execute() transaction reverts
     * 7. Proposal stays in Succeeded state
     * 8. Cycle cannot advance
     * 9. Governance permanently frozen
     *
     * EXPECTED (CORRECT BEHAVIOR):
     * - Malicious proposal should be marked defeated
     * - Governance should continue
     * - Next proposal should be executable
     *
     * ACTUAL (VULNERABLE):
     * - execute() reverts with "GovernanceDoS"
     * - Proposal remains in Succeeded state
     * - Cannot execute, cannot advance cycle
     * - Governance frozen
     */
    function test_attackVector1_balanceOfRevertBlocksGovernance() public {
        console2.log('\n=== Attack Vector 1: balanceOf Hard Revert ===\n');

        // Create malicious proposal (balanceOf works during propose)
        uint256 maliciousProposalId = _createAndPassProposal(
            address(maliciousBalanceOf),
            100 ether,
            alice
        );

        console2.log('Malicious proposal created and passed vote');
        console2.log('Proposal ID:', maliciousProposalId);
        console2.log('Token:', address(maliciousBalanceOf));
        console2.log('');

        // Check state before execution
        ILevrGovernor_v1.ProposalState stateBefore = governor.state(maliciousProposalId);
        console2.log('State before execute:', uint256(stateBefore));
        assertEq(
            uint256(stateBefore),
            uint256(ILevrGovernor_v1.ProposalState.Succeeded),
            'Proposal should be in Succeeded state'
        );

        // Activate the malicious behavior (now balanceOf will revert)
        console2.log('Activating malicious balanceOf behavior...');
        maliciousBalanceOf.activate();
        console2.log('');

        // ASSERTION: execute() should NOT revert (correct behavior)
        // This will FAIL now because execute() DOES revert
        // After fix, this will PASS because execute() handles gracefully
        console2.log('Attempting to execute malicious proposal...');
        console2.log('ASSERTION: execute() should NOT revert');
        console2.log('');

        // This is what we WANT to happen (graceful handling)
        // Currently FAILS because balanceOf reverts
        governor.execute(maliciousProposalId);

        // If we reach here, execution succeeded (will only happen after fix)
        console2.log('Execute succeeded - malicious proposal handled gracefully');
        console2.log('');

        // Check state after execution - should be Executed or Defeated
        ILevrGovernor_v1.ProposalState stateAfter = governor.state(maliciousProposalId);
        console2.log('State after execute:', uint256(stateAfter));

        // ASSERTION: Proposal should be in Executed or Defeated state (not Succeeded)
        assertTrue(
            stateAfter == ILevrGovernor_v1.ProposalState.Executed ||
                stateAfter == ILevrGovernor_v1.ProposalState.Defeated,
            'Proposal should be Executed or Defeated, not stuck in Succeeded'
        );

        // Cycle does NOT auto-advance (advances on next propose)
        uint256 cycleIdAfter = governor.currentCycleId();
        console2.log('Cycle ID after execute:', cycleIdAfter);
        assertEq(cycleIdAfter, 1, 'Cycle does NOT auto-advance');
        
        // Create next proposal to trigger cycle advancement
        vm.prank(attacker);
        uint256 pid2 = governor.proposeTransfer(address(underlying), alice, 10 ether, 'Next');
        assertGt(governor.currentCycleId(), 1, 'Cycle advances on next propose');

        console2.log('');
        console2.log('[TEST SHOULD FAIL BEFORE FIX - Vulnerability exists]');
        console2.log('[EXPECTED BEFORE]: execute() reverts with GovernanceDoS');
        console2.log(
            '[ACTUAL AFTER FIX]: execute() succeeds, malicious proposal handled gracefully'
        );
    }

    // ============================================================================
    // ATTACK VECTOR 2: Gas Bomb (CONDITIONAL BLOCKER)
    // ============================================================================

    /**
     * @notice TEST 2: Gas bomb in transfer blocks governance
     * @dev This test demonstrates the GAS BOMB attack vector
     *
     * ATTACK FLOW:
     * 1. Attacker deploys GasBombToken that consumes 63/64 of gas in transfer
     * 2. Proposal to transfer this token wins vote
     * 3. execute() reaches try-catch block
     * 4. _executeProposal() calls treasury.transfer()
     * 5. Token's transfer() consumes 63/64 of remaining gas
     * 6. Try-catch catches the revert, BUT insufficient gas remains
     * 7. Transaction runs out of gas
     * 8. State rollback: proposal.executed and cycle.executed reset to false
     * 9. Governance frozen (can retry but always fails)
     *
     * EXPECTED (CORRECT BEHAVIOR):
     * - Gas-limited execution prevents gas bomb
     * - Proposal marked executed (even if failed)
     * - Governance continues
     *
     * ACTUAL (VULNERABLE):
     * - OOG after try-catch
     * - State rolled back
     * - Governance frozen
     */
    function test_attackVector2_gasBombBlocksGovernance() public {
        console2.log('\n=== Attack Vector 2: Gas Bomb in Transfer ===\n');

        // Create malicious proposal
        uint256 maliciousProposalId = _createAndPassProposal(address(gasBomb), 100 ether, alice);

        console2.log('Gas bomb proposal created and passed vote');
        console2.log('Proposal ID:', maliciousProposalId);
        console2.log('Token:', address(gasBomb));
        console2.log('');

        // Check initial state
        ILevrGovernor_v1.ProposalState stateBefore = governor.state(maliciousProposalId);
        assertEq(
            uint256(stateBefore),
            uint256(ILevrGovernor_v1.ProposalState.Succeeded),
            'Proposal should be in Succeeded state'
        );

        // ASSERTION: execute() should complete even with gas bomb
        console2.log('Executing with gas bomb...');
        console2.log('ASSERTION: Should handle gracefully');
        console2.log('');

        // Execute should handle gas bomb
        governor.execute(maliciousProposalId);

        console2.log('Execute completed successfully');
        console2.log('');

        // ASSERTION: Proposal should be finalized
        ILevrGovernor_v1.ProposalState stateAfter = governor.state(maliciousProposalId);
        console2.log('State after execute:', uint256(stateAfter));

        assertTrue(
            stateAfter == ILevrGovernor_v1.ProposalState.Executed ||
                stateAfter == ILevrGovernor_v1.ProposalState.Defeated,
            'Proposal should be finalized'
        );

        // Cycle does NOT auto-advance (advances on next propose)
        uint256 cycleIdAfter = governor.currentCycleId();
        assertEq(cycleIdAfter, 1, 'Cycle does NOT auto-advance');
        
        // Create next proposal to trigger cycle advancement
        vm.prank(attacker);
        uint256 pid2 = governor.proposeTransfer(address(underlying), alice, 10 ether, 'Next');
        assertGt(governor.currentCycleId(), 1, 'Cycle advances on next propose');

        console2.log('');
        console2.log('[TEST PASSES - NOT VULNERABLE]');
        console2.log('Gas bomb handled correctly by try-catch');
        console2.log('State committed before try-catch prevents rollback');
    }

    // ============================================================================
    // ATTACK VECTOR 3: Revert Data Bomb (CONDITIONAL BLOCKER)
    // ============================================================================

    /**
     * @notice TEST 3: Revert data bomb blocks governance
     * @dev This test demonstrates the REVERT DATA BOMB attack vector
     *
     * ATTACK FLOW:
     * 1. Attacker deploys RevertBombToken that returns huge revert data
     * 2. Proposal to transfer this token wins vote
     * 3. execute() reaches try-catch
     * 4. Token's transfer() returns 100KB revert data
     * 5. catch (bytes memory) tries to copy 100KB to memory
     * 6. OOG during revert data copy
     * 7. Transaction reverts, state rolled back
     * 8. Governance frozen
     *
     * EXPECTED (CORRECT BEHAVIOR):
     * - catch without data binding prevents revert data copy
     * - Proposal marked executed
     * - Governance continues
     *
     * ACTUAL (VULNERABLE):
     * - OOG during revert data copy
     * - State rolled back
     * - Governance frozen
     */
    function test_attackVector3_revertDataBombBlocksGovernance() public {
        console2.log('\n=== Attack Vector 3: Revert Data Bomb ===\n');

        // Create malicious proposal
        uint256 maliciousProposalId = _createAndPassProposal(address(revertBomb), 100 ether, alice);

        console2.log('Revert bomb proposal created and passed vote');
        console2.log('Proposal ID:', maliciousProposalId);
        console2.log('Token:', address(revertBomb));
        console2.log('Revert data size: ~100KB');
        console2.log('');

        // Check initial state
        ILevrGovernor_v1.ProposalState stateBefore = governor.state(maliciousProposalId);
        assertEq(
            uint256(stateBefore),
            uint256(ILevrGovernor_v1.ProposalState.Succeeded),
            'Proposal should be in Succeeded state'
        );

        // ASSERTION: execute() should handle revert bomb
        console2.log('Executing proposal with revert bomb...');
        console2.log('ASSERTION: Should handle gracefully');
        console2.log('');

        // Execute multiple times (will fail due to revert bomb but doesn't cause DoS)
        governor.execute(maliciousProposalId); // Attempt 1
        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(maliciousProposalId); // Attempt 2
        vm.warp(block.timestamp + 10 minutes + 1); // Wait for delay
        governor.execute(maliciousProposalId); // Attempt 3

        console2.log('Execute completed 3 times (handled revert bomb)');
        console2.log('');

        // NEW BEHAVIOR: Proposal stays in Succeeded (can retry)
        ILevrGovernor_v1.ProposalState stateAfter = governor.state(maliciousProposalId);
        console2.log('State after execute:', uint256(stateAfter));

        assertEq(
            uint256(stateAfter),
            uint256(ILevrGovernor_v1.ProposalState.Succeeded),
            'Proposal should stay in Succeeded state (can retry)'
        );
        
        // Execution attempts tracked
        assertEq(governor.executionAttempts(maliciousProposalId).count, 3, 'Should have 3 attempts');

        // Cycle should NOT have auto-advanced (failed execution)
        assertEq(governor.currentCycleId(), 1, 'Cycle should NOT auto-advance on failure');
        
        // Manual advance works (after 3 attempts)
        governor.startNewCycle();
        assertEq(governor.currentCycleId(), 2, 'Manual advance works');

        console2.log('');
        console2.log('[TEST PASSES - NOT VULNERABLE]');
        console2.log('Revert bomb handled correctly by catch blocks');
        console2.log('No DoS - governance can manually advance');
    }

    // ============================================================================
    // CRITICAL VALIDATION: Cannot Advance Cycle with Executable Proposals
    // ============================================================================

    /**
     * @notice Validate that startNewCycle() prevents orphaning executable proposals
     * @dev This is a CRITICAL governance safety check
     *
     * EXPECTED BEHAVIOR:
     * - Cannot call startNewCycle() if winner hasn't been executed
     * - Must execute winner before advancing cycle
     * - Prevents orphaning proposals that passed voting
     *
     * This test validates _checkNoExecutableProposals() works correctly
     */
    function test_cannotAdvanceCycleWithExecutableProposals() public {
        console2.log('\n=== CRITICAL: Cannot Advance Cycle with Executable Winner ===\n');

        // Create a winning proposal
        uint256 winningProposal = _createAndPassProposal(address(underlying), 100 ether, alice);

        console2.log('Winning proposal created and passed vote');
        console2.log('Proposal ID:', winningProposal);
        console2.log('State:', uint256(governor.state(winningProposal)));
        assertEq(
            uint256(governor.state(winningProposal)),
            uint256(ILevrGovernor_v1.ProposalState.Succeeded),
            'Proposal should be in Succeeded state'
        );

        // CRITICAL ASSERTION: Should NOT be able to start new cycle
        console2.log('');
        console2.log('ASSERTION: Cannot start new cycle (executable proposal remains)');
        vm.expectRevert(ILevrGovernor_v1.ExecutableProposalsRemaining.selector);
        governor.startNewCycle();

        console2.log('[PASS] startNewCycle() correctly reverts');
        console2.log('Winner must be executed before cycle can advance');
        console2.log('');

        // Execute the winner
        console2.log('Executing winner...');
        governor.execute(winningProposal);

        // Verify proposal executed
        assertTrue(governor.getProposal(winningProposal).executed, 'Winner should be executed');

        // Cycle does NOT auto-advance (advances on next propose)
        uint256 cycleAfter = governor.currentCycleId();
        assertEq(cycleAfter, 1, 'Cycle does NOT auto-advance');
        
        // Create next proposal to trigger cycle advancement
        vm.prank(attacker);
        uint256 pid2 = governor.proposeTransfer(address(underlying), alice, 10 ether, 'Next');
        assertGt(governor.currentCycleId(), 1, 'Cycle advances on next propose');

        console2.log('Cycle auto-advanced to:', cycleAfter);
        console2.log('');
        console2.log('[PASS] Governance safety: Executable proposals cannot be orphaned');
    }

    /**
     * @notice Validate cannot advance cycle during Pending state
     */
    function test_cannotAdvanceCycle_duringPendingState() public {
        console2.log('\n=== Cannot Advance During Pending State ===\n');

        // Create proposal (in Pending state - proposal window active)
        vm.prank(alice);
        uint256 pid = governor.proposeTransfer(address(underlying), alice, 100 ether, 'Test');

        console2.log('Proposal created (Pending state)');
        assertEq(
            uint256(governor.state(pid)),
            uint256(ILevrGovernor_v1.ProposalState.Pending),
            'Should be Pending'
        );

        // ASSERTION: Cannot advance cycle (proposal still pending)
        vm.expectRevert(ILevrGovernor_v1.CycleStillActive.selector);
        governor.startNewCycle();

        console2.log('[PASS] Cannot advance during proposal window');
    }

    /**
     * @notice Validate cannot advance cycle during Active state
     */
    function test_cannotAdvanceCycle_duringActiveState() public {
        console2.log('\n=== Cannot Advance During Active State ===\n');

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeTransfer(address(underlying), alice, 100 ether, 'Test');

        // Move to voting window (Active state)
        vm.warp(block.timestamp + 2 days + 1);

        console2.log('Proposal in Active state (voting in progress)');
        assertEq(
            uint256(governor.state(pid)),
            uint256(ILevrGovernor_v1.ProposalState.Active),
            'Should be Active'
        );

        // ASSERTION: Cannot advance cycle (voting still in progress)
        vm.expectRevert(ILevrGovernor_v1.CycleStillActive.selector);
        governor.startNewCycle();

        console2.log('[PASS] Cannot advance during voting window');
    }

    /**
     * @notice Validate CAN advance cycle when all proposals defeated
     */
    function test_canAdvanceCycle_allProposalsDefeated() public {
        console2.log('\n=== CAN Advance When All Proposals Defeated ===\n');

        // Create proposals that will fail quorum (no votes)
        vm.prank(alice);
        uint256 pid1 = governor.proposeTransfer(address(underlying), alice, 100 ether, 'Test1');

        vm.prank(bob);
        uint256 pid2 = governor.proposeBoost(address(underlying), 200 ether);

        // Move past voting window
        vm.warp(block.timestamp + 2 days + 5 days + 1);

        console2.log('Both proposals in Defeated state (no votes)');
        assertEq(
            uint256(governor.state(pid1)),
            uint256(ILevrGovernor_v1.ProposalState.Defeated),
            'P1 should be Defeated'
        );
        assertEq(
            uint256(governor.state(pid2)),
            uint256(ILevrGovernor_v1.ProposalState.Defeated),
            'P2 should be Defeated'
        );

        // ASSERTION: CAN advance cycle (all defeated, no active proposals)
        console2.log('Attempting to start new cycle...');
        governor.startNewCycle();

        uint256 newCycle = governor.currentCycleId();
        assertGt(newCycle, 1, 'Cycle should have advanced');

        console2.log('Cycle advanced to:', newCycle);
        console2.log('[PASS] Can advance when all proposals defeated');
    }
}

// ============================================================================
// MALICIOUS TOKEN CONTRACTS
// ============================================================================

/**
 * @title MaliciousBalanceOfToken
 * @notice Attack Vector 1: Reverts on balanceOf call to treasury
 * @dev This demonstrates the DEFINITE BLOCKER - balanceOf is outside try-catch
 */
contract MaliciousBalanceOfToken is MockERC20 {
    address public targetTreasury;
    bool public activated; // Start false, allow propose(), then activate for execute()

    constructor(address _treasury, uint256 mintAmount) MockERC20('Malicious balanceOf', 'MBAL') {
        targetTreasury = _treasury;
        _mint(_treasury, mintAmount);
        activated = false; // Allow proposal creation
    }

    function activate() external {
        activated = true; // Now balanceOf will revert
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (account == targetTreasury && activated) {
            revert('GovernanceDoS'); // Blocks governance during execute()
        }
        return super.balanceOf(account);
    }
}

/**
 * @title GasBombToken
 * @notice Attack Vector 2: Consumes 63/64 of gas in transfer
 * @dev This demonstrates the GAS BOMB attack
 */
contract GasBombToken is MockERC20 {
    constructor(address _treasury, uint256 mintAmount) MockERC20('Gas Bomb', 'GGAS') {
        _mint(_treasury, mintAmount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Consume 63/64 of remaining gas (EVM's 63/64 rule)
        uint256 gasToWaste = (gasleft() * 63) / 64;
        uint256 target = gasleft() - gasToWaste;

        // Busy loop to burn gas
        while (gasleft() > target) {
            // Just burn gas
        }

        return super.transfer(to, amount);
    }
}

/**
 * @title RevertBombToken
 * @notice Attack Vector 3: Returns huge revert data causing OOG during copy
 * @dev This demonstrates the REVERT DATA BOMB attack
 */
contract RevertBombToken is MockERC20 {
    constructor(address _treasury, uint256 mintAmount) MockERC20('Revert Bomb', 'RBOM') {
        _mint(_treasury, mintAmount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        // Create 100KB revert data (enough to cause OOG during copy)
        bytes memory hugeBomb = new bytes(100_000);

        // Fill with some data to ensure it's allocated
        for (uint256 i = 0; i < 1000; i++) {
            hugeBomb[i] = bytes1(uint8(i % 256));
        }

        // Revert with huge data
        assembly {
            revert(add(hugeBomb, 32), mload(hugeBomb))
        }
    }
}
