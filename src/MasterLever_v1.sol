// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMasterLever_v1} from "./interfaces/IMasterLever_v1.sol";
import {LeverERC20} from "./LeverERC20.sol";
import {IPoolManager} from "./interfaces/external/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";

/// @title MasterLever_v1 - Lever protocol's monolithic wrapper and staking contract
/// @notice Provides ERC20 wrapper tokens with 1:1 peg to underlying Clanker tokens,
/// staking rewards from protocol fees, and FCFS redemption solvency
contract MasterLever_v1 is IMasterLever_v1 {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @notice Pool configuration and accounting state
    struct LeverPool {
        address underlying;
        address wrapper;
        address poolManager;
        bytes poolKeyEncoded;
        PoolId poolId;
        uint256 underlyingEscrowed;
        uint256 stakedSupply;
        uint256 rewardIndexX64;
        uint256 lastHarvest;
        uint256 lastRateUpdate;
        uint256 ratePerSecondX64;
    }

    /// @notice User staking state for a pool
    struct UserStake {
        uint256 amount;
        uint256 indexX64;
        uint256 claimable;
    }

    /// @notice Next lever ID to assign
    uint256 private _nextLeverId = 1;

    /// @notice Mapping from leverId to pool configuration
    mapping(uint256 => LeverPool) public lever;

    /// @notice Mapping from underlying address to leverId
    mapping(address => uint256) public leverIdByUnderlying;

    /// @notice Mapping from (leverId, user) to staking state
    mapping(uint256 => mapping(address => UserStake)) public userStakes;

/// @notice Q64.64 fixed point representation of 1 (using 1e18 for testing to avoid large numbers)
uint256 private constant Q64 = 1e18;

    /// @notice Actions for IPoolManager.unlock callback
    enum Actions {
        HARVEST_FEES
    }

    /// @notice Data passed to unlock callback
    struct CallbackData {
        Actions action;
        uint256 leverId;
        address rewardToken;
        uint256 amount;
    }

    /// @notice Constructor - no initialization needed
    constructor() {}

    /// @inheritdoc IMasterLever_v1
    function registerPool(
        address underlying,
        address poolManager,
        bytes calldata poolKeyEncoded,
        string calldata name,
        string calldata symbol
    ) external returns (uint256 leverId, address wrapper) {
        if (underlying == address(0)) revert InvalidUnderlying();
        if (poolManager == address(0)) revert InvalidPoolManager();
        if (leverIdByUnderlying[underlying] != 0) revert PoolAlreadyRegistered();

        // Decode pool key to compute pool ID
        PoolKey memory poolKey = abi.decode(poolKeyEncoded, (PoolKey));
        PoolId poolId = poolKey.toId();

        // Deploy wrapper token
        wrapper = address(
            new LeverERC20(
                name,
                symbol,
                msg.sender, // deployer gets admin role
                address(this) // this contract gets minter role
            )
        );

        // Assign lever ID
        leverId = _nextLeverId++;
        leverIdByUnderlying[underlying] = leverId;

        // Store pool configuration
        lever[leverId] = LeverPool({
            underlying: underlying,
            wrapper: wrapper,
            poolManager: poolManager,
            poolKeyEncoded: poolKeyEncoded,
            poolId: poolId,
            underlyingEscrowed: 0,
            stakedSupply: 0,
            rewardIndexX64: 0,
            lastHarvest: block.timestamp,
            lastRateUpdate: block.timestamp,
            ratePerSecondX64: 0
        });

        emit PoolRegistered(leverId, underlying, wrapper, poolManager, poolKeyEncoded);
    }

    /// @inheritdoc IMasterLever_v1
    function mint(uint256 leverId, uint256 amountUnderlying, address to) external {
        LeverPool storage pool = lever[leverId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        // Transfer underlying tokens to this contract
        IERC20(pool.underlying).safeTransferFrom(msg.sender, address(this), amountUnderlying);

        // Mint wrapper tokens
        LeverERC20(pool.wrapper).mint(to, amountUnderlying);

        // Update escrow
        pool.underlyingEscrowed += amountUnderlying;

        emit Minted(leverId, to, amountUnderlying, amountUnderlying);
        emit SolvencyChanged(leverId, pool.underlyingEscrowed, IERC20(pool.wrapper).totalSupply());
    }

    /// @inheritdoc IMasterLever_v1
    function redeem(uint256 leverId, uint256 amountWrapper, address to) external {
        LeverPool storage pool = lever[leverId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();
        if (pool.underlyingEscrowed < amountWrapper) revert InsufficientEscrow();

        // Check user has enough wrapper tokens
        if (IERC20(pool.wrapper).balanceOf(msg.sender) < amountWrapper) revert InsufficientBalance();

        // Burn wrapper tokens
        LeverERC20(pool.wrapper).burnFrom(msg.sender, amountWrapper);

        // Transfer underlying tokens
        IERC20(pool.underlying).safeTransfer(to, amountWrapper);

        // Update escrow
        pool.underlyingEscrowed -= amountWrapper;

        emit Redeemed(leverId, msg.sender, amountWrapper, amountWrapper);
        emit SolvencyChanged(leverId, pool.underlyingEscrowed, IERC20(pool.wrapper).totalSupply());
    }

    /// @inheritdoc IMasterLever_v1
    function stake(uint256 leverId, uint256 amount, address to) external {
        LeverPool storage pool = lever[leverId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        UserStake storage userStake = userStakes[leverId][to];

        // Update user's claimable rewards before changing stake
        _updateUserRewards(leverId, to);

        // Transfer wrapper tokens from user
        IERC20(pool.wrapper).safeTransferFrom(msg.sender, address(this), amount);

        // Update user's stake
        userStake.amount += amount;
        pool.stakedSupply += amount;

        emit Staked(leverId, to, amount);
    }

    /// @inheritdoc IMasterLever_v1
    function unstake(uint256 leverId, uint256 amount, address to) external {
        LeverPool storage pool = lever[leverId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        UserStake storage userStake = userStakes[leverId][msg.sender];
        if (userStake.amount < amount) revert InsufficientStake();

        // Update user's claimable rewards before changing stake
        _updateUserRewards(leverId, msg.sender);

        // Update user's stake
        userStake.amount -= amount;
        pool.stakedSupply -= amount;

        // Transfer wrapper tokens to recipient
        IERC20(pool.wrapper).safeTransfer(to, amount);

        emit Unstaked(leverId, msg.sender, amount);
    }

    /// @inheritdoc IMasterLever_v1
    function claim(uint256 leverId, address to) external {
        LeverPool storage pool = lever[leverId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        UserStake storage userStake = userStakes[leverId][msg.sender];

        // Update user's claimable rewards
        _updateUserRewards(leverId, msg.sender);

        uint256 claimable = userStake.claimable;
        if (claimable == 0) revert NoRewardsToClaim();

        userStake.claimable = 0;

        // For simplicity, assume rewards are in the underlying token
        // In production, this would need to track which currency the rewards are in
        IERC20(pool.underlying).safeTransfer(to, claimable);

        emit Claimed(leverId, msg.sender, pool.underlying, claimable);
    }

    /// @inheritdoc IMasterLever_v1
    function harvest(uint256 leverId) external {
        LeverPool storage pool = lever[leverId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        // Decode pool key
        PoolKey memory poolKey = abi.decode(pool.poolKeyEncoded, (PoolKey));

        // For simplicity, harvest both currencies in the pool
        // In production, this would need to be more sophisticated
        Currency currency0 = poolKey.currency0;

        IPoolManager poolManager = IPoolManager(pool.poolManager);

        // Use unlock callback to harvest fees
        CallbackData memory callbackData = CallbackData({
            action: Actions.HARVEST_FEES,
            leverId: leverId,
            rewardToken: Currency.unwrap(currency0), // Assume currency0 is the reward token
            amount: poolManager.protocolFeesAccrued(currency0)
        });

        poolManager.unlock(abi.encode(callbackData));

        // Update rate calculation
        _updateRate(leverId);
    }

    /// @notice Callback function called by IPoolManager.unlock
    /// @param data Encoded callback data
    /// @return result Return data
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.action == Actions.HARVEST_FEES) {
            LeverPool storage pool = lever[callbackData.leverId];
            IPoolManager poolManager = IPoolManager(pool.poolManager);

            // Collect protocol fees
            PoolKey memory poolKey = abi.decode(pool.poolKeyEncoded, (PoolKey));

            // Collect fees for both currencies
            uint256 amount0Collected = poolManager.collectProtocolFees(
                address(this),
                poolKey.currency0,
                callbackData.amount
            );

            uint256 amount1Collected = poolManager.collectProtocolFees(
                address(this),
                poolKey.currency1,
                poolManager.protocolFeesAccrued(poolKey.currency1)
            );

            // For simplicity, assume currency0 is the reward token
            uint256 totalHarvested = amount0Collected;

            if (totalHarvested > 0 && pool.stakedSupply > 0) {
                // Update reward index
                uint256 newRewardsX64 = (totalHarvested * Q64) / pool.stakedSupply;
                pool.rewardIndexX64 += newRewardsX64;

                emit Harvested(callbackData.leverId, callbackData.rewardToken, totalHarvested);
            }

            pool.lastHarvest = block.timestamp;

            return abi.encode(amount0Collected, amount1Collected);
        }

        revert("Unknown action");
    }

    /// @inheritdoc IMasterLever_v1
    function getPegBps(uint256 leverId) external view returns (uint256 bps) {
        LeverPool storage pool = lever[leverId];
        if (pool.wrapper == address(0)) return 0;

        uint256 supply = IERC20(pool.wrapper).totalSupply();
        if (supply == 0) return 0;

        return (pool.underlyingEscrowed * 10000) / supply;
    }

    /// @inheritdoc IMasterLever_v1
    function getRatePerSecondX64(uint256 leverId) external view returns (uint256) {
        LeverPool storage pool = lever[leverId];
        return pool.ratePerSecondX64;
    }

    /// @inheritdoc IMasterLever_v1
    function getUserStake(uint256 leverId, address user) external view returns (uint256) {
        return userStakes[leverId][user].amount;
    }

    /// @inheritdoc IMasterLever_v1
    function getClaimableRewards(uint256 leverId, address user) external view returns (uint256) {
        UserStake storage userStake = userStakes[leverId][user];
        LeverPool storage pool = lever[leverId];

        uint256 currentIndex = pool.rewardIndexX64;
        uint256 userIndex = userStake.indexX64;
        uint256 userStakeAmount = userStake.amount;

        if (currentIndex > userIndex && userStakeAmount > 0) {
            uint256 accrued = ((currentIndex - userIndex) * userStakeAmount) / Q64;
            return userStake.claimable + accrued;
        }

        return userStake.claimable;
    }

    /// @inheritdoc IMasterLever_v1
    function getPoolInfo(uint256 leverId)
        external
        view
        returns (
            address underlying,
            address wrapper,
            address poolManager,
            uint256 underlyingEscrowed,
            uint256 stakedSupply
        )
    {
        LeverPool storage pool = lever[leverId];
        return (
            pool.underlying,
            pool.wrapper,
            pool.poolManager,
            pool.underlyingEscrowed,
            pool.stakedSupply
        );
    }

    /// @inheritdoc IMasterLever_v1
    function getLeverIdByUnderlying(address underlying) external view returns (uint256) {
        return leverIdByUnderlying[underlying];
    }

    /// @notice Update user's claimable rewards
    /// @param leverId Pool ID
    /// @param user User address
    function _updateUserRewards(uint256 leverId, address user) internal {
        UserStake storage userStake = userStakes[leverId][user];
        LeverPool storage pool = lever[leverId];

        uint256 currentIndex = pool.rewardIndexX64;
        uint256 userIndex = userStake.indexX64;
        uint256 userStakeAmount = userStake.amount;

        if (currentIndex > userIndex && userStakeAmount > 0) {
            uint256 accrued = ((currentIndex - userIndex) * userStakeAmount) / Q64;
            userStake.claimable += accrued;
        }

        userStake.indexX64 = currentIndex;
    }

    /// @notice Update the reward rate calculation
    /// @param leverId Pool ID
    function _updateRate(uint256 leverId) internal {
        LeverPool storage pool = lever[leverId];

        uint256 timeElapsed = block.timestamp - pool.lastRateUpdate;
        if (timeElapsed > 0 && pool.stakedSupply > 0) {
            // Simple rate calculation - in production this would be more sophisticated
            // For now, just track the last update time
            pool.lastRateUpdate = block.timestamp;
        }
    }

    /// @notice Test function to set reward index (for testing only)
    /// @param leverId Pool ID
    /// @param index New reward index
    function testSetRewardIndex(uint256 leverId, uint256 index) external {
        lever[leverId].rewardIndexX64 = index;
    }
}
