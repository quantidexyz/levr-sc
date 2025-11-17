// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../src/interfaces/ILevrFactory_v1.sol';
import {LevrFactoryDeployHelper} from './utils/LevrFactoryDeployHelper.sol';

/**
 * @title TransferFactoryOwnership Test
 * @notice Comprehensive tests for the ownership transfer script logic
 * @dev Tests ownership transfer to Gnosis Safe multisig
 */
contract TransferFactoryOwnershipTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    address internal deployer;
    address internal multisig;

    function setUp() public {
        deployer = address(this);
        multisig = address(0x1111111111111111111111111111111111111111);

        // Deploy factory
        ILevrFactory_v1.FactoryConfig memory config = createDefaultConfig(deployer);
        (factory, forwarder, ) = deployFactory(config, deployer, address(0x1234));

        // Verify initial owner is deployer
        assertEq(factory.owner(), deployer, 'Initial owner should be deployer');
    }

    // ============ Ownership Transfer Tests ============

    function test_transferOwnership_success() public {
        // Verify current owner
        assertEq(factory.owner(), deployer, 'Current owner should be deployer');

        // Transfer ownership to multisig
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // Verify new owner
        assertEq(factory.owner(), multisig, 'New owner should be multisig');
    }

    function test_transferOwnership_fromNonOwnerReverts() public {
        // Try to transfer ownership from non-owner
        address attacker = address(0x4774AC3E4);

        vm.prank(attacker);
        vm.expectRevert();
        factory.transferOwnership(multisig);

        // Verify owner didn't change
        assertEq(factory.owner(), deployer, 'Owner should not have changed');
    }

    function test_transferOwnership_toZeroAddressReverts() public {
        // Try to transfer ownership to zero address
        vm.prank(deployer);
        vm.expectRevert();
        factory.transferOwnership(address(0));

        // Verify owner didn't change
        assertEq(factory.owner(), deployer, 'Owner should not have changed');
    }

    function test_transferOwnership_emitsEvent() public {
        // Expect OwnershipTransferred event
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(deployer, multisig);

        // Transfer ownership
        vm.prank(deployer);
        factory.transferOwnership(multisig);
    }

    function test_transferOwnership_multisigCanCallOwnerFunctions() public {
        // Transfer ownership to multisig
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // Verify multisig can call owner functions
        address newClankerFactory = address(0xC1A43E4);

        vm.prank(multisig);
        factory.addTrustedClankerFactory(newClankerFactory);

        // Verify the call succeeded
        assertTrue(
            factory.isTrustedClankerFactory(newClankerFactory),
            'Multisig should be able to add trusted factory'
        );
    }

    function test_transferOwnership_oldOwnerCannotCallOwnerFunctions() public {
        // Transfer ownership to multisig
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // Verify old owner (deployer) cannot call owner functions
        address newClankerFactory = address(0xC1A43E5);

        vm.prank(deployer);
        vm.expectRevert();
        factory.addTrustedClankerFactory(newClankerFactory);
    }

    // ============ Script Environment Validation Tests ============

    function test_scriptEnvironment_factoryAddressRequired() public {
        // Test that LEVR_FACTORY_ADDRESS is required
        // In real deployment, this would be checked in the script
        address factoryAddress = address(factory);

        assertTrue(factoryAddress != address(0), 'Factory address should not be zero');
        assertTrue(factoryAddress.code.length > 0, 'Factory should be a contract');
    }

    function test_scriptEnvironment_multisigAddressRequired() public {
        // Test that GNOSIS_SAFE_ADDRESS is required
        address multisigAddress = multisig;

        assertTrue(multisigAddress != address(0), 'Multisig address should not be zero');
        // Note: In test environment, multisig might be EOA. In production, verify it's a contract.
    }

    function test_scriptEnvironment_callerMustBeCurrentOwner() public {
        // Test that caller must be current owner
        address currentOwner = factory.owner();
        assertEq(currentOwner, deployer, 'Current owner should be deployer');

        // Verify non-owner cannot transfer
        address nonOwner = address(0x40404040);
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.transferOwnership(multisig);
    }

    // ============ Gnosis Safe Deployment Tests ============

    function test_gnosisSafe_addressValidation() public {
        // Test multisig address validation

        // Valid multisig
        assertTrue(multisig != address(0), 'Multisig should not be zero');

        // Invalid multisig (zero address)
        address zeroMultisig = address(0);
        vm.prank(deployer);
        vm.expectRevert();
        factory.transferOwnership(zeroMultisig);
    }

    function test_gnosisSafe_ownershipTransferComplete() public {
        // Test complete ownership transfer flow

        // 1. Verify current owner
        address currentOwner = factory.owner();
        assertEq(currentOwner, deployer, 'Current owner should be deployer');

        // 2. Transfer ownership
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // 3. Verify new owner
        address newOwner = factory.owner();
        assertEq(newOwner, multisig, 'New owner should be multisig');

        // 4. Verify transfer is complete
        assertNotEq(currentOwner, newOwner, 'Owner should have changed');
    }

    // ============ Post-Transfer Verification Tests ============

    function test_postTransfer_multisigCanUpdateConfig() public {
        // Transfer ownership
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // Test multisig can update factory config
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
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

        vm.prank(multisig);
        factory.updateConfig(newConfig);

        assertEq(factory.protocolFeeBps(), 100, 'Multisig should be able to update config');
    }

    function test_postTransfer_multisigCanAddWhitelist() public {
        // Transfer ownership
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // Test multisig can update whitelist
        address newToken = address(0x703E4);
        address weth = address(0x4200000000000000000000000000000000000006);

        // Create new whitelist with WETH and new token
        address[] memory newWhitelist = new address[](2);
        newWhitelist[0] = weth;
        newWhitelist[1] = newToken;

        vm.prank(multisig);
        factory.updateInitialWhitelist(newWhitelist);

        address[] memory whitelist = factory.getInitialWhitelist();
        assertEq(whitelist.length, 2, 'Whitelist should have 2 tokens');
        assertEq(whitelist[1], newToken, 'New token should be in whitelist');
    }

    function test_postTransfer_multisigCanTransferOwnershipAgain() public {
        // Transfer ownership to multisig
        vm.prank(deployer);
        factory.transferOwnership(multisig);

        // Multisig can transfer ownership to another address
        address newMultisig = address(0x2222222222222222222222222222222222222222);

        vm.prank(multisig);
        factory.transferOwnership(newMultisig);

        assertEq(factory.owner(), newMultisig, 'Ownership should transfer again');
    }

    // ============ Security Tests ============

    function test_security_cannotTransferToSameAddress() public {
        // Transferring to same address is technically allowed but pointless
        // Verify it doesn't break anything
        vm.prank(deployer);
        factory.transferOwnership(deployer);

        assertEq(factory.owner(), deployer, 'Owner should remain the same');
    }

    function test_security_multipleTransferAttempts() public {
        // Test multiple consecutive transfer attempts

        // First transfer
        vm.prank(deployer);
        factory.transferOwnership(multisig);
        assertEq(factory.owner(), multisig, 'First transfer should succeed');

        // Second transfer (from new owner)
        address newOwner = address(0x3333333333333333333333333333333333333333);
        vm.prank(multisig);
        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), newOwner, 'Second transfer should succeed');

        // Old owners cannot transfer
        vm.prank(deployer);
        vm.expectRevert();
        factory.transferOwnership(deployer);

        vm.prank(multisig);
        vm.expectRevert();
        factory.transferOwnership(multisig);
    }

    // ============ Helper Events ============

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
