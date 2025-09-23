// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MasterLevr_v1} from "../src/MasterLevr_v1.sol";
import {LevrERC20} from "../src/LevrERC20.sol";
import {IMasterLevr_v1} from "../src/interfaces/IMasterLevr_v1.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";

contract MockHooks is IHooks {
    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}

contract MasterLevrV1Test is Test {
    MasterLevr_v1 masterLevr;
    MockERC20 underlyingToken;
    MockPoolManager poolManager;
    MockHooks mockHooks;

    address user1 = address(0x1);
    address user2 = address(0x2);
    address deployer = address(0x3);

    // Mock pool key data
    bytes poolKeyEncoded;
    PoolKey poolKey;

    function setUp() public {
        // Deploy contracts
        masterLevr = new MasterLevr_v1();
        underlyingToken = new MockERC20("Test Token", "TEST");
        poolManager = new MockPoolManager();
        mockHooks = new MockHooks();

        // Set masterLevr address in mock
        poolManager.setMasterLevr(address(masterLevr));

        // Create a mock pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(underlyingToken)),
            currency1: Currency.wrap(address(0xBEEF)), // WETH mock
            fee: 3000,
            tickSpacing: 60,
            hooks: mockHooks
        });
        poolKeyEncoded = abi.encode(poolKey);

        // Setup user balances
        underlyingToken.mint(user1, 1000 ether);
        underlyingToken.mint(user2, 1000 ether);

        vm.startPrank(user1);
        underlyingToken.approve(address(masterLevr), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        underlyingToken.approve(address(masterLevr), type(uint256).max);
        vm.stopPrank();
    }

    function testRegisterPool() public {
        vm.startPrank(deployer);

        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );

        assertEq(leverId, 1);
        assertTrue(wrapper != address(0));

        // Check wrapper token name and symbol
        assertEq(LevrERC20(wrapper).name(), "Levr Test Token");
        assertEq(LevrERC20(wrapper).symbol(), "wTEST");

        // Check pool info
        (
            address underlying,
            address wrapperAddr,
            address poolMgr,
            uint256 escrowed,
            uint256 staked
        ) = masterLevr.getPoolInfo(leverId);

        assertEq(underlying, address(underlyingToken));
        assertEq(wrapperAddr, wrapper);
        assertEq(poolMgr, address(poolManager));
        assertEq(escrowed, 0);
        assertEq(staked, 0);

        // Check leverId lookup
        assertEq(
            masterLevr.getLeverIdByUnderlying(address(underlyingToken)),
            leverId
        );

        vm.stopPrank();
    }

    function testMintAndRedeem() public {
        // Register pool first
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        // Mint wrapper tokens
        vm.startPrank(user1);
        uint256 mintAmount = 100 ether;
        masterLevr.mint(leverId, mintAmount, user1);

        // Check balances
        assertEq(underlyingToken.balanceOf(user1), 900 ether);
        assertEq(underlyingToken.balanceOf(address(masterLevr)), mintAmount);
        assertEq(LevrERC20(wrapper).balanceOf(user1), mintAmount);

        // Check peg ratio
        assertEq(masterLevr.getPegBps(leverId), 10000); // 100% peg

        // Redeem wrapper tokens
        masterLevr.redeem(leverId, mintAmount, user1);

        // Check balances after redemption
        assertEq(underlyingToken.balanceOf(user1), 1000 ether);
        assertEq(underlyingToken.balanceOf(address(masterLevr)), 0);
        assertEq(LevrERC20(wrapper).balanceOf(user1), 0);

        vm.stopPrank();
    }

    function testInsufficientEscrow() public {
        // Register pool first
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        // Mint some tokens
        vm.startPrank(user1);
        masterLevr.mint(leverId, 50 ether, user1);

        // Try to redeem more than escrowed - should revert
        vm.expectRevert(IMasterLevr_v1.InsufficientEscrow.selector);
        masterLevr.redeem(leverId, 100 ether, user1);

        vm.stopPrank();
    }

    function testStaking() public {
        // Register pool and mint tokens
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLevr.mint(leverId, 100 ether, user1);

        // Approve wrapper for staking
        LevrERC20(wrapper).approve(address(masterLevr), type(uint256).max);

        // Stake tokens
        uint256 stakeAmount = 50 ether;
        masterLevr.stake(leverId, stakeAmount, user1);

        // Check stake balance
        assertEq(masterLevr.getUserStake(leverId, user1), stakeAmount);
        assertEq(LevrERC20(wrapper).balanceOf(user1), 50 ether); // Remaining after staking
        assertEq(
            LevrERC20(wrapper).balanceOf(address(masterLevr)),
            stakeAmount
        );

        // Check pool staked supply
        (, , , , uint256 stakedSupply) = masterLevr.getPoolInfo(leverId);
        assertEq(stakedSupply, stakeAmount);

        vm.stopPrank();
    }

    function testUnstaking() public {
        // Setup staking
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLevr.mint(leverId, 100 ether, user1);
        LevrERC20(wrapper).approve(address(masterLevr), type(uint256).max);

        uint256 stakeAmount = 50 ether;
        masterLevr.stake(leverId, stakeAmount, user1);

        // Unstake
        masterLevr.unstake(leverId, stakeAmount, user1);

        // Check balances
        assertEq(masterLevr.getUserStake(leverId, user1), 0);
        assertEq(LevrERC20(wrapper).balanceOf(user1), 100 ether);
        assertEq(LevrERC20(wrapper).balanceOf(address(masterLevr)), 0);

        vm.stopPrank();
    }

    function testHarvest() public {
        // Register pool
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        // Setup staking
        vm.startPrank(user1);
        masterLevr.mint(leverId, 100 ether, user1);
        LevrERC20(wrapper).approve(address(masterLevr), type(uint256).max);
        masterLevr.stake(leverId, 50 ether, user1);
        vm.stopPrank();

        // Add some protocol fees to mock
        poolManager.setProtocolFeesAccrued(
            Currency.wrap(address(underlyingToken)),
            10 ether
        );

        // Harvest fees
        masterLevr.harvest(leverId);

        // Check that fees were harvested (mock tracks this)
        assertTrue(poolManager.harvestCalled());

        vm.stopPrank();
    }

    function testClaimRewards() public {
        // Register pool and setup staking
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLevr.mint(leverId, 2 ether, user1);
        LevrERC20(wrapper).approve(address(masterLevr), type(uint256).max);
        masterLevr.stake(leverId, 1 ether, user1);
        vm.stopPrank();

        // Simulate harvest by setting the reward index directly
        masterLevr.testSetRewardIndex(leverId, 1e18);

        // Mint the reward tokens to masterLevr
        underlyingToken.mint(address(masterLevr), 1 ether);

        // Check claimable rewards
        uint256 claimable = masterLevr.getClaimableRewards(leverId, user1);
        assertTrue(claimable > 0, "Should have claimable rewards");

        // Claim rewards
        uint256 balanceBefore = underlyingToken.balanceOf(user1);
        vm.startPrank(user1);
        masterLevr.claim(leverId, user1);
        vm.stopPrank();
        uint256 balanceAfter = underlyingToken.balanceOf(user1);

        assertTrue(
            balanceAfter > balanceBefore,
            "Balance should increase after claiming"
        );
        assertEq(
            masterLevr.getClaimableRewards(leverId, user1),
            0,
            "Claimable should be zero after claiming"
        );
    }

    function testPegRatio() public {
        // Register pool
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        // Initially 0% peg (no supply)
        assertEq(masterLevr.getPegBps(leverId), 0);

        // Mint tokens
        vm.startPrank(user1);
        masterLevr.mint(leverId, 100 ether, user1);
        assertEq(masterLevr.getPegBps(leverId), 10000); // 100% peg

        // Simulate over-minting by deployer (deployer needs to grant themselves MINTER_ROLE first)
        vm.startPrank(deployer);
        LevrERC20(wrapper).grantRole(
            LevrERC20(wrapper).MINTER_ROLE(),
            deployer
        );
        LevrERC20(wrapper).mint(deployer, 50 ether);
        vm.stopPrank();

        // Peg should now be 100 * 10000 / 150 = 6667 bps (66.67%)
        assertEq(masterLevr.getPegBps(leverId), 6666); // Allow for rounding

        vm.stopPrank();
    }

    function testPoolNotRegistered() public {
        vm.startPrank(user1);
        vm.expectRevert(IMasterLevr_v1.PoolNotRegistered.selector);
        masterLevr.mint(999, 100 ether, user1);
        vm.stopPrank();
    }

    function testInsufficientBalance() public {
        // Register pool
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLevr.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLevr.mint(leverId, 100 ether, user1);

        // Transfer some wrapper tokens to another user to reduce balance
        LevrERC20(wrapper).transfer(user2, 60 ether);

        // Now user1 has 40 balance but 100 escrowed, try to redeem 50
        // This should fail on balance check, not escrow
        vm.expectRevert(IMasterLevr_v1.InsufficientBalance.selector);
        masterLevr.redeem(leverId, 50 ether, user1);

        vm.stopPrank();
    }
}
