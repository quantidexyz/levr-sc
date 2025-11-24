// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrGovernor_v1_Scenarios_Test is Test, LevrFactoryDeployHelper {
    struct Env {
        ERC20_Mock underlying;
        LevrFactory_v1 factory;
        LevrForwarder_v1 forwarder;
        LevrDeployer_v1 deployer;
        LevrGovernor_v1 governor;
        LevrStaking_v1 staking;
        LevrTreasury_v1 treasury;
        LevrStakedToken_v1 stakedToken;
        uint32 proposalWindow;
        uint32 votingWindow;
    }

    address internal constant PROTOCOL_TREASURY = address(0xBEEF);
    address internal _alice = makeAddr('alice');
    address internal _bob = makeAddr('bob');
    address internal _carol = makeAddr('carol');

    function _deployEnv(
        ILevrFactory_v1.FactoryConfig memory cfg
    ) internal returns (Env memory env) {
        env.underlying = new ERC20_Mock('Scenario Token', 'SCN');

        env.proposalWindow = cfg.proposalWindowSeconds;
        env.votingWindow = cfg.votingWindowSeconds;

        (env.factory, env.forwarder, env.deployer) = deployFactoryWithDefaultClanker(
            cfg,
            address(this)
        );
        registerTokenWithMockClanker(address(env.underlying));
        env.factory.prepareForDeployment();

        ILevrFactory_v1.Project memory project = env.factory.register(address(env.underlying));
        env.governor = LevrGovernor_v1(project.governor);
        env.staking = LevrStaking_v1(project.staking);
        env.treasury = LevrTreasury_v1(payable(project.treasury));
        env.stakedToken = LevrStakedToken_v1(project.stakedToken);
    }

    function _defaultEnv() internal returns (Env memory env) {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(PROTOCOL_TREASURY);
        env = _deployEnv(cfg);
    }

    function _fundTreasury(Env memory env, uint256 amount) internal {
        env.underlying.mint(address(env.treasury), amount);
    }

    function _fundAndStake(Env memory env, address user, uint256 amount) internal {
        env.underlying.mint(user, amount);
        vm.startPrank(user);
        env.underlying.approve(address(env.staking), amount);
        env.staking.stake(amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _advanceToVoting(Env memory env) internal {
        vm.warp(block.timestamp + env.proposalWindow + 1);
    }

    function _advanceToExecution(Env memory env) internal {
        vm.warp(block.timestamp + env.votingWindow + 1);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Scenarios

    function test_Scenario_MaxActiveProposals_StrictLimit() public {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(PROTOCOL_TREASURY);
        cfg.maxActiveProposals = 1;
        Env memory env = _deployEnv(cfg);

        _fundTreasury(env, 200_000 ether);
        _fundAndStake(env, _alice, 2_000 ether);
        _fundAndStake(env, _bob, 2_000 ether);

        vm.prank(_alice);
        env.governor.proposeBoost(address(env.underlying), 1_000 ether);

        vm.prank(_bob);
        vm.expectRevert(ILevrGovernor_v1.MaxProposalsReached.selector);
        env.governor.proposeBoost(address(env.underlying), 500 ether);
    }

    function test_Scenario_ManualCycleAfterFailedExecutions_AllowsRestart() public {
        Env memory env = _defaultEnv();
        RevertingToken revertToken = new RevertingToken();

        revertToken.mint(address(env.treasury), 200_000 ether);
        _fundAndStake(env, _alice, 2_000 ether);
        _fundAndStake(env, _bob, 2_000 ether);

        vm.prank(_alice);
        uint256 proposalId = env.governor.proposeTransfer(
            address(revertToken),
            _bob,
            1_000 ether,
            'fail'
        );

        _advanceToVoting(env);
        vm.prank(_alice);
        env.governor.vote(proposalId, true);
        vm.prank(_bob);
        env.governor.vote(proposalId, true);

        _advanceToExecution(env);
        env.governor.execute(proposalId);
        vm.warp(block.timestamp + env.governor.EXECUTION_ATTEMPT_DELAY() + 1);
        env.governor.execute(proposalId);
        vm.warp(block.timestamp + env.governor.EXECUTION_ATTEMPT_DELAY() + 1);
        env.governor.execute(proposalId);

        uint256 cycleBefore = env.governor.currentCycleId();
        env.governor.startNewCycle();
        assertEq(env.governor.currentCycleId(), cycleBefore + 1, 'manual advancement succeeded');
    }

    function test_Scenario_WinnerSelection_PrefersHigherApproval() public {
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(PROTOCOL_TREASURY);
        cfg.quorumBps = 1000;
        cfg.minimumQuorumBps = 5;
        Env memory env = _deployEnv(cfg);
        _fundTreasury(env, 200_000 ether);

        _fundAndStake(env, _alice, 3_000 ether);
        _fundAndStake(env, _bob, 3_000 ether);
        _fundAndStake(env, _carol, 3_000 ether);

        vm.prank(_alice);
        uint256 proposalA = env.governor.proposeBoost(address(env.underlying), 2_000 ether);

        vm.prank(_bob);
        uint256 proposalB = env.governor.proposeTransfer(
            address(env.underlying),
            _carol,
            1_000 ether,
            'alt'
        );

        _advanceToVoting(env);

        vm.prank(_alice);
        env.governor.vote(proposalA, true);
        vm.prank(_bob);
        env.governor.vote(proposalA, true);

        vm.prank(_alice);
        env.governor.vote(proposalB, true);
        vm.prank(_carol);
        env.governor.vote(proposalB, false);

        _advanceToExecution(env);

        uint256 winner = env.governor.getWinner(env.governor.currentCycleId());
        assertEq(winner, proposalA, 'proposal with higher approval ratio wins');
    }
}

contract RevertingToken is ERC20_Mock {
    constructor() ERC20_Mock('Reverting', 'REV') {}

    function transfer(address, uint256) public pure override returns (bool) {
        revert('Transfer failed');
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert('Transfer failed');
    }
}
