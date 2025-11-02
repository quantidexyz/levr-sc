// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {ILevrTreasury_v1} from '../../src/interfaces/ILevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrFactoryV1_PrepareForDeploymentTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    address internal protocolTreasury = address(0xFEE);

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));
    }

    function test_prepareForDeployment_deploys_treasury_and_staking() public {
        // Step 1: Prepare infrastructure BEFORE deploying Clanker token
        (address treasury, address staking) = factory.prepareForDeployment();

        // Verify contracts are deployed
        assertTrue(treasury != address(0), 'Treasury should be deployed');
        assertTrue(staking != address(0), 'Staking should be deployed');

        // Step 2: Now you would deploy Clanker token with:
        // - treasury as airdrop recipient
        // - staking as LP fee recipient
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');

        // Step 3: Complete registration with the prepared contracts
        ILevrFactory_v1.Project memory project = factory.register(address(clankerToken));

        // Verify same addresses are used
        assertEq(project.treasury, treasury, 'Should use prepared treasury');
        assertEq(project.staking, staking, 'Should use prepared staking');
        assertTrue(project.governor != address(0), 'Governor should be deployed');
        assertTrue(project.stakedToken != address(0), 'StakedToken should be deployed');

        // Verify treasury is controlled by governor (not ownable anymore)
        assertEq(
            LevrTreasury_v1(payable(treasury)).governor(),
            project.governor,
            'Treasury controlled by governor'
        );
    }

    function test_prepareForDeployment_multiple_times_creates_different_addresses() public {
        // Call prepareForDeployment multiple times
        (address treasury1, address staking1) = factory.prepareForDeployment();

        // Warp time to ensure different timestamp
        vm.warp(block.timestamp + 1);

        (address treasury2, address staking2) = factory.prepareForDeployment();

        // Different deployments should get different addresses
        assertTrue(treasury1 != treasury2, 'Different treasuries for different preparations');
        assertTrue(staking1 != staking2, 'Different staking for different preparations');
    }

    function test_register_requires_preparation() public {
        // Prepare infrastructure first
        (address treasury, address staking) = factory.prepareForDeployment();

        // Create token
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');

        // Register with prepared contracts
        ILevrFactory_v1.Project memory project = factory.register(address(clankerToken));

        // Should use prepared contracts and deploy governor/stakedToken
        assertEq(project.treasury, treasury, 'Treasury should match prepared');
        assertEq(project.staking, staking, 'Staking should match prepared');
        assertTrue(project.governor != address(0), 'Governor should be deployed');
        assertTrue(project.stakedToken != address(0), 'StakedToken should be deployed');
    }

    function test_typical_workflow_with_preparation() public {
        // WORKFLOW DEMONSTRATION:
        // This shows the typical flow for deploying a Levr project with Clanker integration

        // Step 1: Prepare infrastructure FIRST (before Clanker token exists)
        (address treasury, address staking) = factory.prepareForDeployment();

        emit log_named_address('Treasury (use as Clanker airdrop recipient)', treasury);
        emit log_named_address('Staking (use as Clanker LP fee recipient)', staking);

        // Step 2: Deploy Clanker token (in real scenario, using Clanker SDK/contracts)
        // - Set `treasury` as airdrop recipient → treasury receives initial allocation
        // - Set `staking` as LP fee recipient → staking receives ongoing trading fees
        MockERC20 clankerToken = new MockERC20('Clanker Token', 'CLANK');

        emit log_named_address('Clanker Token deployed', address(clankerToken));

        // Step 3: Complete registration with prepared contracts
        vm.prank(address(this)); // tokenAdmin for MockERC20 is address(this)
        ILevrFactory_v1.Project memory project = factory.register(address(clankerToken));

        emit log_named_address('Governor deployed', project.governor);
        emit log_named_address('StakedToken deployed', project.stakedToken);

        // Verify the system is fully integrated
        assertEq(project.treasury, treasury, 'Treasury address matches');
        assertEq(project.staking, staking, 'Staking address matches');

        ILevrFactory_v1.Project memory proj = factory.getProjectContracts(address(clankerToken));

        assertEq(proj.treasury, treasury, 'Project treasury registered');
        assertEq(proj.governor, project.governor, 'Project governor registered');
        assertEq(proj.staking, staking, 'Project staking registered');
        assertEq(proj.stakedToken, project.stakedToken, 'Project stakedToken registered');
    }

    function test_getProjects_empty() public {
        // Call getProjects with no registered projects
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(0, 10);

        assertEq(total, 0, 'Total should be 0 when no projects registered');
        assertEq(projects.length, 0, 'Projects array should be empty');
    }

    function test_getProjects_single_project() public {
        // Register one project
        factory.prepareForDeployment();
        MockERC20 token1 = new MockERC20('Token1', 'TK1');
        ILevrFactory_v1.Project memory project1 = factory.register(address(token1));

        // Query all projects
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(0, 10);

        assertEq(total, 1, 'Total should be 1');
        assertEq(projects.length, 1, 'Should return 1 project');
        assertEq(projects[0].clankerToken, address(token1), 'Token address should match');
        assertEq(projects[0].project.treasury, project1.treasury, 'Treasury should match');
        assertEq(projects[0].project.governor, project1.governor, 'Governor should match');
        assertEq(projects[0].project.staking, project1.staking, 'Staking should match');
        assertEq(projects[0].project.stakedToken, project1.stakedToken, 'StakedToken should match');
    }

    function test_getProjects_multiple_projects() public {
        // Register 5 projects
        address[] memory tokens = new address[](5);
        ILevrFactory_v1.Project[] memory registeredProjects = new ILevrFactory_v1.Project[](5);

        for (uint256 i = 0; i < 5; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            tokens[i] = address(token);
            registeredProjects[i] = factory.register(address(token));
        }

        // Query all projects
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(0, 10);

        assertEq(total, 5, 'Total should be 5');
        assertEq(projects.length, 5, 'Should return all 5 projects');

        // Verify each project
        for (uint256 i = 0; i < 5; i++) {
            assertEq(projects[i].clankerToken, tokens[i], 'Token address should match');
            assertEq(
                projects[i].project.treasury,
                registeredProjects[i].treasury,
                'Treasury should match'
            );
        }
    }

    function test_getProjects_pagination() public {
        // Register 5 projects
        address[] memory tokens = new address[](5);

        for (uint256 i = 0; i < 5; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            tokens[i] = address(token);
            factory.register(address(token));
        }

        // Query first 2 projects
        (ILevrFactory_v1.ProjectInfo[] memory page1, uint256 total1) = factory.getProjects(0, 2);
        assertEq(total1, 5, 'Total should be 5');
        assertEq(page1.length, 2, 'First page should have 2 projects');
        assertEq(page1[0].clankerToken, tokens[0], 'First project should be token 0');
        assertEq(page1[1].clankerToken, tokens[1], 'Second project should be token 1');

        // Query next 2 projects
        (ILevrFactory_v1.ProjectInfo[] memory page2, uint256 total2) = factory.getProjects(2, 2);
        assertEq(total2, 5, 'Total should still be 5');
        assertEq(page2.length, 2, 'Second page should have 2 projects');
        assertEq(page2[0].clankerToken, tokens[2], 'Third project should be token 2');
        assertEq(page2[1].clankerToken, tokens[3], 'Fourth project should be token 3');

        // Query last project
        (ILevrFactory_v1.ProjectInfo[] memory page3, uint256 total3) = factory.getProjects(4, 2);
        assertEq(total3, 5, 'Total should still be 5');
        assertEq(page3.length, 1, 'Third page should have 1 project (last one)');
        assertEq(page3[0].clankerToken, tokens[4], 'Fifth project should be token 4');
    }

    function test_getProjects_offset_out_of_bounds() public {
        // Register 3 projects
        for (uint256 i = 0; i < 3; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            factory.register(address(token));
        }

        // Query with offset beyond total
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(10, 5);

        assertEq(total, 3, 'Total should be 3');
        assertEq(projects.length, 0, 'Should return empty array for out of bounds offset');
    }

    function test_getProjects_limit_exceeds_remaining() public {
        // Register 3 projects
        for (uint256 i = 0; i < 3; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            factory.register(address(token));
        }

        // Query with limit larger than remaining
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(1, 10);

        assertEq(total, 3, 'Total should be 3');
        assertEq(projects.length, 2, 'Should return only remaining 2 projects');
    }

    function test_getProjects_offset_at_exactly_total() public {
        // Register 3 projects
        for (uint256 i = 0; i < 3; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            factory.register(address(token));
        }

        // Query with offset exactly at total (edge case)
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(3, 5);

        assertEq(total, 3, 'Total should be 3');
        assertEq(projects.length, 0, 'Should return empty array when offset == total');
    }

    function test_getProjects_zero_limit() public {
        // Register 2 projects
        for (uint256 i = 0; i < 2; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            factory.register(address(token));
        }

        // Query with limit of 0 (should return empty array)
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(0, 0);

        assertEq(total, 2, 'Total should be 2');
        assertEq(projects.length, 0, 'Should return empty array with limit 0');
    }

    function test_getProjects_large_limit() public {
        // Register 3 projects
        address[] memory tokens = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            tokens[i] = address(token);
            factory.register(address(token));
        }

        // Query with very large limit (should return all projects)
        (ILevrFactory_v1.ProjectInfo[] memory projects, uint256 total) = factory.getProjects(
            0,
            type(uint256).max
        );

        assertEq(total, 3, 'Total should be 3');
        assertEq(projects.length, 3, 'Should return all 3 projects');

        // Verify all tokens are present
        for (uint256 i = 0; i < 3; i++) {
            assertEq(projects[i].clankerToken, tokens[i], 'Token should match');
        }
    }

    function test_getProjects_consistency_across_multiple_calls() public {
        // Register 5 projects
        address[] memory tokens = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            tokens[i] = address(token);
            factory.register(address(token));
        }

        // Make multiple calls and verify consistency
        (ILevrFactory_v1.ProjectInfo[] memory firstCall, uint256 total1) = factory.getProjects(
            0,
            5
        );
        (ILevrFactory_v1.ProjectInfo[] memory secondCall, uint256 total2) = factory.getProjects(
            0,
            5
        );

        assertEq(total1, total2, 'Total should be consistent');
        assertEq(firstCall.length, secondCall.length, 'Length should be consistent');

        for (uint256 i = 0; i < firstCall.length; i++) {
            assertEq(
                firstCall[i].clankerToken,
                secondCall[i].clankerToken,
                'Tokens should be consistent'
            );
            assertEq(
                firstCall[i].project.treasury,
                secondCall[i].project.treasury,
                'Treasury should be consistent'
            );
        }
    }

    function test_getProjects_order_matches_registration_order() public {
        // Register projects in specific order
        address[] memory tokens = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            factory.prepareForDeployment();
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i))
            );
            tokens[i] = address(token);
            factory.register(address(token));
        }

        // Query all projects
        (ILevrFactory_v1.ProjectInfo[] memory projects, ) = factory.getProjects(0, 10);

        // Verify order matches registration order
        for (uint256 i = 0; i < 3; i++) {
            assertEq(projects[i].clankerToken, tokens[i], 'Order should match registration order');
        }
    }

    // ============ Missing Edge Cases from USER_FLOWS.md Flow 1-2 ============

    function test_initialize_calledTwiceOnTreasury_reverts() public {
        // Prepare and register to get treasury address
        factory.prepareForDeployment();
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');
        ILevrFactory_v1.Project memory project = factory.register(address(clankerToken));

        LevrTreasury_v1 treasury = LevrTreasury_v1(payable(project.treasury));
        address governor = project.governor;

        // Try to initialize treasury again - should revert
        vm.expectRevert(ILevrTreasury_v1.AlreadyInitialized.selector);
        treasury.initialize(governor, address(clankerToken));
    }

    function test_initialize_calledTwiceOnStaking_reverts() public {
        // Prepare and register to get staking address
        factory.prepareForDeployment();
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');
        ILevrFactory_v1.Project memory project = factory.register(address(clankerToken));

        LevrStaking_v1 staking = LevrStaking_v1(project.staking);
        address[] memory emptyRewardTokens = new address[](0);

        // Try to initialize staking again - should revert
        vm.expectRevert(ILevrStaking_v1.AlreadyInitialized.selector);
        staking.initialize(
            address(clankerToken),
            project.stakedToken,
            project.treasury,
            address(factory),
            emptyRewardTokens
        );
    }

    function test_register_calledTwiceForSameToken_reverts() public {
        // Prepare and register first time
        factory.prepareForDeployment();
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');
        factory.register(address(clankerToken));

        // Try to register same token again - should revert
        factory.prepareForDeployment();
        vm.expectRevert('ALREADY_REGISTERED');
        factory.register(address(clankerToken));
    }

    function test_preparedContracts_usedForMultipleTokens_fails() public {
        // Prepare contracts once
        (address treasury, address staking) = factory.prepareForDeployment();

        // Register first token - this will delete prepared contracts
        MockERC20 token1 = new MockERC20('Token1', 'TK1');
        factory.register(address(token1));

        // Try to register second token with same prepared contracts
        // Since prepared contracts were deleted, register will fail during deploy
        MockERC20 token2 = new MockERC20('Token2', 'TK2');
        vm.expectRevert('DEPLOY_FAILED');
        factory.register(address(token2));
    }

    function test_preparedContracts_usedByDifferentCaller_reverts() public {
        // Setup: Prepare contracts as one caller
        address caller1 = address(0x1111);
        address caller2 = address(0x2222);

        // Caller1 prepares contracts (stored under caller1's address)
        vm.prank(caller1);
        factory.prepareForDeployment();

        // Create token where caller2 is the admin
        vm.prank(caller2);
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');

        // Caller2 tries to register - should fail because:
        // 1. Caller2 is token admin (can call register)
        // 2. But prepared contracts are stored under caller1's address
        // 3. Register looks up _preparedContracts[caller2] which is empty/zero
        // 4. Deploy will fail with zero addresses
        vm.prank(caller2);
        vm.expectRevert('DEPLOY_FAILED'); // Will fail because prepared contracts are for caller1, not caller2
        factory.register(address(clankerToken));
    }

    function test_deployer_withZeroAddresses_validatesAndReverts() public {
        // Create token
        MockERC20 clankerToken = new MockERC20('Test Token', 'TEST');

        // Try to register without preparing - prepared contracts will be zero addresses
        // This should fail during deployer initialization
        vm.expectRevert('DEPLOY_FAILED');
        factory.register(address(clankerToken));
    }
}
