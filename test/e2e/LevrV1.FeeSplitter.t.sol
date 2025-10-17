// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';
import {SwapV4Helper} from '../utils/SwapV4Helper.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IClankerLpLocker} from '../../src/interfaces/external/IClankerLPLocker.sol';
import {IClankerToken} from '../../src/interfaces/external/IClankerToken.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/**
 * @title LevrV1 Fee Splitter E2E Tests
 * @notice E2E integration tests for the LevrFeeSplitter_v1 contract
 * @dev Tests complete integration flow from Clanker deployment to fee distribution
 */
contract LevrV1_FeeSplitterE2E is BaseForkTest, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrFeeSplitter_v1 internal feeSplitter;
    SwapV4Helper internal swapHelper;

    address internal protocolTreasury = address(0xFEE);
    address internal clankerToken;
    address internal clankerFactory;
    address constant DEFAULT_CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
    address constant LP_LOCKER = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
    address constant WETH = 0x4200000000000000000000000000000000000006; // Base WETH

    // Test receivers
    address internal deployer = address(this);
    address internal teamWallet = address(0x7EAA);
    address internal daoTreasury = address(0xDA0);

    function setUp() public override {
        super.setUp();
        clankerFactory = DEFAULT_CLANKER_FACTORY;

        // Deploy swap helper for fee generation
        swapHelper = new SwapV4Helper();

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 0,
            approvalBps: 0,
            minSTokenBpsToSubmit: 0
        });
        (factory, forwarder, levrDeployer) = deployFactory(
            cfg,
            address(this),
            DEFAULT_CLANKER_FACTORY
        );

        // Deploy fee splitter singleton
        feeSplitter = new LevrFeeSplitter_v1(address(factory), address(forwarder));
    }

    /**
     * @notice Helper to deploy Clanker token and register with Levr factory
     */
    function _deployRegisterAndGet()
        internal
        returns (address governor, address treasury, address staking, address stakedToken)
    {
        // Prepare infrastructure first
        factory.prepareForDeployment();

        ClankerDeployer d = new ClankerDeployer();
        clankerToken = d.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: 'Fee Splitter Test Token',
            symbol: 'FSTT',
            clankerFeeBps: 100,
            pairedFeeBps: 100
        });

        ILevrFactory_v1.Project memory project = factory.register(clankerToken);
        treasury = project.treasury;
        governor = project.governor;
        staking = project.staking;
        stakedToken = project.stakedToken;
    }

    /**
     * @notice Helper to simulate fees being generated
     * @dev In reality, fees would come from LP trading. For testing, we just simulate the result.
     */
    function _simulateFeesGenerated() internal {
        // In a real scenario, swaps would generate fees that get sent to the fee locker
        // then claimed and sent to the splitter. For testing, we just simulate this.
        vm.warp(block.timestamp + 1 hours); // Simulate time passing for fee accumulation
    }

    /**
     * @notice Test 1: Complete integration flow with 50/50 split
     * @dev As outlined in spec: Deploy → Register → Configure Splitter → Generate Fees → Distribute
     */
    function test_completeIntegrationFlow_5050Split() public {
        console2.log('=== Test 1: Complete Integration Flow (50/50 Split) ===');

        // 1-2. Deploy Clanker token and register with Levr
        (
            address governor,
            address treasury,
            address staking,
            address stakedToken
        ) = _deployRegisterAndGet();

        console2.log('Clanker Token:', clankerToken);
        console2.log('Staking:', staking);
        console2.log('Fee Splitter:', address(feeSplitter));

        // 3. Configure 50/50 split (staking/deployer)
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000}); // 50% to staking
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: deployer, bps: 5000}); // 50% to deployer

        vm.prank(address(this)); // We are the token admin
        feeSplitter.configureSplits(clankerToken, splits);

        console2.log('Configured 50/50 split');

        // 4. Update reward recipient in LP locker to point to fee splitter
        ILevrFactory_v1.ClankerMetadata memory metadata = factory.getClankerMetadata(clankerToken);
        require(metadata.lpLocker != address(0), 'LP locker not configured');

        // Note: In real deployment, token admin would call updateRewardRecipient on LP locker
        // For this test, we'll assume it's already set or mock it
        // vm.prank(address(this));
        // IClankerLpLocker(metadata.lpLocker).updateRewardRecipient(clankerToken, 0, address(feeSplitter));

        // 5. Simulate fees being generated
        console2.log('Simulating fee generation...');
        _simulateFeesGenerated();

        // 6. Check pending fees (this is simplified - actual pending would be in LP locker)
        vm.warp(block.timestamp + 1 days);

        // Simulate fees being sent to splitter (in reality, collectRewards would do this)
        // For testing, we'll directly transfer WETH to splitter
        deal(WETH, address(feeSplitter), 1000 ether); // Simulate collected fees

        uint256 pendingWETH = feeSplitter.pendingFees(clankerToken, WETH);
        console2.log('Pending WETH fees:', pendingWETH);
        assertGt(pendingWETH, 0, 'Should have WETH fees');

        // 7. Distribute fees (anyone can trigger)
        uint256 deployerBalanceBefore = IERC20(WETH).balanceOf(deployer);
        uint256 stakingBalanceBefore = IERC20(WETH).balanceOf(staking);

        console2.log('Distributing fees...');
        feeSplitter.distribute(clankerToken, WETH);

        uint256 deployerBalanceAfter = IERC20(WETH).balanceOf(deployer);
        uint256 stakingBalanceAfter = IERC20(WETH).balanceOf(staking);

        // 8. Verify 50/50 split
        uint256 deployerReceived = deployerBalanceAfter - deployerBalanceBefore;
        uint256 stakingReceived = stakingBalanceAfter - stakingBalanceBefore;

        console2.log('Deployer received:', deployerReceived);
        console2.log('Staking received:', stakingReceived);

        assertApproxEqRel(
            deployerReceived,
            stakingReceived,
            0.01e18,
            'Deployer and staking should receive equal amounts'
        );
        assertApproxEqRel(
            deployerReceived,
            pendingWETH / 2,
            0.01e18,
            'Deployer should receive ~50% of fees'
        );
        assertApproxEqRel(
            stakingReceived,
            pendingWETH / 2,
            0.01e18,
            'Staking should receive ~50% of fees'
        );

        // 9. Verify distribution state updated
        ILevrFeeSplitter_v1.DistributionState memory state = feeSplitter.getDistributionState(
            clankerToken,
            WETH
        );
        assertEq(
            state.totalDistributed,
            pendingWETH,
            'Total distributed should match pending fees'
        );
        assertEq(
            state.lastDistribution,
            block.timestamp,
            'Last distribution timestamp should be set'
        );

        console2.log('=== Test 1 Complete ===');
    }

    /**
     * @notice Test 2: Batch distribution (multi-token)
     * @dev Test distributing multiple reward tokens in a single transaction
     */
    function test_batchDistribution_multiToken() public {
        console2.log('=== Test 2: Batch Distribution (Multi-Token) ===');

        // Setup
        (, , address staking, ) = _deployRegisterAndGet();

        // Configure 60/40 split
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 6000}); // 60%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: deployer, bps: 4000}); // 40%

        feeSplitter.configureSplits(clankerToken, splits);

        // Simulate fees for multiple tokens
        deal(WETH, address(feeSplitter), 1000 ether); // WETH fees
        deal(clankerToken, address(feeSplitter), 5000 ether); // Clanker token fees

        // Use batch distribution
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = WETH;
        rewardTokens[1] = clankerToken;

        console2.log('Batch distributing WETH and Clanker token fees...');
        feeSplitter.distributeBatch(clankerToken, rewardTokens);

        // Verify WETH distribution (60/40)
        uint256 stakingWETH = IERC20(WETH).balanceOf(staking);
        uint256 deployerWETH = IERC20(WETH).balanceOf(deployer);
        assertApproxEqRel(stakingWETH, 600 ether, 0.01e18, 'Staking should get 60% of WETH');
        assertApproxEqRel(deployerWETH, 400 ether, 0.01e18, 'Deployer should get 40% of WETH');

        // Verify Clanker token distribution (60/40)
        uint256 stakingToken = IERC20(clankerToken).balanceOf(staking);
        uint256 deployerToken = IERC20(clankerToken).balanceOf(deployer);
        assertApproxEqRel(
            stakingToken,
            3000 ether,
            0.01e18,
            'Staking should get 60% of Clanker token'
        );
        assertApproxEqRel(
            deployerToken,
            2000 ether,
            0.01e18,
            'Deployer should get 40% of Clanker token'
        );

        console2.log('WETH distribution verified');
        console2.log('Clanker token distribution verified');
        console2.log('=== Test 2 Complete ===');
    }

    /**
     * @notice Test 3: Migration from existing project
     * @dev Test adding fee splitter to an already-running project
     */
    function test_migrationFromExistingProject() public {
        console2.log('=== Test 3: Migration from Existing Project ===');

        // 1. Project already registered (staking initially receives 100% of fees)
        (, , address staking, ) = _deployRegisterAndGet();

        console2.log('Project registered with staking as initial fee recipient');

        // 2. Simulate existing fees going to staking (before migration)
        deal(WETH, staking, 500 ether); // Staking already has some fees
        uint256 stakingBalanceBefore = IERC20(WETH).balanceOf(staking);
        console2.log('Staking balance before migration:', stakingBalanceBefore);

        // 3. Configure fee splitter (70% staking, 30% team)
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 7000}); // 70%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: teamWallet, bps: 3000}); // 30%

        feeSplitter.configureSplits(clankerToken, splits);
        console2.log('Configured 70/30 split');

        // 4. Update reward recipient in LP locker (migration step)
        // In production: IClankerLpLocker(lpLocker).updateRewardRecipient(clankerToken, 0, address(feeSplitter));

        // 5. Generate new fees (post-migration)
        deal(WETH, address(feeSplitter), 1000 ether); // New fees go to splitter

        // 6. Distribute new fees
        feeSplitter.distribute(clankerToken, WETH);

        // 7. Verify new 70/30 split applied
        uint256 stakingBalanceAfter = IERC20(WETH).balanceOf(staking);
        uint256 teamBalance = IERC20(WETH).balanceOf(teamWallet);

        uint256 stakingReceived = stakingBalanceAfter - stakingBalanceBefore;
        console2.log('Staking received (post-migration):', stakingReceived);
        console2.log('Team received:', teamBalance);

        assertApproxEqRel(
            stakingReceived,
            700 ether,
            0.01e18,
            'Staking should get 70% of new fees'
        );
        assertApproxEqRel(teamBalance, 300 ether, 0.01e18, 'Team should get 30% of new fees');

        // 8. Verify old balance preserved
        assertGe(stakingBalanceAfter, stakingBalanceBefore, 'Staking balance should not decrease');

        console2.log('Migration successful - old fees preserved, new fees split correctly');
        console2.log('=== Test 3 Complete ===');
    }

    /**
     * @notice Test 4: Reconfiguration
     * @dev Test changing split percentages and verify new percentages apply
     */
    function test_reconfiguration() public {
        console2.log('=== Test 4: Reconfiguration ===');

        // Setup
        (, , address staking, ) = _deployRegisterAndGet();

        // 1. Initial configuration: 50/50
        ILevrFeeSplitter_v1.SplitConfig[] memory splits1 = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits1[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000});
        splits1[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: deployer, bps: 5000});

        feeSplitter.configureSplits(clankerToken, splits1);
        console2.log('Initial config: 50/50 split');

        // 2. Generate and distribute fees with first config
        deal(WETH, address(feeSplitter), 1000 ether);
        feeSplitter.distribute(clankerToken, WETH);

        uint256 round1Deployer = IERC20(WETH).balanceOf(deployer);
        uint256 round1Staking = IERC20(WETH).balanceOf(staking);
        console2.log('Round 1 - Deployer:', round1Deployer);
        console2.log('Round 1 - Staking:', round1Staking);

        assertApproxEqRel(round1Deployer, 500 ether, 0.01e18, 'Round 1: deployer should get 50%');
        assertApproxEqRel(round1Staking, 500 ether, 0.01e18, 'Round 1: staking should get 50%');

        // 3. Reconfigure to 80/20
        ILevrFeeSplitter_v1.SplitConfig[] memory splits2 = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits2[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 8000}); // 80%
        splits2[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: deployer, bps: 2000}); // 20%

        feeSplitter.configureSplits(clankerToken, splits2);
        console2.log('Reconfigured to 80/20 split');

        // 4. Generate and distribute more fees with new config
        deal(WETH, address(feeSplitter), 1000 ether);
        feeSplitter.distribute(clankerToken, WETH);

        uint256 round2Deployer = IERC20(WETH).balanceOf(deployer) - round1Deployer;
        uint256 round2Staking = IERC20(WETH).balanceOf(staking) - round1Staking;
        console2.log('Round 2 - Deployer:', round2Deployer);
        console2.log('Round 2 - Staking:', round2Staking);

        // 5. Verify new 80/20 split applied
        assertApproxEqRel(round2Staking, 800 ether, 0.01e18, 'Round 2: staking should get 80%');
        assertApproxEqRel(round2Deployer, 200 ether, 0.01e18, 'Round 2: deployer should get 20%');

        // 6. Verify ratio
        assertApproxEqRel(
            round2Staking * 2,
            round2Deployer * 8,
            0.01e18,
            'Round 2: should maintain 80:20 ratio'
        );

        console2.log('Reconfiguration successful - new percentages applied');
        console2.log('=== Test 4 Complete ===');
    }

    /**
     * @notice Test 5: Multi-receiver distribution (4 receivers)
     * @dev Test balanced distribution pattern from spec
     */
    function test_multiReceiverDistribution() public {
        console2.log('=== Test 5: Multi-Receiver Distribution ===');

        // Setup
        (, , address staking, ) = _deployRegisterAndGet();

        // Configure 4-way split: 40% staking, 30% team, 20% DAO, 10% dev
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](4);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 4000}); // 40%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: teamWallet, bps: 3000}); // 30%
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: daoTreasury, bps: 2000}); // 20%
        splits[3] = ILevrFeeSplitter_v1.SplitConfig({receiver: deployer, bps: 1000}); // 10%

        feeSplitter.configureSplits(clankerToken, splits);
        console2.log('Configured 4-way split: 40/30/20/10');

        // Distribute fees
        deal(WETH, address(feeSplitter), 1000 ether);
        feeSplitter.distribute(clankerToken, WETH);

        // Verify each receiver
        uint256 stakingBalance = IERC20(WETH).balanceOf(staking);
        uint256 teamBalance = IERC20(WETH).balanceOf(teamWallet);
        uint256 daoBalance = IERC20(WETH).balanceOf(daoTreasury);
        uint256 devBalance = IERC20(WETH).balanceOf(deployer);

        console2.log('Staking received:', stakingBalance);
        console2.log('Team received:', teamBalance);
        console2.log('DAO received:', daoBalance);
        console2.log('Dev received:', devBalance);

        assertApproxEqRel(stakingBalance, 400 ether, 0.01e18, 'Staking should get 40%');
        assertApproxEqRel(teamBalance, 300 ether, 0.01e18, 'Team should get 30%');
        assertApproxEqRel(daoBalance, 200 ether, 0.01e18, 'DAO should get 20%');
        assertApproxEqRel(devBalance, 100 ether, 0.01e18, 'Dev should get 10%');

        console2.log('=== Test 5 Complete ===');
    }

    /**
     * @notice Test 6: Permissionless distribution
     * @dev Verify anyone can trigger distribution
     */
    function test_permissionlessDistribution() public {
        console2.log('=== Test 6: Permissionless Distribution ===');

        // Setup
        (, , address staking, ) = _deployRegisterAndGet();

        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        feeSplitter.configureSplits(clankerToken, splits);

        deal(WETH, address(feeSplitter), 1000 ether);

        // Random user triggers distribution
        address randomUser = address(0x4A4D04);
        vm.prank(randomUser);
        feeSplitter.distribute(clankerToken, WETH);

        assertEq(
            IERC20(WETH).balanceOf(staking),
            1000 ether,
            'Distribution should succeed from any caller'
        );

        console2.log('Distribution triggered by random user succeeded');
        console2.log('=== Test 6 Complete ===');
    }

    /**
     * @notice Test 7: Zero staking allocation
     * @dev Test configuration with 0% to staking (all fees to custom receivers)
     */
    function test_zeroStakingAllocation() public {
        console2.log('=== Test 7: Zero Staking Allocation ===');

        // Setup (no need for staking in splits)
        _deployRegisterAndGet();

        // Configure 100% to non-staking receivers
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: teamWallet, bps: 7000}); // 70%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: daoTreasury, bps: 3000}); // 30%

        feeSplitter.configureSplits(clankerToken, splits);
        console2.log('Configured 70/30 split (no staking)');

        // Distribute
        deal(WETH, address(feeSplitter), 1000 ether);
        feeSplitter.distribute(clankerToken, WETH);

        // Verify
        assertApproxEqRel(
            IERC20(WETH).balanceOf(teamWallet),
            700 ether,
            0.01e18,
            'Team should get 70%'
        );
        assertApproxEqRel(
            IERC20(WETH).balanceOf(daoTreasury),
            300 ether,
            0.01e18,
            'DAO should get 30%'
        );

        console2.log('Zero staking allocation works correctly');
        console2.log('=== Test 7 Complete ===');
    }
}
