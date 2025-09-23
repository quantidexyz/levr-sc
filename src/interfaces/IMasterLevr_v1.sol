// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";

/// @title IMasterLevr_v1 - Interface for the Lever protocol's MasterLevr contract
/// @notice Provides ERC20 wrapper tokens with 1:1 peg to underlying Clanker tokens,
/// staking rewards from protocol fees, and FCFS redemption solvency
interface IMasterLevr_v1 {
    /// @notice Thrown when attempting to redeem more than available escrow
    error InsufficientEscrow();

    /// @notice Thrown when pool is not registered
    error PoolNotRegistered();

    /// @notice Thrown when user has insufficient wrapper balance for redemption
    error InsufficientBalance();

    /// @notice Thrown when harvest amount exceeds tracked entitlement
    error HarvestAmountTooLarge();

    /// @notice Thrown when invalid underlying address is provided
    error InvalidUnderlying();

    /// @notice Thrown when invalid pool manager address is provided
    error InvalidPoolManager();

    /// @notice Thrown when attempting to register a pool that is already registered
    error PoolAlreadyRegistered();

    /// @notice Thrown when user has insufficient staked amount for unstaking
    error InsufficientStake();

    /// @notice Thrown when attempting to claim rewards but none are available
    error NoRewardsToClaim();

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

    /// @notice Emitted when a pool is registered
    event PoolRegistered(
        uint256 indexed leverId,
        address indexed underlying,
        address indexed wrapper,
        address poolManager,
        bytes poolKeyEncoded
    );

    /// @notice Emitted when tokens are minted
    event Minted(
        uint256 indexed leverId,
        address indexed user,
        uint256 underlyingAmount,
        uint256 wrapperAmount
    );

    /// @notice Emitted when tokens are redeemed
    event Redeemed(
        uint256 indexed leverId,
        address indexed user,
        uint256 wrapperAmount,
        uint256 underlyingAmount
    );

    /// @notice Emitted when wrapper tokens are staked
    event Staked(uint256 indexed leverId, address indexed user, uint256 amount);

    /// @notice Emitted when wrapper tokens are unstaked
    event Unstaked(
        uint256 indexed leverId,
        address indexed user,
        uint256 amount
    );

    /// @notice Emitted when staking rewards are claimed
    event Claimed(
        uint256 indexed leverId,
        address indexed user,
        address rewardToken,
        uint256 amount
    );

    /// @notice Emitted when protocol fees are harvested
    event Harvested(
        uint256 indexed leverId,
        address indexed rewardToken,
        uint256 amount
    );

    /// @notice Emitted when solvency changes
    event SolvencyChanged(
        uint256 indexed leverId,
        uint256 underlyingEscrowed,
        uint256 wrapperSupply
    );

    /// @notice Register a new pool with underlying token and v4 pool configuration
    /// @param underlying The Clanker-launched ERC20 token address
    /// @param poolManager The Uniswap v4 PoolManager address
    /// @param poolKeyEncoded ABI-encoded PoolKey for the v4 pool
    /// @return leverId Unique identifier for this pool
    /// @return wrapper Address of the deployed wrapper ERC20 token (with name "Levr <underlying_name>" and symbol "w<underlying_symbol>")
    function registerPool(
        address underlying,
        address poolManager,
        bytes calldata poolKeyEncoded
    ) external returns (uint256 leverId, address wrapper);

    /// @notice Mint wrapper tokens by depositing underlying tokens
    /// @param leverId The pool identifier
    /// @param amountUnderlying Amount of underlying tokens to deposit
    /// @param to Address to receive the wrapper tokens
    function mint(
        uint256 leverId,
        uint256 amountUnderlying,
        address to
    ) external;

    /// @notice Redeem wrapper tokens for underlying tokens (FCFS)
    /// @param leverId The pool identifier
    /// @param amountWrapper Amount of wrapper tokens to redeem
    /// @param to Address to receive the underlying tokens
    function redeem(
        uint256 leverId,
        uint256 amountWrapper,
        address to
    ) external;

    /// @notice Stake wrapper tokens to earn protocol fee rewards
    /// @param leverId The pool identifier
    /// @param amount Amount of wrapper tokens to stake
    /// @param to Address to credit the stake to
    function stake(uint256 leverId, uint256 amount, address to) external;

    /// @notice Unstake wrapper tokens
    /// @param leverId The pool identifier
    /// @param amount Amount of wrapper tokens to unstake
    /// @param to Address to receive the unstaked tokens
    function unstake(uint256 leverId, uint256 amount, address to) external;

    /// @notice Claim accumulated staking rewards
    /// @param leverId The pool identifier
    /// @param to Address to receive the reward tokens
    function claim(uint256 leverId, address to) external;

    /// @notice Harvest protocol fees from the v4 pool
    /// @param leverId The pool identifier
    function harvest(uint256 leverId) external;

    /// @notice Get the peg ratio in basis points (underlyingEscrowed * 1e4 / wrapperSupply)
    /// @param leverId The pool identifier
    /// @return bps Peg ratio in basis points (10000 = 100%)
    function getPegBps(uint256 leverId) external view returns (uint256 bps);

    /// @notice Get the current reward rate per second (for APY calculations)
    /// @param leverId The pool identifier
    /// @return ratePerSecondX64 Reward rate per second as Q64.64 fixed point
    function getRatePerSecondX64(
        uint256 leverId
    ) external view returns (uint256 ratePerSecondX64);

    /// @notice Get the total amount staked for a user in a pool
    /// @param leverId The pool identifier
    /// @param user The user address
    /// @return amount Total staked amount
    function getUserStake(
        uint256 leverId,
        address user
    ) external view returns (uint256 amount);

    /// @notice Get the claimable rewards for a user in a pool
    /// @param leverId The pool identifier
    /// @param user The user address
    /// @return amount Claimable reward amount
    function getClaimableRewards(
        uint256 leverId,
        address user
    ) external view returns (uint256 amount);

    /// @notice Get pool information
    /// @param leverId The pool identifier
    /// @return underlying Underlying token address
    /// @return wrapper Wrapper token address
    /// @return poolManager PoolManager address
    /// @return underlyingEscrowed Amount of underlying tokens escrowed
    /// @return stakedSupply Total wrapper tokens staked
    function getPoolInfo(
        uint256 leverId
    )
        external
        view
        returns (
            address underlying,
            address wrapper,
            address poolManager,
            uint256 underlyingEscrowed,
            uint256 stakedSupply
        );

    /// @notice Get the leverId for a given underlying token
    /// @param underlying The underlying token address
    /// @return leverId The pool identifier (0 if not registered)
    function getLeverIdByUnderlying(
        address underlying
    ) external view returns (uint256 leverId);
}
