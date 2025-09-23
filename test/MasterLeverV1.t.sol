// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MasterLever_v1} from "../src/MasterLever_v1.sol";
import {LeverERC20} from "../src/LeverERC20.sol";
import {IMasterLever_v1} from "../src/interfaces/IMasterLever_v1.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";

contract MockHooks is IHooks {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
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

contract MasterLeverV1Test is Test {
    MasterLever_v1 masterLever;
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
        masterLever = new MasterLever_v1();
        underlyingToken = new MockERC20("Test Token", "TEST");
        poolManager = new MockPoolManager();
        mockHooks = new MockHooks();

        // Set masterLever address in mock
        poolManager.setMasterLever(address(masterLever));

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
        underlyingToken.approve(address(masterLever), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        underlyingToken.approve(address(masterLever), type(uint256).max);
        vm.stopPrank();
    }

    function testRegisterPool() public {
        vm.startPrank(deployer);

        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );

        assertEq(leverId, 1);
        assertTrue(wrapper != address(0));

        // Check pool info
        (
            address underlying,
            address wrapperAddr,
            address poolMgr,
            uint256 escrowed,
            uint256 staked
        ) = masterLever.getPoolInfo(leverId);

        assertEq(underlying, address(underlyingToken));
        assertEq(wrapperAddr, wrapper);
        assertEq(poolMgr, address(poolManager));
        assertEq(escrowed, 0);
        assertEq(staked, 0);

        // Check leverId lookup
        assertEq(masterLever.getLeverIdByUnderlying(address(underlyingToken)), leverId);

        vm.stopPrank();
    }

    function testMintAndRedeem() public {
        // Register pool first
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        // Mint wrapper tokens
        vm.startPrank(user1);
        uint256 mintAmount = 100 ether;
        masterLever.mint(leverId, mintAmount, user1);

        // Check balances
        assertEq(underlyingToken.balanceOf(user1), 900 ether);
        assertEq(underlyingToken.balanceOf(address(masterLever)), mintAmount);
        assertEq(LeverERC20(wrapper).balanceOf(user1), mintAmount);

        // Check peg ratio
        assertEq(masterLever.getPegBps(leverId), 10000); // 100% peg

        // Redeem wrapper tokens
        masterLever.redeem(leverId, mintAmount, user1);

        // Check balances after redemption
        assertEq(underlyingToken.balanceOf(user1), 1000 ether);
        assertEq(underlyingToken.balanceOf(address(masterLever)), 0);
        assertEq(LeverERC20(wrapper).balanceOf(user1), 0);

        vm.stopPrank();
    }

    function testInsufficientEscrow() public {
        // Register pool first
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        // Mint some tokens
        vm.startPrank(user1);
        masterLever.mint(leverId, 50 ether, user1);

        // Try to redeem more than escrowed - should revert
        vm.expectRevert(IMasterLever_v1.InsufficientEscrow.selector);
        masterLever.redeem(leverId, 100 ether, user1);

        vm.stopPrank();
    }

    function testStaking() public {
        // Register pool and mint tokens
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLever.mint(leverId, 100 ether, user1);

        // Approve wrapper for staking
        LeverERC20(wrapper).approve(address(masterLever), type(uint256).max);

        // Stake tokens
        uint256 stakeAmount = 50 ether;
        masterLever.stake(leverId, stakeAmount, user1);

        // Check stake balance
        assertEq(masterLever.getUserStake(leverId, user1), stakeAmount);
        assertEq(LeverERC20(wrapper).balanceOf(user1), 50 ether); // Remaining after staking
        assertEq(LeverERC20(wrapper).balanceOf(address(masterLever)), stakeAmount);

        // Check pool staked supply
        (, , , , uint256 stakedSupply) = masterLever.getPoolInfo(leverId);
        assertEq(stakedSupply, stakeAmount);

        vm.stopPrank();
    }

    function testUnstaking() public {
        // Setup staking
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLever.mint(leverId, 100 ether, user1);
        LeverERC20(wrapper).approve(address(masterLever), type(uint256).max);

        uint256 stakeAmount = 50 ether;
        masterLever.stake(leverId, stakeAmount, user1);

        // Unstake
        masterLever.unstake(leverId, stakeAmount, user1);

        // Check balances
        assertEq(masterLever.getUserStake(leverId, user1), 0);
        assertEq(LeverERC20(wrapper).balanceOf(user1), 100 ether);
        assertEq(LeverERC20(wrapper).balanceOf(address(masterLever)), 0);

        vm.stopPrank();
    }

    function testHarvest() public {
        // Register pool
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        // Setup staking
        vm.startPrank(user1);
        masterLever.mint(leverId, 100 ether, user1);
        LeverERC20(wrapper).approve(address(masterLever), type(uint256).max);
        masterLever.stake(leverId, 50 ether, user1);
        vm.stopPrank();

        // Add some protocol fees to mock
        poolManager.setProtocolFeesAccrued(Currency.wrap(address(underlyingToken)), 10 ether);

        // Harvest fees
        masterLever.harvest(leverId);

        // Check that fees were harvested (mock tracks this)
        assertTrue(poolManager.harvestCalled());

        vm.stopPrank();
    }

    function testClaimRewards() public {
        // Register pool and setup staking
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLever.mint(leverId, 2 ether, user1);
        LeverERC20(wrapper).approve(address(masterLever), type(uint256).max);
        masterLever.stake(leverId, 1 ether, user1);
        vm.stopPrank();

        // Simulate harvest by setting the reward index directly
        masterLever.testSetRewardIndex(leverId, 1e18);

        // Mint the reward tokens to masterLever
        underlyingToken.mint(address(masterLever), 1 ether);

    // Check claimable rewards
    uint256 claimable = masterLever.getClaimableRewards(leverId, user1);
    assertTrue(claimable > 0, "Should have claimable rewards");

    // Claim rewards
    uint256 balanceBefore = underlyingToken.balanceOf(user1);
    vm.startPrank(user1);
    masterLever.claim(leverId, user1);
    vm.stopPrank();
    uint256 balanceAfter = underlyingToken.balanceOf(user1);

    assertTrue(balanceAfter > balanceBefore, "Balance should increase after claiming");
    assertEq(masterLever.getClaimableRewards(leverId, user1), 0, "Claimable should be zero after claiming");
    }

    function testPegRatio() public {
        // Register pool
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        // Initially 0% peg (no supply)
        assertEq(masterLever.getPegBps(leverId), 0);

        // Mint tokens
        vm.startPrank(user1);
        masterLever.mint(leverId, 100 ether, user1);
        assertEq(masterLever.getPegBps(leverId), 10000); // 100% peg

        // Simulate over-minting by deployer (deployer needs to grant themselves MINTER_ROLE first)
        vm.startPrank(deployer);
        LeverERC20(wrapper).grantRole(LeverERC20(wrapper).MINTER_ROLE(), deployer);
        LeverERC20(wrapper).mint(deployer, 50 ether);
        vm.stopPrank();

        // Peg should now be 100 * 10000 / 150 = 6667 bps (66.67%)
        assertEq(masterLever.getPegBps(leverId), 6666); // Allow for rounding

        vm.stopPrank();
    }

    function testPoolNotRegistered() public {
        vm.startPrank(user1);
        vm.expectRevert(IMasterLever_v1.PoolNotRegistered.selector);
        masterLever.mint(999, 100 ether, user1);
        vm.stopPrank();
    }

    function testInsufficientBalance() public {
        // Register pool
        vm.startPrank(deployer);
        (uint256 leverId, address wrapper) = masterLever.registerPool(
            address(underlyingToken),
            address(poolManager),
            poolKeyEncoded,
            "Wrapped Test",
            "wTEST"
        );
        vm.stopPrank();

        vm.startPrank(user1);
        masterLever.mint(leverId, 100 ether, user1);

        // Transfer some wrapper tokens to another user to reduce balance
        LeverERC20(wrapper).transfer(user2, 60 ether);

        // Now user1 has 40 balance but 100 escrowed, try to redeem 50
        // This should fail on balance check, not escrow
        vm.expectRevert(IMasterLever_v1.InsufficientBalance.selector);
        masterLever.redeem(leverId, 50 ether, user1);

        vm.stopPrank();
    }
}
