// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrDeployer_v1} from '../../src/interfaces/ILevrDeployer_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrDeployer Complete Branch Coverage Test
 * @notice Tests all branches in LevrDeployer_v1 to achieve 100% branch coverage
 * @dev Focuses on constructor validation branches
 */
contract LevrDeployer_CompleteBranchCoverage_Test is Test {
    LevrFactory_v1 factory;
    LevrDeployer_v1 deployer;
    MockERC20 underlying;

    address alice = address(0x1111);

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            minimumQuorumBps: 25
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), new address[](0));
        underlying = new MockERC20('Underlying', 'UND');
    }

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR VALIDATION BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: constructor reverts when factory is zero address
    /// @dev Verifies require(factory_ != address(0)) branch
    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILevrDeployer_v1.ZeroAddress.selector));
        new LevrDeployer_v1(address(0));
    }

    /// @notice Test: constructor succeeds with valid factory address
    /// @dev Verifies the success path
    function test_constructor_validFactory_succeeds() public {
        deployer = new LevrDeployer_v1(address(factory));
        assertEq(address(deployer.authorizedFactory()), address(factory), 'Factory should be set');
    }

    /// @notice Test: deployProject reverts when called by unauthorized address
    /// @dev Verifies onlyAuthorized modifier branch (address(this) != authorizedFactory)
    function test_deployProject_unauthorizedCaller_reverts() public {
        deployer = new LevrDeployer_v1(address(factory));

        // Try to call deployProject from unauthorized address
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILevrDeployer_v1.UnauthorizedFactory.selector));
        deployer.deployProject(
            address(underlying),
            address(0x1111), // treasury
            address(0x2222), // staking
            address(factory),
            address(0x3333), // forwarder
            new address[](0) // initialWhitelistedTokens
        );
    }
}

