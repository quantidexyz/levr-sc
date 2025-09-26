// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseForkTest} from "../utils/BaseForkTest.sol";
import {ClankerDeployer} from "../utils/ClankerDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ClankerDeployerTest is BaseForkTest {
    ClankerDeployer internal deployer;
    address internal clankerFactory;

    function setUp() public override {
        super.setUp();
        deployer = new ClankerDeployer();
        clankerFactory = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
    }

    function test_deployTokenStaticFee() public {
        // Deploy a token with static fee configuration
        address token = deployer.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: "Test Clanker Token",
            symbol: "TCK",
            clankerFeeBps: 100, // 1%
            pairedFeeBps: 100 // 1%
        });

        // Verify the token was deployed
        assertTrue(token != address(0), "Token should be deployed");

        // Verify it implements ERC20
        // Note: In Clanker deployments, initial tokens go to the locker for liquidity
        // The admin gets rewards through the rewardRecipients mechanism
        uint256 totalSupply = IERC20(token).totalSupply();
        assertTrue(totalSupply > 0, "Token should have total supply");

        // Verify metadata
        string memory name = IERC20Metadata(token).name();
        string memory symbol = IERC20Metadata(token).symbol();
        uint8 decimals = IERC20Metadata(token).decimals();

        assertEq(name, "Test Clanker Token", "Name should match");
        assertEq(symbol, "TCK", "Symbol should match");
        assertEq(decimals, 18, "Decimals should be 18");

        emit log_named_address("Deployed token", token);
        emit log_named_uint("Total supply", totalSupply);
    }

    function test_deployTokenDifferentFees() public {
        // Test with different fee configurations
        address token1 = deployer.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: "Token Low Fee",
            symbol: "TLF",
            clankerFeeBps: 50, // 0.5%
            pairedFeeBps: 100 // 1%
        });

        address token2 = deployer.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: address(this),
            name: "Token High Fee",
            symbol: "THF",
            clankerFeeBps: 500, // 5%
            pairedFeeBps: 300 // 3%
        });

        assertTrue(token1 != address(0), "Token1 should be deployed");
        assertTrue(token2 != address(0), "Token2 should be deployed");
        assertTrue(token1 != token2, "Tokens should be different");

        emit log_named_address("Token1", token1);
        emit log_named_address("Token2", token2);
    }

    function test_deployWithDifferentAdmin() public {
        address differentAdmin = address(0x123);

        address token = deployer.deployFactoryStaticFull({
            clankerFactory: clankerFactory,
            tokenAdmin: differentAdmin,
            name: "Admin Test Token",
            symbol: "ATT",
            clankerFeeBps: 100,
            pairedFeeBps: 100
        });

        assertTrue(token != address(0), "Token should be deployed");

        // Check that tokens exist (they go to the locker, not directly to admin)
        uint256 totalSupply = IERC20(token).totalSupply();
        assertTrue(totalSupply > 0, "Token should have total supply");

        // The admin is configured as rewardRecipient, so they would get rewards
        // but initial tokens are locked in liquidity

        emit log_named_address("Token", token);
        emit log_named_uint("Total supply", totalSupply);
    }
}
