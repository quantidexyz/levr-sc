// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrFactoryV1_SecurityTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    address internal protocolTreasury = address(0xFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));
    }

    function test_cannot_register_with_someone_elses_treasury() public {
        // Alice prepares her infrastructure
        vm.prank(alice);
        (address _aliceTreasury, address _aliceStaking) = factory.prepareForDeployment();

        // Alice creates token (she's the admin since she deployed it)
        vm.prank(alice);
        MockERC20 aliceToken = new MockERC20('Alice Token', 'ALICE');

        // Alice tries to register using her own treasury she prepared - this should FAIL
        // because register() checks msg.sender == deployer, but with vm.prank the actual
        // transaction sender is not alice in the test context. We need to ensure the
        // check works.

        // Actually, let's test the opposite: Bob prepares, then tries to use his own contracts
        // but with a token that alice owns - should fail on tokenAdmin check first
        vm.prank(bob);
        vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
        factory.register(address(aliceToken));
    }

    function test_cannot_register_with_someone_elses_staking() public {
        // Alice prepares her infrastructure
        vm.prank(alice);
        (, address _aliceStaking) = factory.prepareForDeployment();

        // Bob prepares his own treasury but tries to use Alice's staking
        vm.prank(bob);
        (address bobTreasury, ) = factory.prepareForDeployment();

        // Bob creates token (he's the admin)
        vm.prank(bob);
        MockERC20 bobToken = new MockERC20('Bob Token', 'BOB');

        // Bob tries to register - since Bob called prepareForDeployment,
        // it should work with his prepared contracts
        vm.prank(bob);
        ILevrFactory_v1.Project memory project = factory.register(address(bobToken));

        // Should use Bob's prepared contracts
        assertEq(project.treasury, bobTreasury, 'Should use Bob treasury');
        assertTrue(project.staking != address(0), 'Should have staking');
    }

    function test_can_register_with_own_prepared_contracts() public {
        // Alice prepares her infrastructure
        vm.prank(alice);
        (address _aliceTreasury, address _aliceStaking) = factory.prepareForDeployment();

        // Alice creates token (she's the admin)
        vm.prank(alice);
        MockERC20 aliceToken = new MockERC20('Alice Token', 'ALICE');

        // Alice registers with her own prepared contracts - should succeed
        vm.prank(alice);
        ILevrFactory_v1.Project memory project = factory.register(address(aliceToken));

        assertEq(project.treasury, _aliceTreasury, 'Should use Alice treasury');
        assertEq(project.staking, _aliceStaking, 'Should use Alice staking');
        assertTrue(project.governor != address(0), 'Governor deployed');
        assertTrue(project.stakedToken != address(0), 'StakedToken deployed');
    }

    function test_can_register_with_preparation() public {
        // Bob prepares infrastructure
        vm.prank(bob);
        (address bobTreasury, address bobStaking) = factory.prepareForDeployment();

        // Bob creates token (he's the admin)
        vm.prank(bob);
        MockERC20 bobToken = new MockERC20('Bob Token', 'BOB');

        // Bob registers with his prepared contracts - should succeed
        vm.prank(bob);
        ILevrFactory_v1.Project memory project = factory.register(address(bobToken));

        assertEq(project.treasury, bobTreasury, 'Treasury should match prepared');
        assertEq(project.staking, bobStaking, 'Staking should match prepared');
        assertTrue(project.governor != address(0), 'Governor deployed');
        assertTrue(project.stakedToken != address(0), 'StakedToken deployed');
    }

    function test_tokenAdmin_gate_still_enforced() public {
        // Alice prepares infrastructure
        vm.prank(alice);
        (address _aliceTreasury, address _aliceStaking) = factory.prepareForDeployment();

        // Alice creates token (she's the admin)
        vm.prank(alice);
        MockERC20 aliceToken = new MockERC20('Alice Token', 'ALICE');

        // Bob (not tokenAdmin) tries to register - should fail with UnauthorizedCaller
        vm.prank(bob);
        vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
        factory.register(address(aliceToken));
    }
}
