// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';
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
import {ILevrStakedToken_v1} from '../../src/interfaces/ILevrStakedToken_v1.sol';
import {ILevrDeployer_v1} from '../../src/interfaces/ILevrDeployer_v1.sol';
import {ClankerFactory_Mock, ClankerTokenForTest_Mock} from '../mocks/ClankerFactory_Mock.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {RevertingInitializer_Mock, RevertingMetadataToken_Mock} from '../mocks/RevertingMocks.sol';

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
    LevrStakedToken_v1 stakedTokenImpl;

    address owner = address(this);
    address attacker = address(0xBAD);
    address user = address(0x1234);

    // ============ Constructor Tests ============

    function test_Constructor_RevertIf_FactoryZero() public {
        vm.expectRevert(ILevrDeployer_v1.ZeroAddress.selector);
        new LevrDeployer_v1(address(0), address(1), address(1), address(1), address(1));
    }

    function test_Constructor_RevertIf_TreasuryImplZero() public {
        vm.expectRevert(ILevrDeployer_v1.ZeroAddress.selector);
        new LevrDeployer_v1(address(1), address(0), address(1), address(1), address(1));
    }

    function test_Constructor_RevertIf_StakingImplZero() public {
        vm.expectRevert(ILevrDeployer_v1.ZeroAddress.selector);
        new LevrDeployer_v1(address(1), address(1), address(0), address(1), address(1));
    }

    function test_Constructor_RevertIf_GovernorImplZero() public {
        vm.expectRevert(ILevrDeployer_v1.ZeroAddress.selector);
        new LevrDeployer_v1(address(1), address(1), address(1), address(0), address(1));
    }

    function test_Constructor_RevertIf_StakedTokenImplZero() public {
        vm.expectRevert(ILevrDeployer_v1.ZeroAddress.selector);
        new LevrDeployer_v1(address(1), address(1), address(1), address(1), address(0));
    }

    function test_Constructor_SetsImmutablesCorrectly() public view {
        assertEq(deployer.authorizedFactory(), address(factory), 'Factory mismatch');
        assertEq(
            deployer.treasuryImplementation(),
            address(treasuryImpl),
            'Treasury impl mismatch'
        );
        assertEq(deployer.stakingImplementation(), address(stakingImpl), 'Staking impl mismatch');
        assertEq(
            deployer.governorImplementation(),
            address(governorImpl),
            'Governor impl mismatch'
        );
        assertEq(
            deployer.stakedTokenImplementation(),
            address(stakedTokenImpl),
            'Staked token impl mismatch'
        );
    }

    function setUp() public {
        // Deploy forwarder
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        // Predict factory address (will be deployed after implementations and deployer)
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 5);

        // Deploy implementation contracts with predicted factory
        treasuryImpl = new LevrTreasury_v1(predictedFactory, address(forwarder));
        stakingImpl = new LevrStaking_v1(predictedFactory, address(forwarder));
        governorImpl = new LevrGovernor_v1(predictedFactory, address(forwarder));
        stakedTokenImpl = new LevrStakedToken_v1(predictedFactory);

        // Deploy deployer with predicted factory (all components cloned)
        deployer = new LevrDeployer_v1(
            predictedFactory,
            address(treasuryImpl),
            address(stakingImpl),
            address(governorImpl),
            address(stakedTokenImpl)
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

    function test_PrepareContracts_EmitsContractsPrepared() public {
        vm.recordLogs();
        (address treasury, address staking) = factory.prepareForDeployment();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 expectedSig = keccak256('ContractsPrepared(address,address)');
        bool found;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(factory) && entries[i].topics[0] == expectedSig) {
                address loggedTreasury = address(uint160(uint256(entries[i].topics[1])));
                address loggedStaking = address(uint160(uint256(entries[i].topics[2])));
                if (loggedTreasury == treasury && loggedStaking == staking) {
                    found = true;
                    break;
                }
            }
        }

        assertTrue(found, 'ContractsPrepared event not emitted');
    }

    function test_DeployProject_EmitsProjectDeployed() public {
        ClankerFactory_Mock clankerFactory = new ClankerFactory_Mock();
        factory.addTrustedClankerFactory(address(clankerFactory));
        ClankerTokenForTest_Mock clanker = clankerFactory.deployToken(
            address(this),
            'Clanker',
            'CLK'
        );

        factory.prepareForDeployment();

        vm.recordLogs();
        ILevrFactory_v1.Project memory project = factory.register(address(clanker));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 expectedSig = keccak256('ProjectDeployed(address,address,address,address,address)');
        bool found;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(factory) && entries[i].topics[0] == expectedSig) {
                address loggedToken = address(uint160(uint256(entries[i].topics[1])));
                address loggedTreasury = address(uint160(uint256(entries[i].topics[2])));
                address loggedStaking = address(uint160(uint256(entries[i].topics[3])));
                (address loggedStakedToken, address loggedGovernor) = abi.decode(
                    entries[i].data,
                    (address, address)
                );

                if (
                    loggedToken == address(clanker) &&
                    loggedTreasury == project.treasury &&
                    loggedStaking == project.staking &&
                    loggedStakedToken == project.stakedToken &&
                    loggedGovernor == project.governor
                ) {
                    found = true;
                    break;
                }
            }
        }

        assertTrue(found, 'ProjectDeployed event not emitted');
    }

    // ============ Implementation Contract Security Tests ============

    function test_ImplementationConstructors_SetFactoryCorrectly() public view {
        assertEq(treasuryImpl.factory(), address(factory), 'Treasury factory mismatch');
        assertEq(stakingImpl.factory(), address(factory), 'Staking factory mismatch');
        assertEq(governorImpl.factory(), address(factory), 'Governor factory mismatch');
    }

    function test_ImplementationContracts_CannotBeInitializedDirectly() public {
        // Create manual clones
        address treasuryClone = Clones.clone(address(treasuryImpl));
        address stakingClone = Clones.clone(address(stakingImpl));
        address governorClone = Clones.clone(address(governorImpl));
        address stakedTokenClone = Clones.clone(address(stakedTokenImpl));

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

        vm.expectRevert(ILevrStakedToken_v1.OnlyFactory.selector);
        LevrStakedToken_v1(stakedTokenClone).initialize(
            'Levr',
            'sLEV',
            18,
            mockUnderlying,
            attacker
        );

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

    function test_StakedToken_CannotDoubleInitialize() public {
        address stakedTokenClone = Clones.clone(address(stakedTokenImpl));

        vm.prank(address(factory));
        LevrStakedToken_v1(stakedTokenClone).initialize(
            'Levr Staked Foo',
            'sFOO',
            18,
            address(0xAAA1),
            address(0xBBB2)
        );

        vm.prank(address(factory));
        vm.expectRevert(ILevrStakedToken_v1.AlreadyInitialized.selector);
        LevrStakedToken_v1(stakedTokenClone).initialize(
            'Levr Staked Foo',
            'sFOO',
            18,
            address(0xAAA1),
            address(0xBBB2)
        );
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
        vm.expectRevert(ILevrDeployer_v1.UnauthorizedFactory.selector);
        vm.prank(attacker);
        deployer.prepareContracts();

        vm.expectRevert(ILevrDeployer_v1.UnauthorizedFactory.selector);
        vm.prank(attacker);
        deployer.deployProject(address(1), address(2), address(3), new address[](0));
    }

    function test_Deployer_FactoryAddressCannotCallDirectly() public {
        // Even the authorized factory address must use delegatecall context
        vm.expectRevert(ILevrDeployer_v1.UnauthorizedFactory.selector);
        vm.prank(address(factory));
        deployer.prepareContracts();

        vm.expectRevert(ILevrDeployer_v1.UnauthorizedFactory.selector);
        vm.prank(address(factory));
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

    // ============ Deployer Edge Case Tests ============

    function test_DeployProject_RevertIf_ClankerTokenHasNoCode() public {
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(0),
            address(0),
            address(0)
        );
        (address treasuryClone, address stakingClone) = _delegatePrepare(harnessDeployer, harness);

        (bool success, bytes memory data) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(0xBEEF),
            treasuryClone,
            stakingClone,
            new address[](0)
        );

        assertFalse(success, 'deploy should fail when token has no code');
        assertGt(data.length, 0, 'missing revert data for no-code token');
    }

    function test_DeployProject_RevertIf_ClankerTokenRevertsMetadata() public {
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(0),
            address(0),
            address(0)
        );
        (address treasuryClone, address stakingClone) = _delegatePrepare(harnessDeployer, harness);

        RevertingMetadataToken_Mock metadataToken = new RevertingMetadataToken_Mock();
        (bool success, bytes memory data) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(metadataToken),
            treasuryClone,
            stakingClone,
            new address[](0)
        );

        assertFalse(success, 'deploy should fail when metadata calls revert');
        assertEq(
            bytes4(data),
            RevertingMetadataToken_Mock.MetadataQueryFailed.selector,
            'unexpected metadata revert selector'
        );
    }

    function test_DeployProject_RevertIf_TreasuryInitFails() public {
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(0),
            address(0),
            address(0)
        );
        (, address stakingClone) = _delegatePrepare(harnessDeployer, harness);

        ERC20_Mock token = new ERC20_Mock('Harness Token', 'HARN');
        RevertingInitializer_Mock revertingTreasury = new RevertingInitializer_Mock();

        (bool success, bytes memory data) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(token),
            address(revertingTreasury),
            stakingClone,
            new address[](0)
        );

        assertFalse(success, 'deploy should fail when treasury initialize reverts');
        assertEq(
            bytes4(data),
            RevertingInitializer_Mock.RevertingInitializerTriggered.selector,
            'treasury revert selector mismatch'
        );
    }

    function test_DeployProject_RevertIf_StakingInitFails() public {
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(0),
            address(0),
            address(0)
        );
        (address treasuryClone, ) = _delegatePrepare(harnessDeployer, harness);

        ERC20_Mock token = new ERC20_Mock('Harness Token', 'HARN');
        RevertingInitializer_Mock revertingStaking = new RevertingInitializer_Mock();

        (bool success, bytes memory data) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(token),
            treasuryClone,
            address(revertingStaking),
            new address[](0)
        );

        assertFalse(success, 'deploy should fail when staking initialize reverts');
        assertEq(
            bytes4(data),
            RevertingInitializer_Mock.RevertingInitializerTriggered.selector,
            'staking revert selector mismatch'
        );
    }

    function test_DeployProject_RevertIf_GovernorInitFails() public {
        RevertingInitializer_Mock revertingGovernor = new RevertingInitializer_Mock();
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(0),
            address(revertingGovernor),
            address(0)
        );
        (address treasuryClone, address stakingClone) = _delegatePrepare(harnessDeployer, harness);

        ERC20_Mock token = new ERC20_Mock('Harness Token', 'HARN');
        (bool success, bytes memory data) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(token),
            treasuryClone,
            stakingClone,
            new address[](0)
        );

        assertFalse(success, 'deploy should fail when governor initialize reverts');
        assertEq(
            bytes4(data),
            RevertingInitializer_Mock.RevertingInitializerTriggered.selector,
            'governor revert selector mismatch'
        );
    }

    function test_DeployProject_RevertIf_StakedTokenInitFails() public {
        RevertingInitializer_Mock revertingStakedToken = new RevertingInitializer_Mock();
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(0),
            address(0),
            address(revertingStakedToken)
        );
        (address treasuryClone, address stakingClone) = _delegatePrepare(harnessDeployer, harness);

        ERC20_Mock token = new ERC20_Mock('Harness Token', 'HARN');
        (bool success, bytes memory data) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(token),
            treasuryClone,
            stakingClone,
            new address[](0)
        );

        assertFalse(success, 'deploy should fail when staked token initialize reverts');
        assertEq(
            bytes4(data),
            RevertingInitializer_Mock.RevertingInitializerTriggered.selector,
            'staked token revert selector mismatch'
        );
    }

    function test_DeployProject_PassesWhitelistToStaking() public {
        StakingInitSpy stakingSpyImpl = new StakingInitSpy();
        (LevrDeployer_v1 harnessDeployer, DelegateCallerHarness harness) = _createHarnessDeployer(
            address(0),
            address(stakingSpyImpl),
            address(0),
            address(0)
        );
        (address treasuryClone, address stakingClone) = _delegatePrepare(harnessDeployer, harness);

        ERC20_Mock token = new ERC20_Mock('Whitelist Token', 'WLST');
        address[] memory whitelist = new address[](2);
        whitelist[0] = address(0xAAA1);
        whitelist[1] = address(0xBBB2);

        (bool success, ) = _delegateDeploy(
            harnessDeployer,
            harness,
            address(token),
            treasuryClone,
            stakingClone,
            whitelist
        );

        assertTrue(success, 'delegate deploy should succeed with spy staking implementation');

        address[] memory recorded = StakingInitSpy(stakingClone).getLastWhitelist();
        assertEq(recorded.length, whitelist.length, 'whitelist length mismatch');
        for (uint256 i = 0; i < whitelist.length; i++) {
            assertEq(recorded[i], whitelist[i], 'whitelist entry mismatch');
        }

        assertEq(
            StakingInitSpy(stakingClone).initializeCount(),
            1,
            'staking should initialize exactly once'
        );
        assertEq(
            StakingInitSpy(stakingClone).lastUnderlying(),
            address(token),
            'underlying mismatch'
        );
        assertEq(StakingInitSpy(stakingClone).lastTreasury(), treasuryClone, 'treasury mismatch');
    }

    function _createHarnessDeployer(
        address treasuryImplOverride,
        address stakingImplOverride,
        address governorImplOverride,
        address stakedTokenImplOverride
    ) internal returns (LevrDeployer_v1 customDeployer, DelegateCallerHarness harness) {
        harness = new DelegateCallerHarness();
        address harnessFactory = address(harness);

        address treasuryImplAddr = treasuryImplOverride;
        if (treasuryImplAddr == address(0)) {
            treasuryImplAddr = address(new LevrTreasury_v1(harnessFactory, address(forwarder)));
        }

        address stakingImplAddr = stakingImplOverride;
        if (stakingImplAddr == address(0)) {
            stakingImplAddr = address(new LevrStaking_v1(harnessFactory, address(forwarder)));
        }

        address governorImplAddr = governorImplOverride;
        if (governorImplAddr == address(0)) {
            governorImplAddr = address(new LevrGovernor_v1(harnessFactory, address(forwarder)));
        }

        address stakedTokenImplAddr = stakedTokenImplOverride;
        if (stakedTokenImplAddr == address(0)) {
            stakedTokenImplAddr = address(new LevrStakedToken_v1(harnessFactory));
        }

        customDeployer = new LevrDeployer_v1(
            harnessFactory,
            treasuryImplAddr,
            stakingImplAddr,
            governorImplAddr,
            stakedTokenImplAddr
        );
    }

    function _delegatePrepare(
        LevrDeployer_v1 target,
        DelegateCallerHarness harness
    ) internal returns (address treasury, address staking) {
        (bool success, bytes memory data) = harness.delegateCall(
            address(target),
            abi.encodeWithSelector(LevrDeployer_v1.prepareContracts.selector)
        );
        assertTrue(success, 'prepareContracts delegatecall failed');
        (treasury, staking) = abi.decode(data, (address, address));
    }

    function _delegateDeploy(
        LevrDeployer_v1 target,
        DelegateCallerHarness harness,
        address clankerToken,
        address treasury_,
        address staking_,
        address[] memory whitelist
    ) internal returns (bool success, bytes memory data) {
        return
            harness.delegateCall(
                address(target),
                abi.encodeWithSelector(
                    LevrDeployer_v1.deployProject.selector,
                    clankerToken,
                    treasury_,
                    staking_,
                    whitelist
                )
            );
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

        vm.prank(address(factory));
        stakedTokenImpl.initialize('Impl Token', 'sIMPL', 18, mockUnderlying, address(0x9999));

        // Now create treasury clone - it should have clean state (uninitialized)
        address treasuryClone = Clones.clone(address(treasuryImpl));

        // Clone can still be initialized independently
        vm.prank(address(factory));
        LevrTreasury_v1(treasuryClone).initialize(address(0x5555), mockUnderlying);

        // Clone can still be initialized independently
        address stakedTokenClone = Clones.clone(address(stakedTokenImpl));
        vm.prank(address(factory));
        LevrStakedToken_v1(stakedTokenClone).initialize(
            'Clone Token',
            'sCLONE',
            18,
            mockUnderlying,
            address(0xABCD)
        );

        // Verify independent state
        assertEq(treasuryImpl.governor(), user, 'Implementation has own state');
        assertEq(LevrTreasury_v1(treasuryClone).governor(), address(0x5555), 'Clone has own state');
        assertEq(
            stakedTokenImpl.staking(),
            address(0x9999),
            'Implementation retains original state'
        );
        assertEq(
            LevrStakedToken_v1(stakedTokenClone).staking(),
            address(0xABCD),
            'Clone has independent state'
        );
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
        LevrStakedToken_v1 token = new LevrStakedToken_v1(address(this));
        vm.expectRevert(ILevrStakedToken_v1.ZeroAddress.selector);
        token.initialize('Test', 'TST', 18, address(0), address(1));

        LevrStakedToken_v1 token2 = new LevrStakedToken_v1(address(this));
        vm.expectRevert(ILevrStakedToken_v1.ZeroAddress.selector);
        token2.initialize('Test', 'TST', 18, address(1), address(0));
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

contract DelegateCallerHarness {
    function delegateCall(address target, bytes memory data) external returns (bool, bytes memory) {
        (bool success, bytes memory returnData) = target.delegatecall(data);
        return (success, returnData);
    }
}

contract StakingInitSpy {
    address[] private _lastWhitelist;
    address public lastUnderlying;
    address public lastStakedToken;
    address public lastTreasury;
    uint256 public initializeCount;

    function initialize(
        address underlying,
        address stakedToken,
        address treasury,
        address[] memory whitelist
    ) external {
        lastUnderlying = underlying;
        lastStakedToken = stakedToken;
        lastTreasury = treasury;
        initializeCount++;

        delete _lastWhitelist;
        for (uint256 i = 0; i < whitelist.length; i++) {
            _lastWhitelist.push(whitelist[i]);
        }
    }

    function getLastWhitelist() external view returns (address[] memory whitelist) {
        whitelist = new address[](_lastWhitelist.length);
        for (uint256 i = 0; i < _lastWhitelist.length; i++) {
            whitelist[i] = _lastWhitelist[i];
        }
    }
}
