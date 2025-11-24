// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {Test} from 'forge-std/Test.sol';

import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrDeployer_v1_Handler} from './handlers/LevrDeployer_v1_Handler.sol';

contract LevrDeployer_v1_InvariantTest is StdInvariant, Test {
    LevrDeployer_v1_Handler internal _handler;
    LevrDeployer_v1 internal _deployer;

    function setUp() public {
        _handler = new LevrDeployer_v1_Handler();
        _deployer = _handler.deployer();

        targetContract(address(_handler));
    }

    /// @notice Authorized factory and implementation addresses must remain immutable and non-zero
    function invariant_authorizedFactoryAndImplementations() public view {
        assertEq(_deployer.authorizedFactory(), address(_handler), 'Authorized factory mismatch');
        assertTrue(_deployer.treasuryImplementation() != address(0), 'Treasury impl zero');
        assertTrue(_deployer.stakingImplementation() != address(0), 'Staking impl zero');
        assertTrue(_deployer.governorImplementation() != address(0), 'Governor impl zero');
        assertTrue(
            _deployer.stakedTokenImplementation() != address(0),
            'Staked token impl zero'
        );
    }

    /// @notice Prepared clones must always inherit the handler factory address
    function invariant_preparedClonesHaveCorrectFactory() public view {
        uint256 treasuryLen = _handler.allTreasuryClonesLength();
        for (uint256 i = 0; i < treasuryLen; i++) {
            address treasuryClone = _handler.treasuryCloneAt(i);
            assertEq(
                LevrTreasury_v1(treasuryClone).factory(),
                address(_handler),
                'Treasury clone factory mismatch'
            );
        }

        uint256 stakingLen = _handler.allStakingClonesLength();
        for (uint256 i = 0; i < stakingLen; i++) {
            address stakingClone = _handler.stakingCloneAt(i);
            assertEq(
                LevrStaking_v1(stakingClone).factory(),
                address(_handler),
                'Staking clone factory mismatch'
            );
        }
    }

    /// @notice Deployed projects must have internally consistent references
    function invariant_deployedProjectsConsistent() public view {
        uint256 projectsLen = _handler.deployedProjectsLength();
        for (uint256 i = 0; i < projectsLen; i++) {
            ILevrFactory_v1.Project memory project = _handler.deployedProjectAt(i);
            assertTrue(project.treasury != address(0), 'Project treasury zero');
            assertTrue(project.staking != address(0), 'Project staking zero');
            assertTrue(project.stakedToken != address(0), 'Project stakedToken zero');
            assertTrue(project.governor != address(0), 'Project governor zero');

            LevrStaking_v1 staking = LevrStaking_v1(project.staking);
            LevrTreasury_v1 treasury = LevrTreasury_v1(project.treasury);
            LevrGovernor_v1 governor = LevrGovernor_v1(project.governor);
            LevrStakedToken_v1 stakedToken = LevrStakedToken_v1(project.stakedToken);

            assertEq(staking.treasury(), project.treasury, 'Staking treasury mismatch');
            assertEq(staking.stakedToken(), project.stakedToken, 'Staked token mismatch');
            assertEq(treasury.governor(), project.governor, 'Treasury governor mismatch');
            assertEq(governor.treasury(), project.treasury, 'Governor treasury mismatch');
            assertEq(governor.staking(), project.staking, 'Governor staking mismatch');
            assertEq(stakedToken.staking(), project.staking, 'Receipt token staking mismatch');
            assertEq(stakedToken.underlying(), staking.underlying(), 'Underlying mismatch');
        }
    }
}
