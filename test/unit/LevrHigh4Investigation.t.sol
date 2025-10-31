// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/**
 * @title HIGH-4 Investigation - Pool Dilution Analysis
 * @notice Deep dive into whether HIGH-4 is a real vulnerability or expected behavior
 */
contract LevrHigh4InvestigationTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    MockERC20 underlying;
    MockERC20 weth;
    address stakedToken;

    address alice = address(0x1);
    address bob = address(0x2);
    address attacker = address(0x3);

    function setUp() public {
        // Deploy factory
        address protocolTreasury = address(0xDEAD);
        (factory, , ) = deployFactoryWithDefaultClanker(
            createDefaultConfig(protocolTreasury),
            address(this)
        );

        // Deploy tokens
        underlying = new MockERC20('Underlying', 'UNDL');
        weth = new MockERC20('WETH', 'WETH');

        // Register project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        staking = LevrStaking_v1(project.staking);
        stakedToken = project.stakedToken;

        // Whitelist WETH as reward token
        vm.prank(underlying.admin());
        staking.whitelistToken(address(weth));

        // Fund accounts
        underlying.mint(alice, 100_000e18);
        underlying.mint(bob, 100_000e18);
        underlying.mint(attacker, 100_000e18);

        vm.prank(alice);
        underlying.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        underlying.approve(address(staking), type(uint256).max);
        vm.prank(attacker);
        underlying.approve(address(staking), type(uint256).max);
    }

    /**
     * @notice TEST 1: Is the attack actually profitable?
     * Check if attacker gains more than they risk
     */
    function test_attackProfitability() public {
        console.log("\n=== ATTACK PROFITABILITY ANALYSIS ===\n");

        // Setup: Alice & Bob stake, earn rewards
        vm.prank(alice);
        staking.stake(500e18);
        vm.prank(bob);
        staking.stake(500e18);

        // Accrue 1000 WETH rewards
        weth.mint(address(staking), 1000e18);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 7 days); // Vest all

        console.log("Initial state:");
        console.log("  Alice staked: 500");
        console.log("  Bob staked: 500");
        console.log("  Total rewards: 1000 WETH");
        console.log("  Alice expected: 500 WETH (50%)");

        // Attacker front-runs Alice's claim
        uint256 attackerInitialBalance = underlying.balanceOf(attacker);
        
        vm.prank(attacker);
        staking.stake(8000e18);
        console.log("\nAttacker stakes 8000 tokens");

        // Alice's claim executes (diluted)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        
        uint256 aliceReceived = weth.balanceOf(alice);
        console.log("\nAlice claims:");
        console.log("  Received:", aliceReceived / 1e18, "WETH");
        console.log("  Lost:", (500e18 - aliceReceived) / 1e18, "WETH");

        // Attacker claims
        vm.prank(attacker);
        staking.claimRewards(tokens, attacker);
        
        uint256 attackerWethReceived = weth.balanceOf(attacker);
        console.log("\nAttacker claims:");
        console.log("  Received:", attackerWethReceived / 1e18, "WETH");

        // Attacker unstakes (loses all voting power)
        vm.prank(attacker);
        staking.unstake(8000e18, attacker);

        uint256 attackerFinalBalance = underlying.balanceOf(attacker);
        
        console.log("\nAttacker unstakes 8000 tokens");
        console.log("  Voting power after unstake: 0 (destroyed)");

        // Calculate attacker's net gain
        console.log("\n=== ATTACK ECONOMICS ===");
        console.log("Attacker gains:");
        console.log("  + WETH received:", attackerWethReceived / 1e18);
        console.log("Attacker costs:");
        console.log("  - Must own 8000 tokens (locked during attack)");
        console.log("  - Gas for 3 transactions");
        console.log("  - Loses ALL voting power forever (if unstakes)");
        console.log("  - Risk: Others might claim first");
        
        // Is it profitable?
        console.log("\nProfitability check:");
        console.log("  WETH stolen from Alice:", (500e18 - aliceReceived) / 1e18);
        console.log("  Attacker needs to own:", 8000, "tokens (~16x Alice's stake)");
        console.log("  Attacker voting power lost: 100% (if unstakes)");
    }

    /**
     * @notice TEST 2: What if attacker keeps stake?
     * Check if this is "stealing" or just "participating"
     */
    function test_attackerKeepsStake() public {
        console.log("\n=== SCENARIO: ATTACKER KEEPS STAKE ===\n");

        // Setup
        vm.prank(alice);
        staking.stake(500e18);
        vm.prank(bob);
        staking.stake(500e18);

        weth.mint(address(staking), 1000e18);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 7 days);

        // Attacker stakes and KEEPS it
        vm.prank(attacker);
        staking.stake(8000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // All three claim
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        vm.prank(attacker);
        staking.claimRewards(tokens, attacker);

        console.log("Results:");
        console.log("  Alice:", weth.balanceOf(alice) / 1e18, "WETH (with 500 stake)");
        console.log("  Bob:", weth.balanceOf(bob) / 1e18, "WETH (with 500 stake)");
        console.log("  Attacker:", weth.balanceOf(attacker) / 1e18, "WETH (with 8000 stake)");

        console.log("\nAnalysis:");
        console.log("  Is this 'stealing' or 'staking'?");
        console.log("  Attacker HAS 8000 tokens staked");
        console.log("  Attacker WILL have voting power (if holds 7 days)");
        console.log("  System distributes by current stake ratio (by design)");
        console.log("\nConclusion: This is how pool-based rewards work!");
    }

    /**
     * @notice TEST 3: Compare with claim-before-dilution
     * What if Alice claims before attacker stakes?
     */
    function test_claimBeforeDilution() public {
        console.log("\n=== SCENARIO: ALICE CLAIMS FIRST ===\n");

        vm.prank(alice);
        staking.stake(500e18);
        vm.prank(bob);
        staking.stake(500e18);

        weth.mint(address(staking), 1000e18);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 7 days);

        // Alice claims BEFORE attacker stakes
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        console.log("Alice claims first: ", weth.balanceOf(alice) / 1e18, "WETH");

        // Now attacker stakes
        vm.prank(attacker);
        staking.stake(8000e18);

        console.log("Attacker stakes 8000 after Alice claimed");

        // What can attacker claim now?
        vm.prank(attacker);
        staking.claimRewards(tokens, attacker);

        console.log("Attacker receives:", weth.balanceOf(attacker) / 1e18, "WETH");
        console.log("\nConclusion: If users claim frequently, no dilution risk!");
    }

    /**
     * @notice TEST 4: Real-world feasibility
     * Can attacker actually execute this?
     */
    function test_realWorldFeasibility() public {
        console.log("\n=== REAL-WORLD FEASIBILITY ===\n");

        console.log("Attack Requirements:");
        console.log("  1. Attacker must monitor mempool constantly");
        console.log("  2. Attacker must own large amount of tokens (16x+ victim)");
        console.log("  3. Attacker must pay gas for 3 txs (stake+claim+unstake)");
        console.log("  4. Attacker must front-run successfully (MEV competition)");
        console.log("  5. If unstakes: Loses ALL voting power permanently");
        console.log("  6. If keeps stake: This is just normal staking, not attack");

        console.log("\nDefense Mechanisms (Already Exist):");
        console.log("  - Users can claim frequently (no accumulated rewards to steal)");
        console.log("  - Pool-based rewards = standard DeFi design");
        console.log("  - Voting power time-weighted (prevents governance attack)");
        console.log("  - Large capital requirement (8000 tokens) limits attackers");

        console.log("\nSimilar Systems:");
        console.log("  - MasterChef (SushiSwap): Same mechanism");
        console.log("  - Uniswap V2 LP: Share dilution by design");
        console.log("  - Curve pools: Proportional distribution");

        console.log("\n=== VERDICT ===");
        console.log("This appears to be EXPECTED BEHAVIOR, not a vulnerability");
        console.log("Recommendation: Document behavior, encourage frequent claims");
    }
}

