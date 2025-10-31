// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {IClanker} from '../../src/interfaces/external/IClanker.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title LevrFactory Clanker Validation Tests
/// @notice FIX [C-1]: Tests for trusted Clanker factory validation
contract LevrFactoryClankerValidationTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 factory;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    address mockClankerFactoryV1;
    address mockClankerFactoryV2;
    address fakeClankerFactory;

    event TrustedClankerFactoryAdded(address indexed factory);
    event TrustedClankerFactoryRemoved(address indexed factory);

    function setUp() public {
        // Deploy mock Clanker factories first
        mockClankerFactoryV1 = address(new MockClankerFactory('v1'));
        mockClankerFactoryV2 = address(new MockClankerFactory('v2'));
        fakeClankerFactory = address(new MockClankerFactory('fake'));

        // Deploy factory with default config (no trusted factories initially)
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(owner);
        (factory, , ) = deployFactory(cfg, owner, address(0));
    }

    /// @notice Test 1: Reject tokens not deployed by any trusted factory
    function test_rejectToken_notFromTrustedFactory() public {
        console2.log('\n=== C-1 Test 1: Reject Token Not From Trusted Factory ===');

        // Add trusted factory
        factory.addTrustedClankerFactory(mockClankerFactoryV1);

        // Deploy token from v1 factory
        MockClankerTokenForTest tokenV1 = MockClankerFactory(mockClankerFactoryV1).deployToken(
            alice,
            'TokenV1',
            'TV1'
        );

        // Deploy token from FAKE factory (not trusted)
        MockClankerTokenForTest fakeToken = MockClankerFactory(fakeClankerFactory).deployToken(
            alice,
            'FakeToken',
            'FAKE'
        );

        // Prepare contracts
        vm.prank(alice);
        factory.prepareForDeployment();

        // Should succeed for token from trusted factory
        vm.prank(alice);
        factory.register(address(tokenV1));
        console2.log('SUCCESS: Token from trusted factory v1 registered');

        // Should fail for token from untrusted factory
        vm.prank(alice);
        factory.prepareForDeployment(); // Need new prepared contracts

        vm.prank(alice);
        vm.expectRevert('TOKEN_NOT_FROM_TRUSTED_FACTORY');
        factory.register(address(fakeToken));
        console2.log('BLOCKED: Token from untrusted factory rejected');
    }

    /// @notice Test 2: Accept tokens deployed by factory v1
    function test_acceptToken_fromFactoryV1() public {
        console2.log('\n=== C-1 Test 2: Accept Token From Factory V1 ===');

        // Add trusted factory v1
        factory.addTrustedClankerFactory(mockClankerFactoryV1);

        // Deploy token from v1
        MockClankerTokenForTest tokenV1 = MockClankerFactory(mockClankerFactoryV1).deployToken(
            alice,
            'TokenV1',
            'TV1'
        );

        // Register should succeed
        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        ILevrFactory_v1.Project memory project = factory.register(address(tokenV1));

        assertNotEq(project.staking, address(0), 'Staking should be deployed');
        assertNotEq(project.governor, address(0), 'Governor should be deployed');
        console2.log('SUCCESS: Token from v1 factory registered');
    }

    /// @notice Test 3: Accept tokens deployed by factory v2
    function test_acceptToken_fromFactoryV2() public {
        console2.log('\n=== C-1 Test 3: Accept Token From Factory V2 ===');

        // Add both v1 and v2 factories
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        factory.addTrustedClankerFactory(mockClankerFactoryV2);

        // Deploy token from v2
        MockClankerTokenForTest tokenV2 = MockClankerFactory(mockClankerFactoryV2).deployToken(
            bob,
            'TokenV2',
            'TV2'
        );

        // Register should succeed
        vm.prank(bob);
        factory.prepareForDeployment();

        vm.prank(bob);
        ILevrFactory_v1.Project memory project = factory.register(address(tokenV2));

        assertNotEq(project.staking, address(0), 'Staking should be deployed');
        console2.log('SUCCESS: Token from v2 factory registered');
    }

    /// @notice Test 4: Admin can add multiple trusted factories
    function test_admin_addMultipleFactories() public {
        console2.log('\n=== C-1 Test 4: Admin Add Multiple Factories ===');

        // Add factory v1
        vm.expectEmit(true, false, false, false);
        emit TrustedClankerFactoryAdded(mockClankerFactoryV1);
        factory.addTrustedClankerFactory(mockClankerFactoryV1);

        // Add factory v2
        vm.expectEmit(true, false, false, false);
        emit TrustedClankerFactoryAdded(mockClankerFactoryV2);
        factory.addTrustedClankerFactory(mockClankerFactoryV2);

        // Verify both are trusted
        assertTrue(factory.isTrustedClankerFactory(mockClankerFactoryV1), 'V1 should be trusted');
        assertTrue(factory.isTrustedClankerFactory(mockClankerFactoryV2), 'V2 should be trusted');

        // Verify array contains both
        address[] memory factories = factory.getTrustedClankerFactories();
        assertEq(factories.length, 2, 'Should have 2 factories');
        console2.log('SUCCESS: Multiple factories added');
    }

    /// @notice Test 5: Admin can remove trusted factory
    function test_admin_removeFactory() public {
        console2.log('\n=== C-1 Test 5: Admin Remove Factory ===');

        // Add both factories
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        factory.addTrustedClankerFactory(mockClankerFactoryV2);

        // Remove v1
        vm.expectEmit(true, false, false, false);
        emit TrustedClankerFactoryRemoved(mockClankerFactoryV1);
        factory.removeTrustedClankerFactory(mockClankerFactoryV1);

        // Verify v1 is no longer trusted
        assertFalse(
            factory.isTrustedClankerFactory(mockClankerFactoryV1),
            'V1 should not be trusted'
        );
        assertTrue(
            factory.isTrustedClankerFactory(mockClankerFactoryV2),
            'V2 should still be trusted'
        );

        // Verify array only has v2
        address[] memory factories = factory.getTrustedClankerFactories();
        assertEq(factories.length, 1, 'Should have 1 factory');
        assertEq(factories[0], mockClankerFactoryV2, 'Should be v2');
        console2.log('SUCCESS: Factory removed correctly');
    }

    /// @notice Test 6: Only owner can manage trusted factories
    function test_onlyOwner_canManageFactories() public {
        console2.log('\n=== C-1 Test 6: Only Owner Can Manage Factories ===');

        // Non-owner tries to add factory
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature('OwnableUnauthorizedAccount(address)', alice));
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        console2.log('BLOCKED: Non-owner cannot add factory');

        // Owner adds factory
        factory.addTrustedClankerFactory(mockClankerFactoryV1);

        // Non-owner tries to remove factory
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature('OwnableUnauthorizedAccount(address)', alice));
        factory.removeTrustedClankerFactory(mockClankerFactoryV1);
        console2.log('BLOCKED: Non-owner cannot remove factory');

        console2.log('SUCCESS: Only owner can manage factories');
    }

    /// @notice Test 7: Works correctly when no factories configured (allows all)
    function test_noFactories_blocksAllTokens() public {
        console2.log('\n=== C-1 Test 7: No Factories = Block All Tokens ===');

        // Verify no factories configured
        address[] memory factories = factory.getTrustedClankerFactories();
        assertEq(factories.length, 0, 'Should have no factories');

        // Deploy token from any factory (fake)
        MockClankerTokenForTest token = MockClankerFactory(fakeClankerFactory).deployToken(
            alice,
            'AnyToken',
            'ANY'
        );

        // Register should FAIL (require at least one trusted factory)
        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        vm.expectRevert('NO_TRUSTED_FACTORIES');
        factory.register(address(token));

        console2.log('BLOCKED: Registration prevented when no factories configured');
        console2.log('Security: Require at least one trusted factory');
    }

    /// @notice Test 8: Token valid in one factory is accepted even if other factories don\'t know it
    function test_multipleFactories_validInOne() public {
        console2.log('\n=== C-1 Test 8: Token Valid In One Factory Is Accepted ===');

        // Add both factories
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        factory.addTrustedClankerFactory(mockClankerFactoryV2);

        // Deploy token ONLY from v1
        MockClankerTokenForTest tokenV1 = MockClankerFactory(mockClankerFactoryV1).deployToken(
            alice,
            'TokenV1',
            'TV1'
        );

        // Register should succeed (valid in v1, even though v2 doesn't know it)
        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        ILevrFactory_v1.Project memory project = factory.register(address(tokenV1));

        assertNotEq(project.staking, address(0), 'Should register successfully');
        console2.log('SUCCESS: Token accepted if valid in ANY trusted factory');
    }

    /// @notice Test edge case: Cannot add zero address
    function test_cannotAdd_zeroAddress() public {
        vm.expectRevert('ZERO_ADDRESS');
        factory.addTrustedClankerFactory(address(0));
    }

    /// @notice Test edge case: Cannot add same factory twice
    function test_cannotAdd_duplicate() public {
        factory.addTrustedClankerFactory(mockClankerFactoryV1);

        vm.expectRevert('ALREADY_TRUSTED');
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
    }

    /// @notice Test edge case: Cannot remove factory that's not trusted
    function test_cannotRemove_notTrusted() public {
        vm.expectRevert('NOT_TRUSTED');
        factory.removeTrustedClankerFactory(mockClankerFactoryV1);
    }

    /// @notice Test: Removing all trusted factories falls back to allow-all mode
    function test_removeAllFactories_blocksNewRegistrations() public {
        console2.log('\n=== C-1 Test 9: Remove All Factories = Block New Registrations ===');

        // Add factory first
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        console2.log('Added factory v1 to trusted list');

        // Deploy token from v1
        MockClankerTokenForTest token1 = MockClankerFactory(mockClankerFactoryV1).deployToken(
            alice,
            'TokenV1',
            'TV1'
        );

        // Should succeed (from trusted factory)
        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        ILevrFactory_v1.Project memory project1 = factory.register(address(token1));
        assertNotEq(project1.staking, address(0), 'Token 1 should register');
        console2.log('SUCCESS: Token from trusted factory v1 registered');

        // Step 2: Remove the trusted factory
        factory.removeTrustedClankerFactory(mockClankerFactoryV1);
        console2.log('Removed trusted factory v1');

        // Verify array is empty
        address[] memory factories = factory.getTrustedClankerFactories();
        assertEq(factories.length, 0, 'Should have no factories');

        // Deploy token from any factory
        MockClankerTokenForTest token2 = MockClankerFactory(fakeClankerFactory).deployToken(
            bob,
            'FakeToken',
            'FAKE'
        );

        // Step 3: Should NOW REVERT because no trusted factories configured
        vm.prank(bob);
        factory.prepareForDeployment();

        vm.prank(bob);
        vm.expectRevert('NO_TRUSTED_FACTORIES');
        factory.register(address(token2));

        console2.log('BLOCKED: New registrations prevented when no trusted factories');
        console2.log('Security: Empty factory list blocks all registrations');
    }

    /// @notice Test: Dynamic factory rotation (remove old, add new)
    function test_dynamicFactoryRotation() public {
        console2.log('\n=== C-1 Test 10: Dynamic Factory Rotation ===');

        // Setup: Add v1 factory
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        console2.log('Phase 1: Added factory v1');

        // Token from v1 should work
        MockClankerTokenForTest tokenV1 = MockClankerFactory(mockClankerFactoryV1).deployToken(
            alice,
            'TokenV1',
            'TV1'
        );

        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        factory.register(address(tokenV1));
        console2.log('Phase 1: Token from v1 registered');

        // Token from v2 should fail (not trusted yet)
        MockClankerTokenForTest tokenV2 = MockClankerFactory(mockClankerFactoryV2).deployToken(
            bob,
            'TokenV2',
            'TV2'
        );

        vm.prank(bob);
        factory.prepareForDeployment();

        vm.prank(bob);
        vm.expectRevert('TOKEN_NOT_FROM_TRUSTED_FACTORY');
        factory.register(address(tokenV2));
        console2.log('Phase 1: Token from v2 blocked (not trusted)');

        // Rotation: Remove v1, add v2
        factory.removeTrustedClankerFactory(mockClankerFactoryV1);
        factory.addTrustedClankerFactory(mockClankerFactoryV2);
        console2.log('Phase 2: Rotated factories (v1 -> v2)');

        // Token from v2 should now work
        MockClankerTokenForTest tokenV2_new = MockClankerFactory(mockClankerFactoryV2).deployToken(
            bob,
            'TokenV2New',
            'TV2N'
        );

        vm.prank(bob);
        factory.prepareForDeployment();

        vm.prank(bob);
        factory.register(address(tokenV2_new));
        console2.log('Phase 2: Token from v2 registered (now trusted)');

        // Token from v1 should now fail (no longer trusted)
        MockClankerTokenForTest tokenV1_new = MockClankerFactory(mockClankerFactoryV1).deployToken(
            alice,
            'TokenV1New',
            'TV1N'
        );

        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        vm.expectRevert('TOKEN_NOT_FROM_TRUSTED_FACTORY');
        factory.register(address(tokenV1_new));
        console2.log('Phase 2: Token from v1 blocked (no longer trusted)');

        console2.log('SUCCESS: Dynamic factory rotation works');
    }

    /// @notice Test: Emergency fallback (remove all during crisis)
    function test_emergencyFallback_removeAllFactories() public {
        console2.log('\n=== C-1 Test 11: Emergency Fallback (Remove All Factories) ===');

        // Setup: Add multiple factories
        factory.addTrustedClankerFactory(mockClankerFactoryV1);
        factory.addTrustedClankerFactory(mockClankerFactoryV2);
        console2.log('Setup: Added factories v1 and v2');

        // Verify both are trusted
        assertTrue(factory.isTrustedClankerFactory(mockClankerFactoryV1), 'V1 should be trusted');
        assertTrue(factory.isTrustedClankerFactory(mockClankerFactoryV2), 'V2 should be trusted');

        address[] memory initialFactories = factory.getTrustedClankerFactories();
        assertEq(initialFactories.length, 2, 'Should have 2 factories');

        // Emergency: Remove all factories
        factory.removeTrustedClankerFactory(mockClankerFactoryV1);
        factory.removeTrustedClankerFactory(mockClankerFactoryV2);
        console2.log('Emergency: Removed all factories');

        // Verify all are removed
        assertFalse(
            factory.isTrustedClankerFactory(mockClankerFactoryV1),
            'V1 should not be trusted'
        );
        assertFalse(
            factory.isTrustedClankerFactory(mockClankerFactoryV2),
            'V2 should not be trusted'
        );

        address[] memory finalFactories = factory.getTrustedClankerFactories();
        assertEq(finalFactories.length, 0, 'Should have no factories');

        // During emergency: NO token can be registered (require at least one trusted factory)
        MockClankerTokenForTest emergencyToken = MockClankerFactory(fakeClankerFactory).deployToken(
            alice,
            'EmergencyToken',
            'EMG'
        );

        vm.prank(alice);
        factory.prepareForDeployment();

        vm.prank(alice);
        vm.expectRevert('NO_TRUSTED_FACTORIES');
        factory.register(address(emergencyToken));

        console2.log('BLOCKED: Registrations prevented when no factories configured');
        console2.log(
            'SUCCESS: Security requirement enforced (must have at least 1 trusted factory)'
        );
    }
}

/// @notice Mock Clanker Token that implements both IClankerToken and ERC20
/// @dev Standalone implementation to properly set admin
contract MockClankerTokenForTest is MockERC20 {
    address private immutable _tokenAdmin;

    constructor(string memory name, string memory symbol, address admin_) MockERC20(name, symbol) {
        _tokenAdmin = admin_;
        // Mint initial supply to admin
        _mint(admin_, 1_000_000 ether);
    }

    /// @notice Override admin() to return the correct admin
    function admin() external view override returns (address) {
        return _tokenAdmin;
    }
}

/// @notice Mock Clanker Factory for testing
contract MockClankerFactory {
    string public version;
    mapping(address => IClanker.DeploymentInfo) private _deploymentInfo;

    constructor(string memory _version) {
        version = _version;
    }

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
