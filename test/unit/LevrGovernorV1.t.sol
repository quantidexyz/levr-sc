// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {LevrFactory_v1} from "../../src/LevrFactory_v1.sol";
import {LevrGovernor_v1} from "../../src/LevrGovernor_v1.sol";
import {ILevrFactory_v1} from "../../src/interfaces/ILevrFactory_v1.sol";
import {ILevrGovernor_v1} from "../../src/interfaces/ILevrGovernor_v1.sol";
import {LevrStaking_v1} from "../../src/LevrStaking_v1.sol";
import {LevrStakedToken_v1} from "../../src/LevrStakedToken_v1.sol";
import {LevrTreasury_v1} from "../../src/LevrTreasury_v1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LevrGovernorV1_UnitTest is Test {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    address internal user = address(0xA11CE);
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20("Token", "TKN");

        ILevrFactory_v1.TierConfig[]
            memory ttiers = new ILevrFactory_v1.TierConfig[](1);
        ttiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
        ILevrFactory_v1.TierConfig[]
            memory btiers = new ILevrFactory_v1.TierConfig[](1);
        btiers[0] = ILevrFactory_v1.TierConfig({value: 5_000 ether});
        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1
            .FactoryConfig({
                protocolFeeBps: 0,
                submissionDeadlineSeconds: 3 days,
                maxSubmissionPerType: 0,
                streamWindowSeconds: 3 days,
                transferTiers: ttiers,
                stakingBoostTiers: btiers,
                minWTokenToSubmit: 100 ether,
                protocolTreasury: protocolTreasury
            });
        factory = new LevrFactory_v1(cfg, address(this));
        (address govAddr, ) = factory.register(
            address(underlying),
            ILevrFactory_v1.RegisterParams({
                treasury: address(0),
                extraConfig: bytes("")
            })
        );
        (address t, , address st, address s) = factory.getProjectContracts(
            address(underlying)
        );
        governor = LevrGovernor_v1(govAddr);
        treasury = LevrTreasury_v1(payable(t));
        staking = LevrStaking_v1(st);
        sToken = LevrStakedToken_v1(s);

        // fund user and stake to reach min balance
        underlying.mint(user, 1_000 ether);
        vm.startPrank(user);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(200 ether);
        vm.stopPrank();

        // fund treasury for transfer proposals
        underlying.mint(address(treasury), 10_000 ether);
    }

    function test_propose_and_execute_transfer() public {
        vm.startPrank(user);
        uint256 pid = governor.proposeTransfer(
            address(0xB0B),
            500 ether,
            "ops",
            0
        );
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertEq(
            uint8(p.proposalType),
            uint8(ILevrGovernor_v1.ProposalType.Transfer)
        );
        vm.stopPrank();

        governor.execute(pid);
    }

    function test_proposeBoost_respectsTier_limit_and_deadline() public {
        vm.startPrank(user);
        uint256 pid = governor.proposeBoost(4_000 ether, 0);
        vm.stopPrank();

        // move time forward but before deadline
        vm.warp(block.timestamp + 1 days);
        governor.execute(pid);

        // After deadline should revert
        vm.startPrank(user);
        uint256 pid2 = governor.proposeBoost(4_000 ether, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 4 days);
        vm.expectRevert(ILevrGovernor_v1.DeadlinePassed.selector);
        governor.execute(pid2);
    }
}
