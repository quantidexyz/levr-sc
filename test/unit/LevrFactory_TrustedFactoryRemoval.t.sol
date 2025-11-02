// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {IClanker} from '../../src/interfaces/external/IClanker.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Mock Clanker token for testing
contract MockClankerTokenForTest is MockERC20 {
    address private _tokenAdmin;

    constructor(string memory name, string memory symbol, address admin_) MockERC20(name, symbol) {
        _tokenAdmin = admin_;
        _mint(admin_, 1_000_000 ether);
    }

    function admin() external view override returns (address) {
        return _tokenAdmin;
    }
}

/// @notice Mock Clanker factory for testing
contract MockClankerFactory {
    mapping(address => IClanker.DeploymentInfo) private _deploymentInfo;

    function deployToken(
        address admin,
        string memory name,
        string memory symbol
    ) external returns (MockClankerTokenForTest) {
        MockClankerTokenForTest token = new MockClankerTokenForTest(name, symbol, admin);

        _deploymentInfo[address(token)] = IClanker.DeploymentInfo({
            token: address(token),
            hook: address(0),
            locker: address(0),
            extensions: new address[](0)
        });

        return token;
    }

    function tokenDeploymentInfo(
        address token
    ) external view returns (IClanker.DeploymentInfo memory) {
        IClanker.DeploymentInfo memory info = _deploymentInfo[token];
        require(info.token != address(0), 'NotFound');
        return info;
    }
}

/// @title Trusted Factory Removal Test
/// @notice Tests that removing a Clanker factory from trusted list doesn't break existing projects
contract LevrFactory_TrustedFactoryRemovalTest is Test {
    LevrFactory_v1 factory;
    LevrDeployer_v1 deployer;
    LevrForwarder_v1 forwarder;
    MockClankerFactory clankerFactory;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    MockClankerTokenForTest token1;
    ILevrFactory_v1.Project project1;

    function setUp() public {
        // Deploy infrastructure
        forwarder = new LevrForwarder_v1('Levr Forwarder');

        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 50,
            streamWindowSeconds: 7 days,
            protocolTreasury: address(this),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        // Predict factory address
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);

        deployer = new LevrDeployer_v1(predictedFactory);
        factory = new LevrFactory_v1(config, owner, address(forwarder), address(deployer), new address[](0));

        // Deploy mock Clanker factory
        clankerFactory = new MockClankerFactory();

        // Add to trusted list
        factory.addTrustedClankerFactory(address(clankerFactory));

        // Deploy and register a project
        token1 = clankerFactory.deployToken(alice, 'Token1', 'TKN1');

        vm.startPrank(alice);
        factory.prepareForDeployment();
        project1 = factory.register(address(token1));
        vm.stopPrank();

        // Fund alice and bob with tokens
        vm.prank(alice);
        token1.mint(alice, 10000 ether);
        vm.prank(alice);
        token1.mint(bob, 10000 ether);
    }

    function test_RemovalDoesNotBreakStaking() public {
        console2.log('\n=== Test: Removing Factory Does Not Break Staking ===');

        // Alice stakes before removal
        vm.startPrank(alice);
        token1.approve(project1.staking, 1000 ether);
        LevrStaking_v1(project1.staking).stake(1000 ether);
        vm.stopPrank();

        console2.log('Alice staked 1000 tokens');
        uint256 aliceStaked = IERC20(project1.stakedToken).balanceOf(alice);
        assertEq(aliceStaked, 1000 ether, 'Alice should have 1000 staked tokens');

        // Remove factory from trusted list
        console2.log('Removing Clanker factory from trusted list...');
        factory.removeTrustedClankerFactory(address(clankerFactory));

        // Verify factory was removed
        address[] memory trustedFactories = factory.getTrustedClankerFactories();
        assertEq(trustedFactories.length, 0, 'Should have no trusted factories');
        assertFalse(
            factory.isTrustedClankerFactory(address(clankerFactory)),
            'Factory should not be trusted'
        );

        // Bob can still stake (factory removal doesn't affect existing projects)
        vm.startPrank(bob);
        token1.approve(project1.staking, 2000 ether);
        LevrStaking_v1(project1.staking).stake(2000 ether);
        vm.stopPrank();

        console2.log('Bob staked 2000 tokens after factory removal');
        uint256 bobStaked = IERC20(project1.stakedToken).balanceOf(bob);
        assertEq(bobStaked, 2000 ether, 'Bob should have 2000 staked tokens');

        // Alice can unstake
        vm.prank(alice);
        LevrStaking_v1(project1.staking).unstake(500 ether, alice);

        console2.log('Alice unstaked 500 tokens');
        uint256 aliceStakedAfter = IERC20(project1.stakedToken).balanceOf(alice);
        assertEq(aliceStakedAfter, 500 ether, 'Alice should have 500 staked tokens remaining');

        console2.log('[PASS] Staking operations work normally after factory removal');
    }

    function test_RemovalDoesNotBreakGovernance() public {
        console2.log('\n=== Test: Removing Factory Does Not Break Governance ===');

        // Setup: Alice and Bob stake
        vm.startPrank(alice);
        token1.approve(project1.staking, 5000 ether);
        LevrStaking_v1(project1.staking).stake(5000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(project1.staking, 5000 ether);
        LevrStaking_v1(project1.staking).stake(5000 ether);
        vm.stopPrank();

        // Fund treasury
        vm.prank(alice);
        token1.mint(project1.treasury, 100000 ether);

        console2.log('Setup complete: Both users staked, treasury funded');

        // Remove factory from trusted list
        console2.log('Removing Clanker factory from trusted list...');
        factory.removeTrustedClankerFactory(address(clankerFactory));

        // Create proposal after removal
        LevrGovernor_v1 governor = LevrGovernor_v1(project1.governor);

        vm.prank(alice);
        uint256 proposalId = governor.proposeBoost(address(token1), 1000 ether);
        console2.log('Proposal created after factory removal. ID:', proposalId);

        // Fast forward to voting
        vm.warp(block.timestamp + 2 days + 1);

        // Vote
        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.prank(bob);
        governor.vote(proposalId, true);

        console2.log('Both users voted');

        // Fast forward past voting window
        vm.warp(block.timestamp + 5 days + 1);

        // Execute proposal
        vm.prank(alice);
        governor.execute(proposalId);

        console2.log('[PASS] Governance works normally after factory removal');
    }

    function test_RemovalDoesNotBreakTreasury() public {
        console2.log('\n=== Test: Removing Factory Does Not Break Treasury ===');

        // Fund treasury
        vm.prank(alice);
        token1.mint(project1.treasury, 50000 ether);

        uint256 treasuryBalanceBefore = token1.balanceOf(project1.treasury);
        console2.log('Treasury balance before:', treasuryBalanceBefore / 1e18);

        // Remove factory
        console2.log('Removing Clanker factory from trusted list...');
        factory.removeTrustedClankerFactory(address(clankerFactory));

        // Treasury operations still work
        LevrTreasury_v1 treasury = LevrTreasury_v1(project1.treasury);

        // Transfer from treasury (via governor)
        vm.prank(project1.governor);
        treasury.transfer(address(token1), bob, 1000 ether);

        uint256 bobBalance = token1.balanceOf(bob);
        console2.log('Bob received from treasury:', bobBalance / 1e18);
        assertEq(
            bobBalance,
            11000 ether,
            'Bob should have received 1000 tokens (10000 initial + 1000 from treasury)'
        );

        console2.log('[PASS] Treasury operations work normally after factory removal');
    }

    function test_RemovalDoesNotBreakRewardDistribution() public {
        console2.log('\n=== Test: Removing Factory Does Not Break Reward Distribution ===');

        // Alice stakes
        vm.startPrank(alice);
        token1.approve(project1.staking, 5000 ether);
        LevrStaking_v1(project1.staking).stake(5000 ether);
        vm.stopPrank();

        // Fund treasury and apply boost
        vm.prank(alice);
        token1.mint(project1.treasury, 10000 ether);

        vm.prank(project1.governor);
        LevrTreasury_v1(project1.treasury).applyBoost(address(token1), 5000 ether);

        console2.log('Applied 5000 token boost to staking');

        // Remove factory
        console2.log('Removing Clanker factory from trusted list...');
        factory.removeTrustedClankerFactory(address(clankerFactory));

        // Fast forward to accrue rewards
        vm.warp(block.timestamp + 4 days);

        // Claim rewards
        LevrStaking_v1 staking = LevrStaking_v1(project1.staking);
        uint256 claimable = staking.claimableRewards(alice, address(token1));
        console2.log('Claimable rewards:', claimable / 1e18);
        assertTrue(claimable > 0, 'Should have claimable rewards');

        uint256 aliceBalanceBefore = token1.balanceOf(alice);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 aliceBalanceAfter = token1.balanceOf(alice);
        uint256 claimed = aliceBalanceAfter - aliceBalanceBefore;

        console2.log('Alice claimed:', claimed / 1e18);
        assertEq(claimed, claimable, 'Should have claimed exact claimable amount');

        console2.log('[PASS] Reward distribution works normally after factory removal');
    }

    function test_RemovalPreventsNewRegistrations() public {
        console2.log('\n=== Test: Removing All Factories Prevents New Registrations ===');

        // Remove factory (now list is empty)
        factory.removeTrustedClankerFactory(address(clankerFactory));

        address[] memory trustedFactories = factory.getTrustedClankerFactories();
        assertEq(trustedFactories.length, 0, 'Should have no trusted factories');

        // Try to register new project - SHOULD REVERT (no trusted factories)
        MockClankerTokenForTest token2 = clankerFactory.deployToken(bob, 'Token2', 'TKN2');

        vm.startPrank(bob);
        factory.prepareForDeployment();
        vm.expectRevert('NO_TRUSTED_FACTORIES');
        factory.register(address(token2));
        vm.stopPrank();

        console2.log('[PASS] New registrations blocked when no trusted factories');
    }

    function test_RemovalAndReAddAllowsRegistration() public {
        console2.log('\n=== Test: Re-adding Factory Allows Registrations Again ===');

        // Remove factory
        factory.removeTrustedClankerFactory(address(clankerFactory));

        // Verify removal
        assertFalse(
            factory.isTrustedClankerFactory(address(clankerFactory)),
            'Should not be trusted'
        );

        // Re-add factory
        factory.addTrustedClankerFactory(address(clankerFactory));

        // Verify re-added
        assertTrue(
            factory.isTrustedClankerFactory(address(clankerFactory)),
            'Should be trusted again'
        );

        // Register new project
        MockClankerTokenForTest token2 = clankerFactory.deployToken(bob, 'Token2', 'TKN2');

        vm.startPrank(bob);
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project2 = factory.register(address(token2));
        vm.stopPrank();

        // Verify registration
        assertTrue(project2.staking != address(0), 'Project should be registered');
        console2.log('[PASS] Re-adding factory allows new registrations');
    }

    function test_GetClankerMetadata_FailsGracefullyAfterRemoval() public {
        console2.log('\n=== Test: getClankerMetadata Fails Gracefully After Removal ===');

        // Get metadata before removal
        ILevrFactory_v1.ClankerMetadata memory metadataBefore = factory.getClankerMetadata(
            address(token1)
        );
        assertTrue(metadataBefore.exists, 'Metadata should exist before removal');

        console2.log('Metadata exists before removal');

        // Remove factory
        factory.removeTrustedClankerFactory(address(clankerFactory));

        // Get metadata after removal - should return non-existent
        ILevrFactory_v1.ClankerMetadata memory metadataAfter = factory.getClankerMetadata(
            address(token1)
        );
        assertFalse(metadataAfter.exists, 'Metadata should not exist after removal');
        assertEq(metadataAfter.feeLocker, address(0), 'Fee locker should be zero');
        assertEq(metadataAfter.lpLocker, address(0), 'LP locker should be zero');
        assertEq(metadataAfter.hook, address(0), 'Hook should be zero');

        console2.log('[PASS] getClankerMetadata fails gracefully (returns non-existent)');
    }

    function test_MultipleFactories_RemovalOfOneDoesNotAffectOthers() public {
        console2.log('\n=== Test: Multiple Factories - Removing One Does Not Affect Others ===');

        // Deploy second Clanker factory
        MockClankerFactory clankerFactory2 = new MockClankerFactory();
        factory.addTrustedClankerFactory(address(clankerFactory2));

        console2.log('Added second Clanker factory');

        // Deploy token from second factory
        MockClankerTokenForTest token2 = clankerFactory2.deployToken(bob, 'Token2', 'TKN2');

        vm.startPrank(bob);
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project2 = factory.register(address(token2));
        vm.stopPrank();

        console2.log('Registered project from factory 2');

        // Remove first factory
        factory.removeTrustedClankerFactory(address(clankerFactory));

        console2.log('Removed first Clanker factory');

        // Verify first factory is removed
        assertFalse(
            factory.isTrustedClankerFactory(address(clankerFactory)),
            'Factory 1 should not be trusted'
        );

        // Verify second factory still trusted
        assertTrue(
            factory.isTrustedClankerFactory(address(clankerFactory2)),
            'Factory 2 should still be trusted'
        );

        // Can still register from second factory
        MockClankerTokenForTest token3 = clankerFactory2.deployToken(bob, 'Token3', 'TKN3');

        vm.startPrank(bob);
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project3 = factory.register(address(token3));
        vm.stopPrank();

        assertTrue(project3.staking != address(0), 'Should be able to register from factory 2');

        console2.log('[PASS] Removing one factory does not affect other trusted factories');
    }

    function test_EmergencyRecovery_RemoveAllThenAddBackRestoresValidation() public {
        console2.log('\n=== Test: Emergency Recovery - Re-adding Factory Restores Validation ===');

        // Start with factory in trusted list
        address[] memory trustedBefore = factory.getTrustedClankerFactories();
        assertEq(trustedBefore.length, 1, 'Should have one trusted factory');

        // Existing projects still work
        vm.startPrank(alice);
        token1.approve(project1.staking, 1000 ether);
        LevrStaking_v1(project1.staking).stake(1000 ether);
        vm.stopPrank();

        console2.log('Existing projects functional');

        // Remove factory (blocks new registrations)
        factory.removeTrustedClankerFactory(address(clankerFactory));

        console2.log('Removed factory - new registrations blocked');

        // Cannot register when no trusted factories
        MockClankerTokenForTest token2 = clankerFactory.deployToken(bob, 'Token2', 'TKN2');

        vm.startPrank(bob);
        factory.prepareForDeployment();
        vm.expectRevert('NO_TRUSTED_FACTORIES');
        factory.register(address(token2));
        vm.stopPrank();

        console2.log('Registration blocked (no trusted factories)');

        // Recovery: Add factory back
        factory.addTrustedClankerFactory(address(clankerFactory));

        console2.log('Factory re-added - validation restored');

        // New registrations from trusted factory work
        MockClankerTokenForTest token3 = clankerFactory.deployToken(bob, 'Token3', 'TKN3');

        vm.startPrank(bob);
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project3 = factory.register(address(token3));
        vm.stopPrank();

        assertTrue(
            project3.staking != address(0),
            'Should be able to register from trusted factory'
        );

        console2.log('[PASS] Emergency recovery successful - validation restored');
    }
}
