// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockClankerFactory} from '../mocks/MockClankerFactory.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrFactory_v1_Test is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal _factory;
    LevrForwarder_v1 internal _forwarder;
    LevrDeployer_v1 internal _deployer;
    MockERC20 internal _clanker;

    address internal _protocolTreasury = address(0xDEAD);
    address internal _nonOwner = makeAddr('nonOwner');
    address internal _trustedFactory = makeAddr('trustedFactory');

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(_protocolTreasury);
        (_factory, _forwarder, _deployer) = deployFactoryWithDefaultClanker(cfg, address(this));
        _clanker = new MockERC20('Clanker', 'CLNK');
        registerTokenWithMockClanker(address(_clanker));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Helper Functions

    function _prepare() internal {
        vm.prank(address(this));
        _factory.prepareForDeployment();
    }

    function _register() internal returns (ILevrFactory_v1.Project memory project) {
        _prepare();
        project = _factory.register(address(_clanker));
    }

    function _defaultConfig() internal view returns (ILevrFactory_v1.FactoryConfig memory cfg) {
        cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: _factory.protocolFeeBps(),
            streamWindowSeconds: _factory.streamWindowSeconds(address(0)),
            protocolTreasury: _factory.protocolTreasury(),
            proposalWindowSeconds: _factory.proposalWindowSeconds(address(0)),
            votingWindowSeconds: _factory.votingWindowSeconds(address(0)),
            maxActiveProposals: _factory.maxActiveProposals(address(0)),
            quorumBps: _factory.quorumBps(address(0)),
            approvalBps: _factory.approvalBps(address(0)),
            minSTokenBpsToSubmit: _factory.minSTokenBpsToSubmit(address(0)),
            maxProposalAmountBps: _factory.maxProposalAmountBps(address(0)),
            minimumQuorumBps: _factory.minimumQuorumBps(address(0))
        });
    }

    function _setPermissiveMode(bool enabled) internal {
        if (mockClankerFactory != address(0)) {
            MockClankerFactory(mockClankerFactory).setPermissiveMode(enabled);
        }
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Initialization

    /* Test: constructor */
    function test_Constructor_SetsOwnerAndConfig() public view {
        assertEq(_factory.owner(), address(this));
        assertEq(_factory.protocolTreasury(), _protocolTreasury);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Modifiers

    /* Test: onlyOwner (addTrustedClankerFactory) */
    function test_AddTrustedFactory_RevertIf_NotOwner() public {
        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _nonOwner)
        );
        _factory.addTrustedClankerFactory(_trustedFactory);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test External Functions

    // ========================================================================
    // External - Clanker Factory Registry

    /* Test: addTrustedClankerFactory */
    function test_AddTrustedFactory_Success() public {
        _factory.addTrustedClankerFactory(_trustedFactory);
        assertTrue(_factory.isTrustedClankerFactory(_trustedFactory));

        vm.expectRevert(ILevrFactory_v1.AlreadyTrusted.selector);
        _factory.addTrustedClankerFactory(_trustedFactory);
    }

    /* Test: removeTrustedClankerFactory */
    function test_RemoveTrustedFactory_Success() public {
        _factory.addTrustedClankerFactory(_trustedFactory);
        _factory.removeTrustedClankerFactory(_trustedFactory);
        assertFalse(_factory.isTrustedClankerFactory(_trustedFactory));

        vm.expectRevert(ILevrFactory_v1.NotTrusted.selector);
        _factory.removeTrustedClankerFactory(_trustedFactory);
    }

    // ========================================================================
    // External - Deployment & Registration

    /* Test: register */
    function test_Register_SuccessDeploysProject() public {
        ILevrFactory_v1.Project memory project = _register();
        assertTrue(project.staking != address(0));
        assertEq(_factory.getProject(address(_clanker)).staking, project.staking);

        (ILevrFactory_v1.ProjectInfo[] memory infos, uint256 total) = _factory.getProjects(0, 10);
        assertEq(total, 1);
        assertEq(infos[0].clankerToken, address(_clanker));
    }

    function test_Register_RevertIf_NotAdmin() public {
        _prepare();
        vm.prank(_nonOwner);
        vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
        _factory.register(address(_clanker));
    }

    function test_Register_RevertIf_TokenNotTrusted() public {
        MockERC20 rogueToken = new MockERC20('Rogue', 'ROG');
        _setPermissiveMode(false);

        _prepare();
        vm.expectRevert(ILevrFactory_v1.TokenNotTrusted.selector);
        _factory.register(address(rogueToken));
    }

    function test_Register_RevertIf_SkipsPrepare() public {
        vm.expectRevert(ILevrFactory_v1.DeployFailed.selector);
        _factory.register(address(_clanker));
    }

    // ========================================================================
    // External - Configuration

    /* Test: updateConfig */
    function test_UpdateConfig_SetsNewDefaults() public {
        ILevrFactory_v1.FactoryConfig memory cfg = _defaultConfig();
        cfg.protocolFeeBps = 100;
        cfg.streamWindowSeconds = 5 days;
        cfg.proposalWindowSeconds = 1 days;
        cfg.votingWindowSeconds = 2 days;
        cfg.maxActiveProposals = 5;
        cfg.quorumBps = 3000;
        cfg.approvalBps = 5500;
        cfg.minSTokenBpsToSubmit = 200;
        cfg.maxProposalAmountBps = 1000;
        cfg.minimumQuorumBps = 50;
        cfg.protocolTreasury = address(0xFEED);

        _factory.updateConfig(cfg);

        assertEq(_factory.protocolFeeBps(), 100);
        assertEq(_factory.streamWindowSeconds(address(0)), 5 days);
        assertEq(_factory.proposalWindowSeconds(address(0)), 1 days);
        assertEq(_factory.protocolTreasury(), address(0xFEED));
    }

    function test_UpdateConfig_RevertIf_Invalid() public {
        ILevrFactory_v1.FactoryConfig memory cfg = _defaultConfig();
        cfg.maxActiveProposals = 0;
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        _factory.updateConfig(cfg);
    }

    /* Test: updateInitialWhitelist */
    function test_UpdateInitialWhitelist_RevertIf_NotOwner() public {
        address[] memory list = new address[](1);
        list[0] = address(_clanker);

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _nonOwner)
        );
        _factory.updateInitialWhitelist(list);
    }

    function test_UpdateInitialWhitelist_RevertIf_ZeroAddress() public {
        address[] memory list = new address[](1);
        list[0] = address(0);

        vm.expectRevert(ILevrFactory_v1.ZeroAddress.selector);
        _factory.updateInitialWhitelist(list);
    }

    function test_UpdateInitialWhitelist_SetsWhitelistAndProjectsInherit() public {
        MockERC20 stable = new MockERC20('Stable', 'STBL');
        address[] memory list = new address[](1);
        list[0] = address(stable);

        _factory.updateInitialWhitelist(list);

        address[] memory stored = _factory.getInitialWhitelist();
        assertEq(stored.length, 1);
        assertEq(stored[0], address(stable));

        ILevrFactory_v1.Project memory project = _register();
        assertTrue(
            ILevrStaking_v1(project.staking).isTokenWhitelisted(address(stable)),
            'Project should inherit whitelist'
        );
    }

    /* Test: updateConfigBounds */
    function test_UpdateConfigBounds_RevertIf_Zero() public {
        ILevrFactory_v1.ConfigBounds memory bounds = ILevrFactory_v1.ConfigBounds({
            minStreamWindowSeconds: 0,
            minProposalWindowSeconds: 1,
            minVotingWindowSeconds: 1,
            minQuorumBps: 1,
            minApprovalBps: 1,
            minMinSTokenBpsToSubmit: 1,
            minMinimumQuorumBps: 1
        });

        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        _factory.updateConfigBounds(bounds);
    }

    // ========================================================================
    // External - Project Admin

    /* Test: verifyProject */
    function test_VerifyAndUpdateProjectConfig() public {
        _register();

        _factory.verifyProject(address(_clanker));
        {
            ILevrFactory_v1.Project memory project = _factory.getProject(address(_clanker));
            assertTrue(project.verified);
        }

        ILevrFactory_v1.ProjectConfig memory projectCfg = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: 1 days,
            proposalWindowSeconds: 2 hours,
            votingWindowSeconds: 1 days,
            maxActiveProposals: 3,
            quorumBps: 2500,
            approvalBps: 5500,
            minSTokenBpsToSubmit: 150,
            maxProposalAmountBps: 750,
            minimumQuorumBps: 40
        });

        vm.prank(address(this));
        _factory.updateProjectConfig(address(_clanker), projectCfg);

        assertEq(_factory.streamWindowSeconds(address(_clanker)), 1 days);
        assertEq(_factory.quorumBps(address(_clanker)), 2500);

        _factory.unverifyProject(address(_clanker));
        assertFalse(_factory.getProject(address(_clanker)).verified);
    }

    /* Test: updateInitialWhitelist */
    function test_UpdateInitialWhitelist_StoresTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0xAAA1);
        tokens[1] = address(0xAAA2);

        _factory.updateInitialWhitelist(tokens);

        address[] memory stored = _factory.getInitialWhitelist();
        assertEq(stored.length, 2);
        assertEq(stored[0], tokens[0]);

        tokens[1] = address(0);
        vm.expectRevert(ILevrFactory_v1.ZeroAddress.selector);
        _factory.updateInitialWhitelist(tokens);
    }
}
