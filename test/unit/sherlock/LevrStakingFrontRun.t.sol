// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';

import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {ILevrStaking_v1} from '../../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';

/**
 * @title LevrStakingFrontRun
 * @notice POC tests for Sherlock #23 - Staking initialization front-run vulnerability
 * @dev Tests validate that an attacker can front-run the legitimate initialization
 *      by calling initialize() with their own factory address before the real factory does.
 */
contract LevrStakingFrontRunTest is Test {
    LevrStaking_v1 public staking;
    MockERC20 public underlying;
    MockERC20 public stakedToken;

    address public trustedForwarder = makeAddr('trustedForwarder');
    address public legitimateFactory = makeAddr('legitimateFactory');
    address public treasury = makeAddr('treasury');
    address public attacker = makeAddr('attacker');
    address public attackerFactory = makeAddr('attackerFactory');

    function setUp() public {
        // Deploy mock tokens
        underlying = new MockERC20('Underlying', 'UND');
        stakedToken = new MockERC20('Staked', 'sUND');

        console2.log('=== Front-Run Initialization POC Setup ===');
        console2.log('Legitimate Factory:', legitimateFactory);
        console2.log('Attacker:', attacker);
        console2.log('Attacker Factory:', attackerFactory);
    }

    /**
     * @notice Test Vector 1: Front-run initialization attempt (SHOULD FAIL AFTER FIX)
     * @dev After fix, attacker cannot initialize because factory is set in constructor
     */
    function test_frontRunInitialization_attackPrevented() public {
        console2.log('\n=== Attack Vector 1: Front-Run Initialization (After Fix) ===');

        // Step 1: Legitimate factory deploys staking with factory address in constructor
        vm.prank(legitimateFactory);
        staking = new LevrStaking_v1(trustedForwarder, legitimateFactory);
        console2.log('Staking deployed at:', address(staking));
        console2.log('Factory immutably set to:', staking.factory());

        // Step 2: Attacker tries to front-run initialization
        console2.log('\nAttacker attempting to front-run initialization...');

        address[] memory emptyTokens = new address[](0);

        // Attack FAILS: Only legitimate factory can initialize
        vm.prank(attacker);
        vm.expectRevert(ILevrStaking_v1.OnlyFactory.selector);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        console2.log('[OK] Attack prevented - only factory can initialize');

        // Step 3: Legitimate factory successfully initializes
        console2.log('\nLegitimate factory initializing...');

        vm.prank(legitimateFactory);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        console2.log('[OK] Legitimate initialization succeeded');

        // Step 4: Verify correct factory is set
        assertEq(staking.factory(), legitimateFactory, 'Factory should be legitimate');
        console2.log('Factory correctly set to:', staking.factory());
        console2.log('[OK] FIX VERIFIED: Front-run attack prevented');
    }

    /**
     * @notice Test Vector 2: Attacker cannot bypass OnlyFactory check (AFTER FIX)
     * @dev After fix, factory is immutable and cannot be set by attacker
     */
    function test_attackerCannotBypassOnlyFactoryCheck() public {
        console2.log('\n=== Attack Vector 2: OnlyFactory Check (After Fix) ===');

        // Deploy staking with legitimate factory
        vm.prank(legitimateFactory);
        staking = new LevrStaking_v1(trustedForwarder, legitimateFactory);

        address[] memory emptyTokens = new address[](0);

        // Attacker tries to initialize
        console2.log('Attacker attempting to initialize...');

        vm.prank(attacker);
        // After fix: Check compares against immutable factory (set in constructor)
        // if (_msgSender() != factory) revert OnlyFactory();
        // Becomes: if (attacker != legitimateFactory) revert; ← FAILS!
        vm.expectRevert(ILevrStaking_v1.OnlyFactory.selector);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        console2.log('[OK] OnlyFactory check works correctly');
        console2.log('[OK] Attacker cannot bypass access control');
    }

    /**
     * @notice Test Vector 3: Realistic deployment scenario (AFTER FIX)
     * @dev Shows that front-run attack is prevented after fix
     */
    function test_realisticFrontRunScenario_prevented() public {
        console2.log('\n=== Attack Vector 3: Realistic Deployment (After Fix) ===');

        // Timeline simulation:
        console2.log('Block 100: Factory deploys staking with factory address');
        vm.roll(100);

        vm.prank(legitimateFactory);
        staking = new LevrStaking_v1(trustedForwarder, legitimateFactory);
        console2.log('Staking deployed:', address(staking));
        console2.log('Factory immutably set:', staking.factory());

        // Attacker sees deployment transaction in mempool
        console2.log('\nBlock 100: Attacker sees deployment in mempool');
        console2.log('Attacker extracts staking address from deployment tx');

        // Block 101: Attacker tries to front-run
        console2.log('\nBlock 101: Attacker broadcasts initialize() with higher gas');

        address[] memory emptyTokens = new address[](0);

        vm.prank(attacker);
        vm.expectRevert(ILevrStaking_v1.OnlyFactory.selector);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        console2.log('[OK] Attacker tx reverted - attack prevented');

        // Legitimate register() tx executes successfully
        console2.log('\n[LEGITIMATE] Register() tx executes');

        vm.prank(legitimateFactory);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        console2.log('[OK] Legitimate register() succeeded');

        // Verify deployment successful
        console2.log('\n=== Post-Deployment State ===');
        console2.log('Factory (legitimate):', staking.factory());
        console2.log('Underlying:', staking.underlying());
        console2.log('Treasury:', staking.treasury());

        assertEq(staking.factory(), legitimateFactory, 'Legitimate factory set');

        console2.log('\n[OK] FIX VERIFIED:');
        console2.log('  - Front-run attack prevented');
        console2.log('  - Deployment successful');
        console2.log('  - Factory cannot be changed (immutable)');
    }

    /**
     * @notice Test Vector 4: Attacker cannot control parameters (AFTER FIX)
     * @dev After fix, only factory can initialize with any parameters
     */
    function test_attackerCannotControlParameters() public {
        console2.log('\n=== Attack Vector 4: Parameter Control (After Fix) ===');

        vm.prank(legitimateFactory);
        staking = new LevrStaking_v1(trustedForwarder, legitimateFactory);

        // Attacker prepares malicious parameters
        address maliciousUnderlying = makeAddr('maliciousToken');
        address maliciousStakedToken = makeAddr('maliciousStakedToken');
        address maliciousTreasury = makeAddr('maliciousTreasury');

        address[] memory emptyTokens = new address[](0);

        console2.log('Attacker attempting to set malicious parameters...');

        // Attacker cannot initialize (OnlyFactory check)
        vm.prank(attacker);
        vm.expectRevert(ILevrStaking_v1.OnlyFactory.selector);
        staking.initialize(
            maliciousUnderlying,
            maliciousStakedToken,
            maliciousTreasury,
            emptyTokens
        );

        console2.log('[OK] Attacker prevented from setting parameters');

        // Only legitimate factory can set parameters
        vm.prank(legitimateFactory);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        // Verify all parameters are legitimately set
        assertEq(staking.underlying(), address(underlying));
        assertEq(staking.stakedToken(), address(stakedToken));
        assertEq(staking.treasury(), treasury);
        assertEq(staking.factory(), legitimateFactory);

        console2.log('\n[OK] All parameters controlled by legitimate factory:');
        console2.log('  Underlying:', staking.underlying());
        console2.log('  StakedToken:', staking.stakedToken());
        console2.log('  Treasury:', staking.treasury());
        console2.log('  Factory:', staking.factory());

        console2.log('\n[OK] FIX VERIFIED: Only factory can set parameters');
    }

    /**
     * @notice Test legitimate initialization works after fix
     * @dev Baseline test to show normal operation with immutable factory
     */
    function test_legitimateInitialization_afterFix() public {
        console2.log('\n=== Baseline: Legitimate Initialization (After Fix) ===');

        vm.prank(legitimateFactory);
        staking = new LevrStaking_v1(trustedForwarder, legitimateFactory);

        console2.log('Staking deployed with factory:', staking.factory());

        address[] memory emptyTokens = new address[](0);

        // Legitimate initialization (factory set in constructor)
        vm.prank(legitimateFactory);
        staking.initialize(address(underlying), address(stakedToken), treasury, emptyTokens);

        // Verify correct initialization
        assertEq(staking.factory(), legitimateFactory);
        assertEq(staking.underlying(), address(underlying));
        assertEq(staking.stakedToken(), address(stakedToken));
        assertEq(staking.treasury(), treasury);

        console2.log('[OK] Legitimate initialization successful');
        console2.log('Factory (immutable):', staking.factory());
        console2.log('Underlying:', staking.underlying());
        console2.log('StakedToken:', staking.stakedToken());
        console2.log('Treasury:', staking.treasury());
    }
}
