// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMasterLevr_v1} from "./interfaces/IMasterLevr_v1.sol";
import {LevrERC20} from "./LevrERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "./interfaces/external/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";

/// @title MasterLevr_v1 - Levr protocol's monolithic wrapper and staking contract
/// @notice Provides ERC20 wrapper tokens with 1:1 peg to underlying Clanker tokens,
/// staking rewards from protocol fees, and FCFS redemption solvency
contract MasterLevr_v1 is IMasterLevr_v1 {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @notice Next levr ID to assign
    uint256 private _nextLevrId = 1;

    /// @notice Mapping from levrId to pool configuration
    mapping(uint256 => LevrPool) public levr;

    /// @notice Mapping from underlying address to levrId
    mapping(address => uint256) public levrIdByUnderlying;

    /// @notice Mapping from (levrId, user) to staking state
    mapping(uint256 => mapping(address => UserStake)) public userStakes;

    /// @notice Q64.64 fixed point representation of 1 (using 1e18 for testing to avoid large numbers)
    uint256 private constant Q64 = 1e18;

    /// @notice Constructor - no initialization needed
    constructor() {}

    /// @inheritdoc IMasterLevr_v1
    function registerPool(
        address underlying,
        address poolManager,
        bytes calldata poolKeyEncoded
    ) external returns (uint256 levrId, address wrapper) {
        if (underlying == address(0)) revert InvalidUnderlying();
        if (poolManager == address(0)) revert InvalidPoolManager();
        if (levrIdByUnderlying[underlying] != 0) revert PoolAlreadyRegistered();

        // Get underlying token metadata
        IERC20Metadata underlyingToken = IERC20Metadata(underlying);
        string memory underlyingName = underlyingToken.name();
        string memory underlyingSymbol = underlyingToken.symbol();

        // Generate wrapper token name and symbol
        string memory wrapperName = string.concat("Levr ", underlyingName);
        string memory wrapperSymbol = string.concat("w", underlyingSymbol);

        // Decode pool key to compute pool ID
        PoolKey memory poolKey = abi.decode(poolKeyEncoded, (PoolKey));
        PoolId poolId = poolKey.toId();

        // Deploy wrapper token
        wrapper = address(
            new LevrERC20(
                wrapperName,
                wrapperSymbol,
                msg.sender, // deployer gets admin role
                address(this) // this contract gets minter role
            )
        );

        // Assign levr ID
        levrId = _nextLevrId++;
        levrIdByUnderlying[underlying] = levrId;

        // Store pool configuration
        levr[levrId] = LevrPool({
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
            ratePerSecondX64: 0,
            rewardToken: address(0) // Will be set on first harvest
        });

        emit PoolRegistered(
            levrId,
            underlying,
            wrapper,
            poolManager,
            poolKeyEncoded
        );
    }

    /// @inheritdoc IMasterLevr_v1
    function mint(
        uint256 levrId,
        uint256 amountUnderlying,
        address to
    ) external {
        LevrPool storage pool = levr[levrId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        // Transfer underlying tokens to this contract
        IERC20(pool.underlying).safeTransferFrom(
            msg.sender,
            address(this),
            amountUnderlying
        );

        // Mint wrapper tokens
        LevrERC20(pool.wrapper).mint(to, amountUnderlying);

        // Update escrow
        pool.underlyingEscrowed += amountUnderlying;

        emit Minted(levrId, to, amountUnderlying, amountUnderlying);
        emit SolvencyChanged(
            levrId,
            pool.underlyingEscrowed,
            IERC20(pool.wrapper).totalSupply()
        );
    }

    /// @inheritdoc IMasterLevr_v1
    function redeem(
        uint256 levrId,
        uint256 amountWrapper,
        address to
    ) external {
        LevrPool storage pool = levr[levrId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();
        if (pool.underlyingEscrowed < amountWrapper)
            revert InsufficientEscrow();

        // Check user has enough wrapper tokens
        if (IERC20(pool.wrapper).balanceOf(msg.sender) < amountWrapper)
            revert InsufficientBalance();

        // Burn wrapper tokens
        LevrERC20(pool.wrapper).burnFrom(msg.sender, amountWrapper);

        // Transfer underlying tokens
        IERC20(pool.underlying).safeTransfer(to, amountWrapper);

        // Update escrow
        pool.underlyingEscrowed -= amountWrapper;

        emit Redeemed(levrId, msg.sender, amountWrapper, amountWrapper);
        emit SolvencyChanged(
            levrId,
            pool.underlyingEscrowed,
            IERC20(pool.wrapper).totalSupply()
        );
    }

    /// @inheritdoc IMasterLevr_v1
    function stake(uint256 levrId, uint256 amount, address to) external {
        LevrPool storage pool = levr[levrId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        UserStake storage userStake = userStakes[levrId][to];

        // Update user's claimable rewards before changing stake
        _updateUserRewards(levrId, to);

        // Transfer wrapper tokens from user
        IERC20(pool.wrapper).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Update user's stake
        userStake.amount += amount;
        pool.stakedSupply += amount;

        emit Staked(levrId, to, amount);
    }

    /// @inheritdoc IMasterLevr_v1
    function unstake(uint256 levrId, uint256 amount, address to) external {
        LevrPool storage pool = levr[levrId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        UserStake storage userStake = userStakes[levrId][msg.sender];
        if (userStake.amount < amount) revert InsufficientStake();

        // Update user's claimable rewards before changing stake
        _updateUserRewards(levrId, msg.sender);

        // Update user's stake
        userStake.amount -= amount;
        pool.stakedSupply -= amount;

        // Transfer wrapper tokens to recipient
        IERC20(pool.wrapper).safeTransfer(to, amount);

        emit Unstaked(levrId, msg.sender, amount);
    }

    /// @inheritdoc IMasterLevr_v1
    function claim(uint256 levrId, address to) external {
        LevrPool storage pool = levr[levrId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        UserStake storage userStake = userStakes[levrId][msg.sender];

        // Update user's claimable rewards
        _updateUserRewards(levrId, msg.sender);

        uint256 claimable = userStake.claimable;
        if (claimable == 0) revert NoRewardsToClaim();

        userStake.claimable = 0;

        // Transfer rewards in the correct currency
        if (pool.rewardToken == address(0)) revert NoRewardsToClaim();
        IERC20(pool.rewardToken).safeTransfer(to, claimable);

        emit Claimed(levrId, msg.sender, pool.rewardToken, claimable);
    }

    /// @inheritdoc IMasterLevr_v1
    function harvest(uint256 levrId) external {
        LevrPool storage pool = levr[levrId];
        if (pool.underlying == address(0)) revert PoolNotRegistered();

        IPoolManager poolManager = IPoolManager(pool.poolManager);

        // Verify we are the protocol fee controller before attempting harvest
        if (poolManager.protocolFeeController() != address(this)) {
            revert InvalidCaller();
        }

        // Use unlock callback to harvest fees
        CallbackData memory callbackData = CallbackData({
            action: Actions.HARVEST_FEES,
            levrId: levrId,
            rewardToken: address(0), // Will be determined in callback
            amount: 0 // Will be determined in callback
        });

        poolManager.unlock(abi.encode(callbackData));

        // Update rate calculation
        _updateRate(levrId);
    }

    /// @notice Callback function called by IPoolManager.unlock
    /// @param data Encoded callback data
    /// @return result Return data
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.action == Actions.HARVEST_FEES) {
            LevrPool storage pool = levr[callbackData.levrId];
            IPoolManager poolManager = IPoolManager(pool.poolManager);

            // Verify we are the protocol fee controller
            if (poolManager.protocolFeeController() != address(this)) {
                revert InvalidCaller();
            }

            // Decode pool key
            PoolKey memory poolKey = abi.decode(pool.poolKeyEncoded, (PoolKey));

            // Determine which currency to harvest rewards from
            // For Clanker pools, typically the non-ETH currency gets the fees
            Currency rewardCurrency;
            address rewardTokenAddress;

            if (Currency.unwrap(poolKey.currency0) == pool.underlying) {
                rewardCurrency = poolKey.currency0;
                rewardTokenAddress = Currency.unwrap(poolKey.currency0);
            } else if (Currency.unwrap(poolKey.currency1) == pool.underlying) {
                rewardCurrency = poolKey.currency1;
                rewardTokenAddress = Currency.unwrap(poolKey.currency1);
            } else {
                // Default to currency0 if neither matches underlying
                rewardCurrency = poolKey.currency0;
                rewardTokenAddress = Currency.unwrap(poolKey.currency0);
            }

            // Get available fees for the reward currency
            uint256 availableFees = poolManager.protocolFeesAccrued(
                rewardCurrency
            );
            if (availableFees == 0) {
                return abi.encode(0, 0);
            }

            // Collect protocol fees - this creates a positive delta that must be settled
            uint256 amountCollected = poolManager.collectProtocolFees(
                address(this),
                rewardCurrency,
                availableFees
            );

            // Since we collected fees, we have a positive delta for rewardCurrency
            // In v4, we need to either:
            // 1. Use these tokens in a swap (settling the delta)
            // 2. Account for them properly
            // For fee harvesting, we simply acknowledge we've collected them
            // The tokens are now at address(this) and can be used for rewards

            if (amountCollected > 0 && pool.stakedSupply > 0) {
                // Set reward token on first harvest
                if (pool.rewardToken == address(0)) {
                    pool.rewardToken = rewardTokenAddress;
                }

                // Update reward index
                uint256 newRewardsX64 = (amountCollected * Q64) /
                    pool.stakedSupply;
                pool.rewardIndexX64 += newRewardsX64;

                emit Harvested(
                    callbackData.levrId,
                    rewardTokenAddress,
                    amountCollected
                );
            }

            pool.lastHarvest = block.timestamp;

            // Return collected amounts for both currencies (0 for non-reward currency)
            return
                abi.encode(
                    rewardCurrency == poolKey.currency0 ? amountCollected : 0,
                    rewardCurrency == poolKey.currency1 ? amountCollected : 0
                );
        }

        revert("Unknown action");
    }

    /// @inheritdoc IMasterLevr_v1
    function getPegBps(uint256 levrId) external view returns (uint256 bps) {
        LevrPool storage pool = levr[levrId];
        if (pool.wrapper == address(0)) return 0;

        uint256 supply = IERC20(pool.wrapper).totalSupply();
        if (supply == 0) return 0;

        return (pool.underlyingEscrowed * 10000) / supply;
    }

    /// @inheritdoc IMasterLevr_v1
    function getRatePerSecondX64(
        uint256 levrId
    ) external view returns (uint256) {
        LevrPool storage pool = levr[levrId];
        return pool.ratePerSecondX64;
    }

    /// @inheritdoc IMasterLevr_v1
    function getUserStake(
        uint256 levrId,
        address user
    ) external view returns (uint256) {
        return userStakes[levrId][user].amount;
    }

    /// @inheritdoc IMasterLevr_v1
    function getClaimableRewards(
        uint256 levrId,
        address user
    ) external view returns (uint256) {
        UserStake storage userStake = userStakes[levrId][user];
        LevrPool storage pool = levr[levrId];

        uint256 currentIndex = pool.rewardIndexX64;
        uint256 userIndex = userStake.indexX64;
        uint256 userStakeAmount = userStake.amount;

        if (currentIndex > userIndex && userStakeAmount > 0) {
            uint256 accrued = ((currentIndex - userIndex) * userStakeAmount) /
                Q64;
            return userStake.claimable + accrued;
        }

        return userStake.claimable;
    }

    /// @inheritdoc IMasterLevr_v1
    function getPoolInfo(
        uint256 levrId
    )
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
        LevrPool storage pool = levr[levrId];
        return (
            pool.underlying,
            pool.wrapper,
            pool.poolManager,
            pool.underlyingEscrowed,
            pool.stakedSupply
        );
    }

    /// @inheritdoc IMasterLevr_v1
    function getPoolInfoWithRewardToken(
        uint256 levrId
    )
        external
        view
        returns (
            address underlying,
            address wrapper,
            address poolManager,
            uint256 underlyingEscrowed,
            uint256 stakedSupply,
            address rewardToken
        )
    {
        LevrPool storage pool = levr[levrId];
        return (
            pool.underlying,
            pool.wrapper,
            pool.poolManager,
            pool.underlyingEscrowed,
            pool.stakedSupply,
            pool.rewardToken
        );
    }

    /// @inheritdoc IMasterLevr_v1
    function getLevrIdByUnderlying(
        address underlying
    ) external view returns (uint256) {
        return levrIdByUnderlying[underlying];
    }

    /// @notice Update user's claimable rewards
    /// @param levrId Pool ID
    /// @param user User address
    function _updateUserRewards(uint256 levrId, address user) internal {
        UserStake storage userStake = userStakes[levrId][user];
        LevrPool storage pool = levr[levrId];

        uint256 currentIndex = pool.rewardIndexX64;
        uint256 userIndex = userStake.indexX64;
        uint256 userStakeAmount = userStake.amount;

        if (currentIndex > userIndex && userStakeAmount > 0) {
            uint256 accrued = ((currentIndex - userIndex) * userStakeAmount) /
                Q64;
            userStake.claimable += accrued;
        }

        userStake.indexX64 = currentIndex;
    }

    /// @notice Update the reward rate calculation
    /// @param levrId Pool ID
    function _updateRate(uint256 levrId) internal {
        LevrPool storage pool = levr[levrId];

        uint256 timeElapsed = block.timestamp - pool.lastRateUpdate;
        if (timeElapsed > 0 && pool.stakedSupply > 0) {
            // Simple rate calculation - in production this would be more sophisticated
            // For now, just track the last update time
            pool.lastRateUpdate = block.timestamp;
        }
    }

    /// @notice Test function to set reward index (for testing only)
    /// @param levrId Pool ID
    /// @param index New reward index
    function testSetRewardIndex(uint256 levrId, uint256 index) external {
        levr[levrId].rewardIndexX64 = index;
    }
}
