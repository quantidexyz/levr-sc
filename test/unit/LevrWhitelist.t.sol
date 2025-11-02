// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/**
 * @title Levr Whitelist System Tests
 * @notice Comprehensive tests for the whitelist-only reward token system
 * @dev Tests factory initial whitelist, project inheritance, and state protection
 */
contract LevrWhitelistTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal stakedToken;
    MockERC20 internal underlying;
    MockERC20 internal weth;
    MockERC20 internal usdc;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal owner = address(this);

    event TokenWhitelisted(address indexed token);
    event TokenUnwhitelisted(address indexed token);
    event InitialWhitelistUpdated(address[] tokens);

    function setUp() public {
        // Deploy tokens
        underlying = new MockERC20('Underlying', 'UND');
        usdc = new MockERC20('USD Coin', 'USDC');

        // Deploy factory with default clanker setup (includes WETH in initial whitelist)
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(owner);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, owner);

        // Get WETH address from factory (deployed by helper at Base WETH address)
        address[] memory initialWhitelist = factory.getInitialWhitelist();
        if (initialWhitelist.length > 0) {
            weth = MockERC20(initialWhitelist[0]);
        } else {
            // Fallback: use hardcoded Base WETH address
            weth = MockERC20(0x4200000000000000000000000000000000000006);
        }
    }

    // ============ Factory Initial Whitelist Tests ============

    /// @notice Test factory stores and returns initial whitelist
    function test_factory_initialWhitelist_storedCorrectly() public {
        console2.log('\n=== Factory Initial Whitelist Stored ===');

        address[] memory whitelist = factory.getInitialWhitelist();

        // Should have WETH (deployed by helper)
        assertEq(whitelist.length, 1, 'Should have 1 token in initial whitelist');

        // WETH address is hardcoded in helper as Base WETH
        address expectedWeth = 0x4200000000000000000000000000000000000006;
        assertEq(whitelist[0], expectedWeth, 'Should be WETH');

        console2.log('SUCCESS: Factory initial whitelist retrieved correctly');
    }

    /// @notice Test factory owner can update initial whitelist
    function test_factory_updateInitialWhitelist_succeeds() public {
        console2.log('\n=== Update Factory Initial Whitelist ===');

        address[] memory newWhitelist = new address[](2);
        newWhitelist[0] = address(weth);
        newWhitelist[1] = address(usdc);

        vm.expectEmit(true, true, true, true);
        emit InitialWhitelistUpdated(newWhitelist);

        vm.prank(owner);
        factory.updateInitialWhitelist(newWhitelist);

        address[] memory retrieved = factory.getInitialWhitelist();
        assertEq(retrieved.length, 2, 'Should have 2 tokens');
        assertEq(retrieved[0], address(weth), 'First should be WETH');
        assertEq(retrieved[1], address(usdc), 'Second should be USDC');

        console2.log('SUCCESS: Factory initial whitelist updated');
    }

    /// @notice Test non-owner cannot update initial whitelist
    function test_factory_updateInitialWhitelist_onlyOwner() public {
        console2.log('\n=== Update Initial Whitelist - Only Owner ===');

        address[] memory newWhitelist = new address[](1);
        newWhitelist[0] = address(usdc);

        vm.prank(alice);
        vm.expectRevert();
        factory.updateInitialWhitelist(newWhitelist);

        console2.log('SUCCESS: Non-owner cannot update initial whitelist');
    }

    /// @notice Test cannot add zero address to initial whitelist
    function test_factory_updateInitialWhitelist_rejectsZeroAddress() public {
        console2.log('\n=== Update Initial Whitelist - Reject Zero Address ===');

        address[] memory newWhitelist = new address[](2);
        newWhitelist[0] = address(weth);
        newWhitelist[1] = address(0);

        vm.prank(owner);
        vm.expectRevert('ZERO_ADDRESS_IN_WHITELIST');
        factory.updateInitialWhitelist(newWhitelist);

        console2.log('SUCCESS: Zero address rejected from initial whitelist');
    }

    // ============ Project Whitelist Inheritance Tests ============

    /// @notice Test project inherits factory's initial whitelist
    function test_project_inheritsFactoryWhitelist() public {
        console2.log('\n=== Project Inherits Factory Whitelist ===');

        // Update factory whitelist before deploying project
        address[] memory newWhitelist = new address[](2);
        newWhitelist[0] = address(weth);
        newWhitelist[1] = address(usdc);
        vm.prank(owner);
        factory.updateInitialWhitelist(newWhitelist);

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Verify both WETH and USDC are whitelisted
        assertTrue(staking.isTokenWhitelisted(address(weth)), 'WETH should be whitelisted');
        assertTrue(staking.isTokenWhitelisted(address(usdc)), 'USDC should be whitelisted');

        // Verify underlying is also whitelisted (separately from initial whitelist)
        assertTrue(
            staking.isTokenWhitelisted(address(underlying)),
            'Underlying should be whitelisted'
        );

        console2.log('SUCCESS: Project inherits factory whitelist + underlying');
    }

    /// @notice Test project can extend inherited whitelist
    function test_project_extendsInheritedWhitelist() public {
        console2.log('\n=== Project Extends Inherited Whitelist ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Project admin adds a new token
        MockERC20 dai = new MockERC20('DAI', 'DAI');
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.whitelistToken(address(dai));

        // Verify all tokens are whitelisted
        assertTrue(staking.isTokenWhitelisted(address(underlying)), 'Underlying whitelisted');
        assertTrue(staking.isTokenWhitelisted(address(weth)), 'WETH inherited');
        assertTrue(staking.isTokenWhitelisted(address(dai)), 'DAI added by project');

        console2.log('SUCCESS: Project can extend whitelist beyond initial');
    }

    // ============ Underlying Token Protection Tests ============

    /// @notice Test underlying token cannot be whitelisted again (already whitelisted)
    function test_underlying_cannotWhitelistAgain() public {
        console2.log('\n=== Cannot Whitelist Underlying Again ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Try to whitelist underlying (should fail - already whitelisted)
        vm.prank(address(this));
        vm.expectRevert('CANNOT_MODIFY_UNDERLYING');
        staking.whitelistToken(address(underlying));

        console2.log('SUCCESS: Cannot whitelist underlying token');
    }

    /// @notice Test underlying token cannot be unwhitelisted
    function test_underlying_cannotUnwhitelist() public {
        console2.log('\n=== Cannot Unwhitelist Underlying ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Verify underlying is whitelisted
        assertTrue(
            staking.isTokenWhitelisted(address(underlying)),
            'Underlying should be whitelisted'
        );

        // Try to unwhitelist underlying (should fail)
        vm.prank(address(this));
        vm.expectRevert('CANNOT_UNWHITELIST_UNDERLYING');
        staking.unwhitelistToken(address(underlying));

        // Verify still whitelisted
        assertTrue(staking.isTokenWhitelisted(address(underlying)), 'Underlying still whitelisted');

        console2.log('SUCCESS: Underlying token is immutably whitelisted');
    }

    // ============ Reward State Protection Tests ============

    /// @notice Test cannot unwhitelist token with pending rewards
    function test_whitelist_rejectsTokenWithPendingRewards() public {
        console2.log('\n=== Cannot Unwhitelist Token With Pending Rewards ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Whitelist a token and accrue rewards
        MockERC20 dai = new MockERC20('DAI', 'DAI');
        vm.prank(address(this));
        staking.whitelistToken(address(dai));

        dai.mint(address(staking), 100 ether);
        staking.accrueRewards(address(dai));

        // Wait for stream to start
        vm.warp(block.timestamp + 1 days);

        // Claim some rewards (not all)
        address[] memory tokens = new address[](1);
        tokens[0] = address(dai);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        // Unwhitelist (should fail - still has pending rewards in stream)
        vm.prank(address(this));
        vm.expectRevert('CANNOT_UNWHITELIST_WITH_PENDING_REWARDS');
        staking.unwhitelistToken(address(dai));

        console2.log('SUCCESS: Cannot unwhitelist token with active stream');
    }

    /// @notice Test cannot unwhitelist token with pool rewards
    function test_unwhitelist_rejectsTokenWithPoolRewards() public {
        console2.log('\n=== Cannot Unwhitelist Token With Pool Rewards ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Whitelist and accrue rewards
        MockERC20 dai = new MockERC20('DAI', 'DAI');
        vm.prank(address(this));
        staking.whitelistToken(address(dai));

        dai.mint(address(staking), 100 ether);
        staking.accrueRewards(address(dai));

        // Wait for stream to fully vest
        vm.warp(block.timestamp + 4 days);

        // Don't claim - rewards are in pool now
        // Try to unwhitelist - should fail
        vm.prank(address(this));
        vm.expectRevert('CANNOT_UNWHITELIST_WITH_PENDING_REWARDS');
        staking.unwhitelistToken(address(dai));

        console2.log('SUCCESS: Cannot unwhitelist token with vested pool rewards');
    }

    // ============ Whitelist State Transition Tests ============

    /// @notice Test complete whitelist lifecycle
    function test_whitelist_completeLifecycle() public {
        console2.log('\n=== Complete Whitelist Lifecycle ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Alice stakes
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        MockERC20 dai = new MockERC20('DAI', 'DAI');

        // 1. Whitelist token
        vm.expectEmit(true, false, false, false);
        emit TokenWhitelisted(address(dai));
        vm.prank(address(this));
        staking.whitelistToken(address(dai));
        assertTrue(staking.isTokenWhitelisted(address(dai)), 'DAI should be whitelisted');
        console2.log('1. Token whitelisted');

        // 2. Accrue rewards
        dai.mint(address(staking), 100 ether);
        staking.accrueRewards(address(dai));
        console2.log('2. Rewards accrued');

        // 3. Wait and claim all
        vm.warp(block.timestamp + 4 days);
        address[] memory tokens = new address[](1);
        tokens[0] = address(dai);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        console2.log('3. All rewards claimed');

        // 4. Unwhitelist token
        vm.expectEmit(true, false, false, false);
        emit TokenUnwhitelisted(address(dai));
        vm.prank(address(this));
        staking.unwhitelistToken(address(dai));
        assertFalse(staking.isTokenWhitelisted(address(dai)), 'DAI should not be whitelisted');
        console2.log('4. Token unwhitelisted');

        // 5. Cleanup finished token
        staking.cleanupFinishedRewardToken(address(dai));
        console2.log('5. Token cleaned up');

        // 6. Re-whitelist token
        vm.prank(address(this));
        staking.whitelistToken(address(dai));
        assertTrue(staking.isTokenWhitelisted(address(dai)), 'DAI should be re-whitelisted');
        console2.log('6. Token re-whitelisted');

        // 7. Accrue new rewards
        dai.mint(address(staking), 50 ether);
        staking.accrueRewards(address(dai));
        console2.log('7. New rewards accrued');

        console2.log('SUCCESS: Complete whitelist lifecycle works');
    }

    /// @notice Test cannot re-whitelist already whitelisted token
    function test_whitelist_cannotWhitelistTwice() public {
        console2.log('\n=== Cannot Whitelist Already Whitelisted Token ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        MockERC20 dai = new MockERC20('DAI', 'DAI');

        // Whitelist once
        vm.prank(address(this));
        staking.whitelistToken(address(dai));

        // Try to whitelist again
        vm.prank(address(this));
        vm.expectRevert('ALREADY_WHITELISTED');
        staking.whitelistToken(address(dai));

        console2.log('SUCCESS: Cannot whitelist already whitelisted token');
    }

    /// @notice Test whitelisting requires token admin permission
    function test_whitelist_onlyTokenAdmin() public {
        console2.log('\n=== Whitelist Requires Token Admin ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        MockERC20 dai = new MockERC20('DAI', 'DAI');

        // Alice tries to whitelist (not admin)
        vm.prank(alice);
        vm.expectRevert('ONLY_TOKEN_ADMIN');
        staking.whitelistToken(address(dai));

        // Token admin can whitelist
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.whitelistToken(address(dai));

        console2.log('SUCCESS: Only token admin can whitelist');
    }

    /// @notice Test unwhitelisting requires token admin permission
    function test_unwhitelist_onlyTokenAdmin() public {
        console2.log('\n=== Unwhitelist Requires Token Admin ===');

        // Deploy project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        staking = LevrStaking_v1(project.staking);

        // Whitelist a token
        MockERC20 dai = new MockERC20('DAI', 'DAI');
        vm.prank(address(this));
        staking.whitelistToken(address(dai));

        // Alice tries to unwhitelist (not admin)
        vm.prank(alice);
        vm.expectRevert('ONLY_TOKEN_ADMIN');
        staking.unwhitelistToken(address(dai));

        // Token admin can unwhitelist
        vm.prank(address(this));
        staking.unwhitelistToken(address(dai));

        console2.log('SUCCESS: Only token admin can unwhitelist');
    }

    // ============ Integration Tests ============

    /// @notice Test multiple projects use different whitelists
    function test_multiProject_independentWhitelists() public {
        console2.log('\n=== Multiple Projects Have Independent Whitelists ===');

        // Update factory whitelist
        address[] memory newWhitelist = new address[](1);
        newWhitelist[0] = address(weth);
        vm.prank(owner);
        factory.updateInitialWhitelist(newWhitelist);

        // Deploy first project
        MockERC20 token1 = new MockERC20('Token1', 'TK1');
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project1 = factory.register(address(token1));
        LevrStaking_v1 staking1 = LevrStaking_v1(project1.staking);

        // Deploy second project
        MockERC20 token2 = new MockERC20('Token2', 'TK2');
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project2 = factory.register(address(token2));
        LevrStaking_v1 staking2 = LevrStaking_v1(project2.staking);

        // Both should have WETH from factory
        assertTrue(staking1.isTokenWhitelisted(address(weth)), 'Project1 has WETH');
        assertTrue(staking2.isTokenWhitelisted(address(weth)), 'Project2 has WETH');

        // Add DAI to project1 only
        MockERC20 dai = new MockERC20('DAI', 'DAI');
        vm.prank(address(this)); // Admin of token1
        staking1.whitelistToken(address(dai));

        // Verify independent whitelists
        assertTrue(staking1.isTokenWhitelisted(address(dai)), 'Project1 has DAI');
        assertFalse(staking2.isTokenWhitelisted(address(dai)), 'Project2 does not have DAI');

        console2.log('SUCCESS: Projects maintain independent whitelists');
    }
}
