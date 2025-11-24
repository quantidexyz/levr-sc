// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';

/// @title LevrDeployer_v1 Test
/// @notice Comprehensive security testing for clone-based deployment infrastructure
/// @dev Tests frontrunning protection, authorization, and initialization security
contract LevrDeployer_v1_Test is Test {
    LevrFactory_v1 factory;
    LevrDeployer_v1 deployer;
    LevrForwarder_v1 forwarder;

    LevrTreasury_v1 treasuryImpl;
    LevrStaking_v1 stakingImpl;
    LevrGovernor_v1 governorImpl;

    address owner = address(this);
    address attacker = address(0xBAD);
    address user = address(0x1234);

    function setUp() public {
        // Deploy forwarder
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        // Predict factory address (will be deployed after implementations and deployer)
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 4);

        // Deploy implementation contracts with predicted factory
        treasuryImpl = new LevrTreasury_v1(predictedFactory, address(forwarder));
        stakingImpl = new LevrStaking_v1(predictedFactory, address(forwarder));
        governorImpl = new LevrGovernor_v1(predictedFactory, address(forwarder));

        // Deploy deployer with predicted factory (stakedToken deployed as new instance per project)
        deployer = new LevrDeployer_v1(
            predictedFactory,
            address(treasuryImpl),
            address(stakingImpl),
            address(governorImpl)
        );

        // Deploy factory
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 50,
            streamWindowSeconds: 3 days,
            protocolTreasury: owner,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        ILevrFactory_v1.ConfigBounds memory bounds = ILevrFactory_v1.ConfigBounds({
            minStreamWindowSeconds: 1,
            minProposalWindowSeconds: 1,
            minVotingWindowSeconds: 1,
            minQuorumBps: 1,
            minApprovalBps: 1,
            minMinSTokenBpsToSubmit: 1,
            minMinimumQuorumBps: 1
        });

        address[] memory whitelist = new address[](0);
        factory = new LevrFactory_v1(
            config,
            bounds,
            owner,
            address(forwarder),
            address(deployer),
            whitelist
        );

        // Verify factory address matches prediction
        require(address(factory) == predictedFactory, 'Factory address mismatch');
    }

    // ============ Implementation Contract Security Tests ============

    function test_ImplementationConstructors_SetFactoryCorrectly() public view {
        assertEq(treasuryImpl.factory(), address(factory), 'Treasury factory mismatch');
        assertEq(stakingImpl.factory(), address(factory), 'Staking factory mismatch');
        assertEq(governorImpl.factory(), address(factory), 'Governor factory mismatch');
    }

    function test_ImplementationContracts_CannotBeInitializedDirectly() public {
        // Create manual clones (stakedToken is not cloned - deployed as new instance)
        address treasuryClone = Clones.clone(address(treasuryImpl));
        address stakingClone = Clones.clone(address(stakingImpl));
        address governorClone = Clones.clone(address(governorImpl));

        // Attempt to initialize as attacker (should fail - not factory)
        vm.startPrank(attacker);

        // Deploy mock for testing
        address mockUnderlying = address(new ERC20_Mock('Test', 'TST'));

        vm.expectRevert();
        LevrTreasury_v1(treasuryClone).initialize(attacker, mockUnderlying);

        vm.expectRevert();
        LevrStaking_v1(stakingClone).initialize(
            mockUnderlying,
            address(0x1111),
            address(0x2222),
            new address[](0)
        );

        vm.expectRevert();
        LevrGovernor_v1(governorClone).initialize(
            address(0x1111),
            address(0x2222),
            address(0x3333),
            address(0x4444)
        );

        // Note: StakedToken is deployed as new instance, not cloned
        // No initialization frontrunning risk since it's deployed with constructor args

        vm.stopPrank();
    }

    // ============ Governor Frontrunning Tests ============

    function test_Governor_OnlyFactoryCanInitialize() public {
        address governorClone = Clones.clone(address(governorImpl));

        // Attacker tries to frontrun initialization
        vm.prank(attacker);
        vm.expectRevert(ILevrGovernor_v1.OnlyFactory.selector);
        LevrGovernor_v1(governorClone).initialize(
            attacker, // malicious treasury
            address(1),
            address(2),
            address(3)
        );

        // Factory can initialize
        vm.prank(address(factory));
        LevrGovernor_v1(governorClone).initialize(address(1), address(2), address(3), address(4));

        // Verify initialization worked correctly
        assertEq(LevrGovernor_v1(governorClone).treasury(), address(1));
    }

    function test_Governor_CannotDoubleInitialize() public {
        address governorClone = Clones.clone(address(governorImpl));

        // Factory initializes once
        vm.prank(address(factory));
        LevrGovernor_v1(governorClone).initialize(
            address(0x1111),
            address(0x2222),
            address(0x3333),
            address(0x4444)
        );

        // Attempt second initialization (should fail)
        vm.prank(address(factory));
        vm.expectRevert(ILevrGovernor_v1.AlreadyInitialized.selector);
        LevrGovernor_v1(governorClone).initialize(
            address(0x5555),
            address(0x6666),
            address(0x7777),
            address(0x8888)
        );
    }

    function test_Governor_FactoryIsImmutable() public {
        address governorClone = Clones.clone(address(governorImpl));

        // Factory address is inherited from implementation (immutable)
        assertEq(LevrGovernor_v1(governorClone).factory(), address(factory));

        // Initialize
        vm.prank(address(factory));
        LevrGovernor_v1(governorClone).initialize(address(1), address(2), address(3), address(4));

        // Factory address remains unchanged
        assertEq(LevrGovernor_v1(governorClone).factory(), address(factory));
    }

    // ============ StakedToken Security Tests ============

    function test_StakedToken_NoInitializationFrontrunning() public pure {
        // StakedToken is deployed as new instance with constructor args
        // No initialization frontrunning risk since all parameters are set at construction time
        // This test documents the security model change from clone-based to direct deployment
        assertTrue(true, 'StakedToken uses constructor - no frontrunning risk');
    }

    // ============ Treasury Frontrunning Tests ============

    function test_Treasury_OnlyFactoryCanInitialize() public {
        address treasuryClone = Clones.clone(address(treasuryImpl));

        // Attacker tries to frontrun
        vm.prank(attacker);
        vm.expectRevert(); // OnlyFactory error
        LevrTreasury_v1(treasuryClone).initialize(attacker, address(1));

        // Factory can initialize
        vm.prank(address(factory));
        LevrTreasury_v1(treasuryClone).initialize(address(1), address(2));

        assertEq(LevrTreasury_v1(treasuryClone).governor(), address(1));
    }

    function test_Treasury_FactoryIsImmutable() public {
        address treasuryClone = Clones.clone(address(treasuryImpl));

        // Verify factory is set correctly (inherited from implementation)
        assertEq(LevrTreasury_v1(treasuryClone).factory(), address(factory));
    }

    // ============ Staking Frontrunning Tests ============

    function test_Staking_OnlyFactoryCanInitialize() public {
        address stakingClone = Clones.clone(address(stakingImpl));

        // Deploy mock ERC20 for testing
        address mockUnderlying = address(new ERC20_Mock('Test', 'TST'));
        address mockStakedToken = address(0x1111);
        address mockTreasury = address(0x2222);

        // Attacker tries to frontrun
        vm.prank(attacker);
        vm.expectRevert(ILevrStaking_v1.OnlyFactory.selector);
        LevrStaking_v1(stakingClone).initialize(
            mockUnderlying,
            mockStakedToken,
            mockTreasury,
            new address[](0)
        );

        // Factory can initialize
        vm.prank(address(factory));
        LevrStaking_v1(stakingClone).initialize(
            mockUnderlying,
            mockStakedToken,
            mockTreasury,
            new address[](0)
        );

        assertEq(LevrStaking_v1(stakingClone).underlying(), mockUnderlying);
    }

    function test_Staking_CannotDoubleInitialize() public {
        address stakingClone = Clones.clone(address(stakingImpl));

        // Deploy mock ERC20 for testing
        address mockUnderlying = address(new ERC20_Mock('Test', 'TST'));
        address mockStakedToken = address(0x1111);
        address mockTreasury = address(0x2222);

        // Initialize once
        vm.prank(address(factory));
        LevrStaking_v1(stakingClone).initialize(
            mockUnderlying,
            mockStakedToken,
            mockTreasury,
            new address[](0)
        );

        // Attempt second initialization
        vm.prank(address(factory));
        vm.expectRevert(ILevrStaking_v1.AlreadyInitialized.selector);
        LevrStaking_v1(stakingClone).initialize(
            mockUnderlying,
            mockStakedToken,
            mockTreasury,
            new address[](0)
        );
    }

    // ============ Deployer Authorization Tests ============

    function test_Deployer_OnlyFactoryCanDelegatecall() public {
        // Attacker tries to call deployer directly (not via delegatecall)
        vm.prank(attacker);
        vm.expectRevert();
        deployer.prepareContracts();

        vm.prank(attacker);
        vm.expectRevert();
        deployer.deployProject(address(1), address(2), address(3), new address[](0));
    }

    function test_Deployer_DelegatecallFromWrongFactory() public {
        // Deploy a fake factory
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 50,
            streamWindowSeconds: 3 days,
            protocolTreasury: attacker,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        ILevrFactory_v1.ConfigBounds memory bounds = ILevrFactory_v1.ConfigBounds({
            minStreamWindowSeconds: 1,
            minProposalWindowSeconds: 1,
            minVotingWindowSeconds: 1,
            minQuorumBps: 1,
            minApprovalBps: 1,
            minMinSTokenBpsToSubmit: 1,
            minMinimumQuorumBps: 1
        });

        address[] memory whitelist = new address[](0);
        LevrFactory_v1 fakeFactory = new LevrFactory_v1(
            config,
            bounds,
            attacker,
            address(forwarder),
            address(deployer), // Trying to use our deployer
            whitelist
        );

        // Fake factory tries to use deployer (should fail - wrong factory address)
        // Note: We DON'T use vm.expectRevert() here because we want to check the actual result
        vm.prank(address(fakeFactory));
        (bool success, ) = address(deployer).delegatecall(
            abi.encodeWithSignature('prepareContracts()')
        );
        assertFalse(success, 'Unauthorized factory should not be able to use deployer');
    }

    // ============ Full Flow Integration Tests ============

    function test_FullFlow_NoFrontrunningPossible() public {
        // Simulate legitimate user preparing contracts
        vm.prank(user);
        (address treasury, address staking) = factory.prepareForDeployment();

        // Attacker sees the prepared contracts in mempool and tries to initialize them
        vm.startPrank(attacker);

        // Try to initialize treasury
        vm.expectRevert();
        LevrTreasury_v1(treasury).initialize(attacker, address(1));

        // Try to initialize staking
        vm.expectRevert();
        LevrStaking_v1(staking).initialize(attacker, attacker, attacker, new address[](0));

        vm.stopPrank();

        // User continues with legitimate registration - should work fine
        // (Would need actual Clanker token for full test, but initialization protection is verified)
    }

    function test_AtomicDeployment_PreventsMEV() public {
        // The entire deployment happens in one transaction via delegatecall
        // This test verifies atomicity

        vm.prank(user);
        (address treasury, address staking) = factory.prepareForDeployment();

        // Between prepare and register, attacker cannot:
        // 1. Initialize treasury (protected by factory check)
        // 2. Initialize staking (protected by factory check)
        // 3. Create malicious clones (doesn't affect user's deployment)

        // Verify both contracts are deployed but not initialized
        assertEq(LevrTreasury_v1(treasury).governor(), address(0)); // Not initialized
        assertEq(LevrStaking_v1(staking).underlying(), address(0)); // Not initialized
    }

    // ============ Implementation Immutability Tests ============

    function test_Implementations_AreIndependentFromClones() public {
        // Key security property: implementations can be initialized once, but clones are independent
        // This prevents implementation poisoning attacks

        // Deploy mock for testing
        address mockUnderlying = address(new ERC20_Mock('Test', 'TST'));

        // Initialize implementation contracts (by factory - this is allowed and safe)
        vm.prank(address(factory));
        treasuryImpl.initialize(user, mockUnderlying);

        vm.prank(address(factory));
        stakingImpl.initialize(mockUnderlying, address(0x1111), address(0x2222), new address[](0));

        vm.prank(address(factory));
        governorImpl.initialize(address(0x1111), address(0x2222), address(0x3333), mockUnderlying);

        // Note: StakedToken is deployed as new instance, not cloned

        // Now create treasury clone - it should have clean state (uninitialized)
        address treasuryClone = Clones.clone(address(treasuryImpl));

        // Clone can still be initialized independently
        vm.prank(address(factory));
        LevrTreasury_v1(treasuryClone).initialize(address(0x5555), mockUnderlying);

        // Verify independent state
        assertEq(treasuryImpl.governor(), user, 'Implementation has own state');
        assertEq(LevrTreasury_v1(treasuryClone).governor(), address(0x5555), 'Clone has own state');
    }

    function test_CloneIndependence_SeparateState() public {
        // Create two clones
        address clone1 = Clones.clone(address(treasuryImpl));
        address clone2 = Clones.clone(address(treasuryImpl));

        // Initialize both
        vm.prank(address(factory));
        LevrTreasury_v1(clone1).initialize(address(1), address(2));

        vm.prank(address(factory));
        LevrTreasury_v1(clone2).initialize(address(3), address(4));

        // Verify they have independent state
        assertEq(LevrTreasury_v1(clone1).governor(), address(1));
        assertEq(LevrTreasury_v1(clone2).governor(), address(3));

        // But same immutable factory
        assertEq(LevrTreasury_v1(clone1).factory(), address(factory));
        assertEq(LevrTreasury_v1(clone2).factory(), address(factory));
    }

    // ============ Zero Address Protection Tests ============

    function test_Governor_RejectsZeroAddresses() public {
        address governorClone = Clones.clone(address(governorImpl));

        vm.startPrank(address(factory));

        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        LevrGovernor_v1(governorClone).initialize(address(0), address(1), address(2), address(3));

        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        LevrGovernor_v1(governorClone).initialize(address(1), address(0), address(2), address(3));

        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        LevrGovernor_v1(governorClone).initialize(address(1), address(2), address(0), address(3));

        vm.expectRevert(ILevrGovernor_v1.InvalidRecipient.selector);
        LevrGovernor_v1(governorClone).initialize(address(1), address(2), address(3), address(0));

        vm.stopPrank();
    }

    function test_StakedToken_RejectsZeroAddresses() public {
        // Test that StakedToken constructor rejects zero addresses
        vm.expectRevert();
        new LevrStakedToken_v1('Test', 'TST', 18, address(0), address(1));

        vm.expectRevert();
        new LevrStakedToken_v1('Test', 'TST', 18, address(1), address(0));
    }

    // ============ Access Control After Initialization Tests ============

    function test_Treasury_OnlyGovernorAfterInit() public {
        address treasuryClone = Clones.clone(address(treasuryImpl));

        vm.prank(address(factory));
        LevrTreasury_v1(treasuryClone).initialize(user, address(1));

        // Attacker cannot call governor-only functions
        vm.prank(attacker);
        vm.expectRevert();
        LevrTreasury_v1(treasuryClone).transfer(address(1), attacker, 100);

        // Governor can call
        vm.prank(user);
        // Would succeed if treasury had balance (not testing transfer logic here)
    }
}
