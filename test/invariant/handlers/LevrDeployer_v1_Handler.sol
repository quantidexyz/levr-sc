// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from 'forge-std/Base.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';

import {ILevrFactory_v1} from '../../../src/interfaces/ILevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../../src/LevrDeployer_v1.sol';
import {LevrForwarder_v1} from '../../../src/LevrForwarder_v1.sol';
import {LevrTreasury_v1} from '../../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {ERC20_Mock} from '../../mocks/ERC20_Mock.sol';

contract LevrDeployer_v1_Handler is CommonBase, StdUtils {
    struct Prepared {
        address treasury;
        address staking;
    }

    LevrForwarder_v1 public immutable forwarder;
    LevrTreasury_v1 public immutable treasuryImpl;
    LevrStaking_v1 public immutable stakingImpl;
    LevrGovernor_v1 public immutable governorImpl;
    LevrStakedToken_v1 public immutable stakedTokenImpl;
    LevrDeployer_v1 public immutable deployerLogic;

    Prepared[] internal _pendingPrepared;
    address[] internal _allTreasuryClones;
    address[] internal _allStakingClones;
    ILevrFactory_v1.Project[] internal _deployedProjects;

    constructor() {
        forwarder = new LevrForwarder_v1('LevrForwarder_DeployerInvariant');
        treasuryImpl = new LevrTreasury_v1(address(this), address(forwarder));
        stakingImpl = new LevrStaking_v1(address(this), address(forwarder));
        governorImpl = new LevrGovernor_v1(address(this), address(forwarder));
        stakedTokenImpl = new LevrStakedToken_v1(address(this));

        deployerLogic = new LevrDeployer_v1(
            address(this),
            address(treasuryImpl),
            address(stakingImpl),
            address(governorImpl),
            address(stakedTokenImpl)
        );
    }

    /// @notice Call prepareContracts via the authorized factory (handler)
    function prepareContracts() external {
        (bool success, bytes memory data) = address(deployerLogic).delegatecall(
            abi.encodeWithSelector(LevrDeployer_v1.prepareContracts.selector)
        );
        if (!success) return;
        (address treasury, address staking) = abi.decode(data, (address, address));
        _pendingPrepared.push(Prepared(treasury, staking));
        _allTreasuryClones.push(treasury);
        _allStakingClones.push(staking);
    }

    /// @notice Deploy a project using the oldest prepared contracts
    function deployProject(uint256 whitelistLenSeed) external {
        if (_pendingPrepared.length == 0) return;

        Prepared memory prepared = _pendingPrepared[_pendingPrepared.length - 1];
        _pendingPrepared.pop();

        ERC20_Mock clanker = new ERC20_Mock('Clanker', 'CLK');

        uint256 whitelistLen = bound(whitelistLenSeed, 0, 3);
        address[] memory whitelist = new address[](whitelistLen);
        for (uint256 i = 0; i < whitelistLen; i++) {
            whitelist[i] = address(new ERC20_Mock('Reward', 'RWD'));
        }

        (bool success, bytes memory data) = address(deployerLogic).delegatecall(
            abi.encodeWithSelector(
                LevrDeployer_v1.deployProject.selector,
                address(clanker),
                prepared.treasury,
                prepared.staking,
                whitelist
            )
        );
        if (!success) return;

        ILevrFactory_v1.Project memory project = abi.decode(data, (ILevrFactory_v1.Project));

        _deployedProjects.push(project);
    }

    function allTreasuryClonesLength() external view returns (uint256) {
        return _allTreasuryClones.length;
    }

    function treasuryCloneAt(uint256 index) external view returns (address) {
        return _allTreasuryClones[index];
    }

    function allStakingClonesLength() external view returns (uint256) {
        return _allStakingClones.length;
    }

    function stakingCloneAt(uint256 index) external view returns (address) {
        return _allStakingClones[index];
    }

    function deployedProjectsLength() external view returns (uint256) {
        return _deployedProjects.length;
    }

    function deployedProjectAt(
        uint256 index
    ) external view returns (ILevrFactory_v1.Project memory) {
        return _deployedProjects[index];
    }

    function deployer() external view returns (LevrDeployer_v1) {
        return deployerLogic;
    }
}
