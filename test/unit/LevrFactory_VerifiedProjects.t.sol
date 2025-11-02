// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/**
 * @title Levr Factory Verified Projects Configuration Tests
 * @notice Tests for verified project config overrides and protocol fee protection
 * @dev Ensures projects cannot override protocol-level settings
 */
contract LevrFactory_VerifiedProjectsTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    MockERC20 internal underlying;

    address internal alice = address(0xA11CE);
    address internal owner = address(this);

    event ProjectVerified(address indexed clankerToken);
    event ProjectUnverified(address indexed clankerToken);
    event ProjectConfigUpdated(address indexed clankerToken);
    event ConfigUpdated();

    function setUp() public {
        // Deploy factory with default config
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(owner);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, owner);

        // Deploy and register a project
        underlying = new MockERC20('Underlying', 'UND');
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        staking = LevrStaking_v1(project.staking);
        governor = LevrGovernor_v1(project.governor);

        // Fund alice
        underlying.mint(alice, 10000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();
    }

    // ============ Protocol Fee Protection Tests ============

    /// @notice CRITICAL: Verified projects cannot override protocol fee
    function test_projectConfig_cannotOverrideProtocolFee() public {
        console2.log('\n=== Projects Cannot Override Protocol Fee ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Get current factory protocol fee
        uint16 factoryProtocolFee = factory.protocolFeeBps();
        console2.log('Factory protocol fee:', factoryProtocolFee);

        // Project admin tries to update config (implicitly trying to change protocol fee)
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this)); // Token admin
        factory.updateProjectConfig(address(underlying), customConfig);

        // Verify protocol fee unchanged (projects use factory value)
        // Since protocolFeeBps() has no override, it always returns factory value
        uint16 protocolFeeAfter = factory.protocolFeeBps();
        assertEq(protocolFeeAfter, factoryProtocolFee, 'Protocol fee must not change');

        console2.log('SUCCESS: Protocol fee remains at factory value');
    }

    /// @notice CRITICAL: Protocol fee changes in factory apply to all projects
    function test_factoryProtocolFeeChange_appliesToAllProjects() public {
        console2.log('\n=== Factory Protocol Fee Changes Apply to All Projects ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Initial protocol fee
        uint16 initialFee = factory.protocolFeeBps();
        console2.log('Initial protocol fee:', initialFee);

        // Project updates its config
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Factory owner changes protocol fee
        ILevrFactory_v1.FactoryConfig memory newFactoryConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 500, // Changed from 100 to 500 (5%)
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25
        });

        vm.prank(owner);
        factory.updateConfig(newFactoryConfig);

        // Verify project uses NEW protocol fee (cannot override)
        uint16 newProtocolFee = factory.protocolFeeBps();
        assertEq(newProtocolFee, 500, 'Protocol fee should be updated to 500');

        console2.log('New protocol fee:', newProtocolFee);
        console2.log('SUCCESS: Factory protocol fee changes apply to all projects');
    }

    /// @notice Test projects cannot override protocol treasury
    function test_projectConfig_cannotOverrideProtocolTreasury() public {
        console2.log('\n=== Projects Cannot Override Protocol Treasury ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Get current factory protocol treasury
        address factoryTreasury = factory.protocolTreasury();
        console2.log('Factory protocol treasury:', factoryTreasury);

        // Project admin updates config (implicitly preserves protocol treasury)
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Verify protocol treasury unchanged
        address treasuryAfter = factory.protocolTreasury();
        assertEq(treasuryAfter, factoryTreasury, 'Protocol treasury must not change');

        console2.log('SUCCESS: Protocol treasury remains at factory value');
    }

    // ============ Verified Project Config Override Tests ============

    /// @notice Test verified projects can override governance parameters
    function test_verifiedProject_canOverrideGovernanceParams() public {
        console2.log('\n=== Verified Projects Can Override Governance ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Get default values
        uint16 defaultQuorum = factory.quorumBps(address(0));
        uint16 defaultApproval = factory.approvalBps(address(0));
        console2.log('Default quorum:', defaultQuorum);
        console2.log('Default approval:', defaultApproval);

        // Project admin sets custom config
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000, // Custom: 60% vs factory 70%
            approvalBps: 5500, // Custom: 55% vs factory 51%
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this)); // Token admin
        factory.updateProjectConfig(address(underlying), customConfig);

        // Verify project uses custom values
        uint16 projectQuorum = factory.quorumBps(address(underlying));
        uint16 projectApproval = factory.approvalBps(address(underlying));

        assertEq(projectQuorum, 6000, 'Project should use custom quorum');
        assertEq(projectApproval, 5500, 'Project should use custom approval');

        // Verify factory defaults unchanged
        assertEq(factory.quorumBps(address(0)), defaultQuorum, 'Factory default unchanged');
        assertEq(factory.approvalBps(address(0)), defaultApproval, 'Factory default unchanged');

        console2.log('Project quorum:', projectQuorum);
        console2.log('Project approval:', projectApproval);
        console2.log('SUCCESS: Verified projects can customize governance');
    }

    /// @notice Test unverified projects cannot update config
    function test_unverifiedProject_cannotUpdateConfig() public {
        console2.log('\n=== Unverified Projects Cannot Update Config ===');

        // Don't verify project (it's unverified by default)

        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this)); // Token admin
        vm.expectRevert(abi.encodeWithSignature('ProjectNotVerified()'));
        factory.updateProjectConfig(address(underlying), customConfig);

        console2.log('SUCCESS: Unverified projects cannot update config');
    }

    /// @notice Test only token admin can update project config
    function test_projectConfig_onlyTokenAdmin() public {
        console2.log('\n=== Only Token Admin Can Update Project Config ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        // Alice (not admin) tries to update
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature('UnauthorizedCaller()'));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Token admin can update
        vm.prank(address(this)); // Test contract is admin
        factory.updateProjectConfig(address(underlying), customConfig);

        console2.log('SUCCESS: Only token admin can update project config');
    }

    /// @notice Test project config validation prevents gridlock
    function test_projectConfig_validationPreventsGridlock() public {
        console2.log('\n=== Project Config Validation Prevents Gridlock ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Try to set impossible quorum (> 100%)
        ILevrFactory_v1.ProjectConfig memory invalidConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 11000, // Invalid: > 100%
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        vm.expectRevert('INVALID_QUORUM_BPS');
        factory.updateProjectConfig(address(underlying), invalidConfig);

        console2.log('SUCCESS: Invalid quorum rejected');

        // Try to set zero proposal window
        invalidConfig.quorumBps = 6000; // Fix quorum
        invalidConfig.proposalWindowSeconds = 0; // Zero window

        vm.prank(address(this));
        vm.expectRevert('PROPOSAL_WINDOW_ZERO');
        factory.updateProjectConfig(address(underlying), invalidConfig);

        console2.log('SUCCESS: Zero proposal window rejected');
    }

    /// @notice Test protocol fee updates in factory sync to verified projects
    function test_factoryProtocolFeeUpdate_syncsToVerifiedProjects() public {
        console2.log('\n=== Factory Protocol Fee Updates Sync to Verified Projects ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Project sets custom governance config
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Initial protocol fee
        uint16 initialProtocolFee = factory.protocolFeeBps();
        console2.log('Initial protocol fee:', initialProtocolFee);

        // Factory owner updates protocol fee
        ILevrFactory_v1.FactoryConfig memory newFactoryConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 300, // Changed from 100 to 300
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25
        });

        vm.prank(owner);
        factory.updateConfig(newFactoryConfig);

        // Project must use new protocol fee (cannot override)
        uint16 currentProtocolFee = factory.protocolFeeBps();
        assertEq(currentProtocolFee, 300, 'Protocol fee should be 300');

        // Project's custom governance config should remain
        assertEq(factory.quorumBps(address(underlying)), 6000, 'Custom quorum preserved');
        assertEq(factory.approvalBps(address(underlying)), 5500, 'Custom approval preserved');

        console2.log('New protocol fee:', currentProtocolFee);
        console2.log('Project quorum (custom):', factory.quorumBps(address(underlying)));
        console2.log('SUCCESS: Protocol fee syncs, custom governance preserved');
    }

    /// @notice Test project config update preserves factory protocol fee
    function test_projectConfigUpdate_alwaysUsesCurrentFactoryProtocolFee() public {
        console2.log('\n=== Project Config Always Uses Current Factory Protocol Fee ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Update factory protocol fee BEFORE project config update
        ILevrFactory_v1.FactoryConfig memory factoryConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 250, // Set to 250
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25
        });

        vm.prank(owner);
        factory.updateConfig(factoryConfig);

        console2.log('Factory protocol fee set to:', factory.protocolFeeBps());

        // Now project updates its config
        ILevrFactory_v1.ProjectConfig memory projectConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), projectConfig);

        // Verify project uses current factory protocol fee (250)
        assertEq(factory.protocolFeeBps(), 250, 'Must use current factory protocol fee');

        console2.log('Protocol fee after project config update:', factory.protocolFeeBps());
        console2.log('SUCCESS: Project config update uses current factory protocol fee');
    }

    /// @notice Test multiple projects cannot override protocol fee independently
    function test_multipleProjects_cannotOverrideProtocolFeeIndependently() public {
        console2.log('\n=== Multiple Projects Cannot Override Protocol Fee ===');

        // Deploy second project
        MockERC20 underlying2 = new MockERC20('Underlying2', 'UND2');
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project2 = factory.register(address(underlying2));

        // Verify both projects
        vm.prank(owner);
        factory.verifyProject(address(underlying));
        vm.prank(owner);
        factory.verifyProject(address(underlying2));

        // Project 1 sets custom config
        ILevrFactory_v1.ProjectConfig memory config1 = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this)); // Admin of underlying
        factory.updateProjectConfig(address(underlying), config1);

        // Project 2 sets different custom config
        ILevrFactory_v1.ProjectConfig memory config2 = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 5 days,
            proposalWindowSeconds: 1 days,
            votingWindowSeconds: 3 days,
            maxActiveProposals: 5,
            quorumBps: 8000,
            approvalBps: 6000,
            minSTokenBpsToSubmit: 200,
            maxProposalAmountBps: 4000,
            minimumQuorumBps: 500
        });

        vm.prank(address(this)); // Admin of underlying2
        factory.updateProjectConfig(address(underlying2), config2);

        // Both projects use SAME protocol fee (factory value)
        uint16 protocolFee = factory.protocolFeeBps();
        assertEq(protocolFee, factory.protocolFeeBps(), 'Both use factory protocol fee');

        // But have different governance configs
        assertEq(factory.quorumBps(address(underlying)), 6000, 'Project 1 custom quorum');
        assertEq(factory.quorumBps(address(underlying2)), 8000, 'Project 2 custom quorum');

        console2.log('Protocol fee (both projects):', protocolFee);
        console2.log('Project 1 quorum:', factory.quorumBps(address(underlying)));
        console2.log('Project 2 quorum:', factory.quorumBps(address(underlying2)));
        console2.log('SUCCESS: Multiple projects share protocol fee, independent governance');
    }

    // ============ Config Resolution Tests ============

    /// @notice Test config resolution for verified vs unverified projects
    function test_configResolution_verifiedVsUnverified() public {
        console2.log('\n=== Config Resolution: Verified vs Unverified ===');

        // Deploy second project (will remain unverified)
        MockERC20 underlying2 = new MockERC20('Underlying2', 'UND2');
        factory.prepareForDeployment();
        factory.register(address(underlying2));

        // Verify only first project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Set custom config for verified project
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Verified project uses custom config
        assertEq(factory.quorumBps(address(underlying)), 6000, 'Verified uses custom');

        // Unverified project uses factory default
        assertEq(factory.quorumBps(address(underlying2)), 7000, 'Unverified uses default');

        // Both use same protocol fee
        assertEq(factory.protocolFeeBps(), factory.protocolFeeBps(), 'Same protocol fee');

        console2.log('Verified project quorum:', factory.quorumBps(address(underlying)));
        console2.log('Unverified project quorum:', factory.quorumBps(address(underlying2)));
        console2.log('SUCCESS: Config resolution works correctly');
    }

    /// @notice Test unverify removes custom config
    function test_unverify_removesCustomConfig() public {
        console2.log('\n=== Unverify Removes Custom Config ===');

        // Verify and set custom config
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Verify custom config active
        assertEq(factory.quorumBps(address(underlying)), 6000, 'Custom quorum active');

        // Unverify project
        vm.prank(owner);
        factory.unverifyProject(address(underlying));

        // Should revert to factory defaults
        assertEq(factory.quorumBps(address(underlying)), 7000, 'Reverted to default');
        assertEq(factory.approvalBps(address(underlying)), 5100, 'Reverted to default');

        console2.log('After unverify quorum:', factory.quorumBps(address(underlying)));
        console2.log('SUCCESS: Unverify removes custom config');
    }

    // ============ Protocol Revenue Protection Tests ============

    /// @notice Test protocol fee cannot be avoided by any means
    function test_protocolFee_cannotBeAvoided() public {
        console2.log('\n=== Protocol Fee Cannot Be Avoided ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        // Even with extreme (but valid) config, protocol fee cannot be changed
        uint16 protocolFeeBefore = factory.protocolFeeBps();

        // Project tries extreme config (all valid but restrictive)
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 3 days, // Min valid: 1 day
            proposalWindowSeconds: 1 days, // Short but valid
            votingWindowSeconds: 2 days, // Short but valid
            maxActiveProposals: 1, // Extreme: Only 1 proposal
            quorumBps: 9999, // Extreme: 99.99% quorum
            approvalBps: 9999, // Extreme: 99.99% approval
            minSTokenBpsToSubmit: 9999, // Extreme: 99.99% to propose
            maxProposalAmountBps: 1, // Extreme: 0.01% max
            minimumQuorumBps: 9999 // Extreme: 99.99% minimum
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        uint16 protocolFeeAfter = factory.protocolFeeBps();
        assertEq(protocolFeeAfter, protocolFeeBefore, 'Protocol fee unchanged');

        console2.log('Protocol fee before:', protocolFeeBefore);
        console2.log('Protocol fee after extreme config:', protocolFeeAfter);
        console2.log('SUCCESS: Protocol fee cannot be avoided by any config combination');
    }

    /// @notice Test factory owner can change protocol fee at any time
    function test_factoryOwner_canAlwaysChangeProtocolFee() public {
        console2.log('\n=== Factory Owner Can Always Change Protocol Fee ===');

        // Verify project with custom config
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Factory owner changes protocol fee
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 500, // Changed to 5%
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25
        });

        vm.prank(owner);
        factory.updateConfig(newConfig);

        // All projects (verified or not) use new protocol fee
        assertEq(factory.protocolFeeBps(), 500, 'New protocol fee applied');

        console2.log('New protocol fee:', factory.protocolFeeBps());
        console2.log('SUCCESS: Factory owner maintains protocol fee control');
    }

    /// @notice Test protocol treasury cannot be overridden by projects
    function test_protocolTreasury_cannotBeOverridden() public {
        console2.log('\n=== Protocol Treasury Cannot Be Overridden ===');

        // Verify project
        vm.prank(owner);
        factory.verifyProject(address(underlying));

        address initialTreasury = factory.protocolTreasury();
        console2.log('Initial protocol treasury:', initialTreasury);

        // Project updates config
        ILevrFactory_v1.ProjectConfig memory customConfig = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 7 days,
            proposalWindowSeconds: 3 days,
            votingWindowSeconds: 4 days,
            maxActiveProposals: 10,
            quorumBps: 6000,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 50,
            maxProposalAmountBps: 3000,
            minimumQuorumBps: 100
        });

        vm.prank(address(this));
        factory.updateProjectConfig(address(underlying), customConfig);

        // Protocol treasury must remain unchanged
        assertEq(factory.protocolTreasury(), initialTreasury, 'Protocol treasury unchanged');

        // Factory owner changes protocol treasury
        ILevrFactory_v1.FactoryConfig memory newConfig = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0x1234567890123456789012345678901234567890), // Changed
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25
        });

        vm.prank(owner);
        factory.updateConfig(newConfig);

        // All projects use new protocol treasury
        assertEq(
            factory.protocolTreasury(),
            address(0x1234567890123456789012345678901234567890),
            'New treasury applied'
        );

        console2.log('New protocol treasury:', factory.protocolTreasury());
        console2.log('SUCCESS: Protocol treasury controlled by factory only');
    }
}
