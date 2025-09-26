// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {BaseForkTest} from "./utils/BaseForkTest.sol";

import {LevrFactory_v1} from "../src/LevrFactory_v1.sol";
import {ILevrFactory_v1} from "../src/interfaces/ILevrFactory_v1.sol";
import {ILevrGovernor_v1} from "../src/interfaces/ILevrGovernor_v1.sol";

contract LevrFactoryV1_ForkTest is BaseForkTest {
    LevrFactory_v1 internal factory;

    address internal protocolTreasury = makeAddr("protocolTreasury");

    // Example token to act as a Clanker token on fork; can be replaced via env
    address internal clankerToken;

    function setUp() public override {
        super.setUp();
        clankerToken = vm.envOr("CLANKER_TOKEN", address(0));
        if (clankerToken == address(0)) {
            // Fallback to a locally deployed mock ERC20 if not provided
            // This keeps tests runnable without env, but real fork tests should set CLANKER_TOKEN
            clankerToken = address(new MockERC20Fork("ClankerMock", "CLK", 18));
        }

        ILevrFactory_v1.TierConfig[]
            memory transferTiers = new ILevrFactory_v1.TierConfig[](3);
        transferTiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
        transferTiers[1] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
        transferTiers[2] = ILevrFactory_v1.TierConfig({value: 100_000 ether});

        ILevrFactory_v1.TierConfig[]
            memory boostTiers = new ILevrFactory_v1.TierConfig[](3);
        boostTiers[0] = ILevrFactory_v1.TierConfig({value: 1_000 ether});
        boostTiers[1] = ILevrFactory_v1.TierConfig({value: 10_000 ether});
        boostTiers[2] = ILevrFactory_v1.TierConfig({value: 100_000 ether});

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1
            .FactoryConfig({
                protocolFeeBps: 0,
                submissionDeadlineSeconds: 7 days,
                maxSubmissionPerType: 0,
                streamWindowSeconds: 3 days,
                transferTiers: transferTiers,
                stakingBoostTiers: boostTiers,
                minWTokenToSubmit: 0,
                protocolTreasury: protocolTreasury
            });

        factory = new LevrFactory_v1(cfg, address(this));
    }

    function test_registerProject_deploysContracts_andWiresStorage() public {
        (address governor, address stakedToken) = factory.register(
            clankerToken,
            ILevrFactory_v1.RegisterParams({
                treasury: address(0),
                extraConfig: bytes("")
            })
        );

        (
            address treasury,
            address gotGovernor,
            address staking,
            address gotStaked
        ) = factory.getProjectContracts(clankerToken);
        assertEq(governor, gotGovernor, "governor mismatch");
        assertEq(stakedToken, gotStaked, "staked token mismatch");
        assertTrue(
            treasury != address(0) && staking != address(0),
            "zero addresses"
        );

        // Governor deadline config propagated
        ILevrGovernor_v1 gov = ILevrGovernor_v1(governor);
        uint256 pid = gov.proposeBoost(1, 0);
        ILevrGovernor_v1.Proposal memory p = gov.getProposal(pid);
        assertGt(p.deadline, block.timestamp, "deadline not set");
    }
}

// Minimal mock ERC20 to enable local runs without env-provided CLANKER_TOKEN
contract MockERC20Fork {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
        balanceOf[msg.sender] = type(uint128).max;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(
        address f,
        address t,
        uint256 a
    ) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allow");
        allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}
