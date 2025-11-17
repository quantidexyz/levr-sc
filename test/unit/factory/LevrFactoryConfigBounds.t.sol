// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../../utils/LevrFactoryDeployHelper.sol';

contract LevrFactoryConfigBoundsTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    MockERC20 internal underlying;

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(address(this));
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this), createDefaultBounds());

        underlying = new MockERC20('Underlying', 'UND');
        factory.prepareForDeployment();
        factory.register(address(underlying));
        factory.verifyProject(address(underlying));
    }

    function test_updateProjectConfig_revertsWhenQuorumBelowMin() public {
        ILevrFactory_v1.ProjectConfig memory cfg = _baselineProjectConfig();
        ILevrFactory_v1.ConfigBounds memory bounds = factory.getConfigBounds();
        cfg.quorumBps = bounds.minQuorumBps - 1;

        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        factory.updateProjectConfig(address(underlying), cfg);
    }

    function test_updateProjectConfig_revertsWhenVotingWindowBelowMin() public {
        ILevrFactory_v1.ProjectConfig memory cfg = _baselineProjectConfig();
        ILevrFactory_v1.ConfigBounds memory bounds = factory.getConfigBounds();
        cfg.votingWindowSeconds = bounds.minVotingWindowSeconds - 1;

        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        factory.updateProjectConfig(address(underlying), cfg);
    }

    function test_factoryOwnerCanRaiseBounds_grandfatherExistingConfigsUntilNextUpdate() public {
        ILevrFactory_v1.ProjectConfig memory cfg = _baselineProjectConfig();
        cfg.quorumBps = cfg.quorumBps + 100; // ensure > min
        factory.updateProjectConfig(address(underlying), cfg);

        ILevrFactory_v1.ConfigBounds memory newBounds = factory.getConfigBounds();
        newBounds.minQuorumBps = cfg.quorumBps + 500;
        newBounds.minVotingWindowSeconds = newBounds.minVotingWindowSeconds + 1 days;
        newBounds.minStreamWindowSeconds = newBounds.minStreamWindowSeconds + 12 hours;

        factory.updateConfigBounds(newBounds);

        // Existing config remains unchanged even though it's now below the floor.
        assertLt(
            factory.quorumBps(address(underlying)),
            newBounds.minQuorumBps,
            'existing config is grandfathered'
        );

        // Attempting to update with the old (below-min) parameters now fails.
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        factory.updateProjectConfig(address(underlying), cfg);

        // Updating to the new minimum succeeds.
        cfg.quorumBps = newBounds.minQuorumBps;
        cfg.votingWindowSeconds = newBounds.minVotingWindowSeconds;
        cfg.streamWindowSeconds = newBounds.minStreamWindowSeconds;
        factory.updateProjectConfig(address(underlying), cfg);

        assertEq(
            factory.quorumBps(address(underlying)),
            newBounds.minQuorumBps,
            'respects new bounds'
        );
        assertEq(
            factory.votingWindowSeconds(address(underlying)),
            newBounds.minVotingWindowSeconds,
            'voting window respects bounds'
        );
    }

    function test_configBounds_canBeUpdatedButNotSetToZero() public {
        ILevrFactory_v1.ConfigBounds memory bounds = factory.getConfigBounds();
        bounds.minProposalWindowSeconds += 1 hours;
        bounds.minVotingWindowSeconds += 1 hours;
        factory.updateConfigBounds(bounds);

        bounds.minVotingWindowSeconds = 0;
        vm.expectRevert(ILevrFactory_v1.InvalidConfig.selector);
        factory.updateConfigBounds(bounds);
    }

    function _baselineProjectConfig()
        internal
        view
        returns (ILevrFactory_v1.ProjectConfig memory cfg)
    {
        cfg = ILevrFactory_v1.ProjectConfig({
            streamWindowSeconds: factory.streamWindowSeconds(address(0)),
            proposalWindowSeconds: factory.proposalWindowSeconds(address(0)),
            votingWindowSeconds: factory.votingWindowSeconds(address(0)),
            maxActiveProposals: factory.maxActiveProposals(address(0)),
            quorumBps: factory.quorumBps(address(0)),
            approvalBps: factory.approvalBps(address(0)),
            minSTokenBpsToSubmit: factory.minSTokenBpsToSubmit(address(0)),
            maxProposalAmountBps: factory.maxProposalAmountBps(address(0)),
            minimumQuorumBps: factory.minimumQuorumBps(address(0))
        });
    }
}
