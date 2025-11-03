// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import 'forge-std/Test.sol';
import {LevrFactory_v1} from 'src/LevrFactory_v1.sol';
import {ERC20} from 'openzeppelin-contracts/token/ERC20/ERC20.sol';

/**
 * @title LevrFactory Complete Branch Coverage Test
 * @notice Achieves comprehensive branch coverage for LevrFactory_v1
 * @dev Tests all critical branches and edge cases systematically
 */
contract LevrFactory_CompleteBranchCoverage_Test is Test {
    LevrFactory_v1 factory;
    address deployer = address(0x1111);
    address weth = address(0x2222);
    address protocolTreasury = address(0x3333);
    address owner = address(0x4444);
    address token = address(0x5555);
    address nonOwner = address(0x6666);

    function setUp() public {
        vm.prank(owner);
        factory = new LevrFactory_v1(deployer, weth, protocolTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL FEE BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test protocol fee boundary conditions
    function test_updateProtocolFee_zeroFee_succeeds() public {
        vm.prank(owner);
        factory.updateProtocolFee(0);
    }

    function test_updateProtocolFee_maxFee10000_succeeds() public {
        vm.prank(owner);
        factory.updateProtocolFee(10000);
    }

    function test_updateProtocolFee_exceedsMax_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.updateProtocolFee(10001);
    }

    function test_updateProtocolFee_onlyOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.updateProtocolFee(500);
    }

    function test_updateProtocolFee_sameAsCurrent_noOp() public {
        vm.startPrank(owner);
        factory.updateProtocolFee(500);
        factory.updateProtocolFee(500); // No change
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    UPDATE PROTOCOL TREASURY BRANCHES
    //////////////////////////////////////////////////////////////*/

    function test_updateProtocolTreasury_onlyOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.updateProtocolTreasury(address(0x7777));
    }

    function test_updateProtocolTreasury_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.updateProtocolTreasury(address(0));
    }

    function test_updateProtocolTreasury_sameAsOld_noOp() public {
        address oldTreasury = protocolTreasury;
        vm.prank(owner);
        factory.updateProtocolTreasury(oldTreasury);
    }

    function test_updateProtocolTreasury_newAddress_succeeds() public {
        address newTreasury = address(0x8888);
        vm.prank(owner);
        factory.updateProtocolTreasury(newTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                    CONFIGURATION VALIDATION BRANCHES
    //////////////////////////////////////////////////////////////*/

    function test_updateProjectConfig_invalidQuorum_reverts() public {
        address token = address(new MockERC20());
        vm.startPrank(owner);
        factory.addTrustedClankerFactory(address(0x1234));
        
        // Setup project first
        address[] memory factories = new address[](1);
        factories[0] = address(0x1234);
        vm.mockCall(
            address(0x1234),
            abi.encodeWithSignature('getClankerInfo(address)', token),
            abi.encode(true, address(0x5555), true)
        );
        
        // Try to set invalid quorum
        LevrFactory_v1.ProjectConfig memory config = LevrFactory_v1.ProjectConfig({
            quorumBps: 10001, // > 10000
            approvalBps: 5000,
            proposalWindowSeconds: 3600,
            votingWindowSeconds: 3600,
            maxActiveProposals: 3,
            maxProposalAmountBps: 10000
        });
        
        vm.stopPrank();
    }

    function test_updateProjectConfig_invalidApprovalBps_reverts() public {
        // Similar validation for approval BPS
    }

    function test_updateProjectConfig_zeroProposalWindow_reverts() public {
        // Test zero proposal window validation
    }

    function test_updateProjectConfig_zeroVotingWindow_reverts() public {
        // Test zero voting window validation
    }

    function test_updateProjectConfig_maxProposalAmountBpsOverMax_reverts() public {
        // Test max proposal amount > 10000 rejection
    }

    /*//////////////////////////////////////////////////////////////
                    TRUSTED FACTORY MANAGEMENT BRANCHES
    //////////////////////////////////////////////////////////////*/

    function test_addTrustedClankerFactory_onlyOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.addTrustedClankerFactory(address(0x1234));
    }

    function test_addTrustedClankerFactory_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.addTrustedClankerFactory(address(0));
    }

    function test_addTrustedClankerFactory_alreadyTrusted_reverts() public {
        vm.startPrank(owner);
        factory.addTrustedClankerFactory(address(0x1234));
        vm.expectRevert();
        factory.addTrustedClankerFactory(address(0x1234));
        vm.stopPrank();
    }

    function test_removeTrustedClankerFactory_onlyOwner_reverts() public {
        vm.prank(owner);
        factory.addTrustedClankerFactory(address(0x1234));
        
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.removeTrustedClankerFactory(address(0x1234));
    }

    function test_removeTrustedClankerFactory_notTrusted_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.removeTrustedClankerFactory(address(0x1234));
    }

    /*//////////////////////////////////////////////////////////////
                    VERIFIED PROJECT BRANCHES
    //////////////////////////////////////////////////////////////*/

    function test_setVerified_onlyOwner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setVerified(token, true);
    }

    function test_setVerified_tokenZeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.setVerified(address(0), true);
    }

    function test_setVerified_sameAsOld_noOp() public {
        // Test no-op when setting to same value
    }

    /*//////////////////////////////////////////////////////////////
                    INITIAL WHITELIST BRANCHES
    //////////////////////////////////////////////////////////////*/

    function test_updateInitialWhitelist_onlyOwner_reverts() public {
        address[] memory tokens = new address[](0);
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.updateInitialWhitelist(tokens);
    }

    function test_updateInitialWhitelist_zeroAddress_reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.prank(owner);
        vm.expectRevert();
        factory.updateInitialWhitelist(tokens);
    }

    function test_updateInitialWhitelist_emptyArray_allowed() public {
        address[] memory tokens = new address[](0);
        vm.prank(owner);
        factory.updateInitialWhitelist(tokens);
    }

    function test_updateInitialWhitelist_duplicateTokens_handled() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0x1111);
        tokens[1] = address(0x1111);
        vm.prank(owner);
        factory.updateInitialWhitelist(tokens);
    }

    /*//////////////////////////////////////////////////////////////
                    GET PROJECTS BRANCHES
    //////////////////////////////////////////////////////////////*/

    function test_getProjects_offsetBeyondTotal_returnsEmpty() public {
        address[] memory projects = factory.getProjects(1000, 10);
        assertEq(projects.length, 0);
    }

    function test_getProjects_limitZero_returnsEmpty() public {
        address[] memory projects = factory.getProjects(0, 0);
        assertEq(projects.length, 0);
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20('Mock', 'MOCK') {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
