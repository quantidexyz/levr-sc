// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILevrERC20} from "./interfaces/ILevrERC20.sol";
import {ILevrTreasury_v1} from "./interfaces/ILevrTreasury_v1.sol";
import {ILevrFactory_v1} from "./interfaces/ILevrFactory_v1.sol";

contract LevrTreasury_v1 is ILevrTreasury_v1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable underlying;
    address public immutable factory;
    address public governor;
    address public wrapper;

    uint256 private collectedFees;
    uint256 private _totalStaked;
    mapping(address => uint256) private _stakedBalance;
    // reward tokens registry and accounting
    // use ILevrTreasury_v1.RewardInfo for on-chain layout
    address[] private _rewardTokens; // includes underlying by default
    mapping(address => ILevrTreasury_v1.RewardInfo) private _rewardInfo; // token => info
    mapping(address => mapping(address => int256)) private _rewardDebt; // user => token => debt
    uint256 private constant ACC_SCALE = 1e18;

    constructor(address underlying_, address factory_) {
        if (underlying_ == address(0) || factory_ == address(0))
            revert ILevrTreasury_v1.ZeroAddress();
        underlying = underlying_;
        factory = factory_;
    }

    function initialize(address governor_, address wrapper_) external {
        // one-time init by factory
        if (governor != address(0)) revert();
        if (msg.sender != factory) revert();
        if (governor_ == address(0) || wrapper_ == address(0))
            revert ILevrTreasury_v1.ZeroAddress();
        governor = governor_;
        wrapper = wrapper_;
        // register underlying as a reward token by default
        _rewardInfo[underlying] = ILevrTreasury_v1.RewardInfo({
            accPerShare: 0,
            exists: true
        });
        _rewardTokens.push(underlying);
        emit Initialized(underlying, governor_, wrapper_);
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert ILevrTreasury_v1.OnlyGovernor();
        _;
    }

    modifier onlyWrapper() {
        if (msg.sender != wrapper) revert ILevrTreasury_v1.OnlyWrapper();
        _;
    }

    /// @inheritdoc ILevrTreasury_v1
    function wrap(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 minted) {
        require(to != address(0), "TO_ZERO");
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

        (uint256 protocolFee, uint256 projectFee) = _calculateFees(amount);
        uint256 totalFee = protocolFee;
        if (projectFee > 0) {
            collectedFees += projectFee;
        }

        address protocolTreasury_ = ILevrFactory_v1(factory).protocolTreasury();
        if (protocolFee > 0 && protocolTreasury_ != address(0)) {
            IERC20(underlying).safeTransfer(
                protocolTreasury_,
                protocolFee - projectFee
            );
        }

        minted = amount - totalFee;
        ILevrERC20(wrapper).mint(to, minted);

        emit Wrapped(msg.sender, to, amount, minted, totalFee);
    }

    /// @inheritdoc ILevrTreasury_v1
    function unwrap(
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256 returned) {
        require(to != address(0), "TO_ZERO");
        ILevrERC20(wrapper).burn(msg.sender, amount);

        (uint256 protocolFee, uint256 projectFee) = _calculateFees(amount);
        uint256 totalFee = protocolFee;
        if (projectFee > 0) {
            collectedFees += projectFee;
        }

        address protocolTreasury_ = ILevrFactory_v1(factory).protocolTreasury();
        if (protocolFee > 0 && protocolTreasury_ != address(0)) {
            IERC20(underlying).safeTransfer(
                protocolTreasury_,
                protocolFee - projectFee
            );
        }

        returned = amount - totalFee;
        IERC20(underlying).safeTransfer(to, returned);

        emit Unwrapped(msg.sender, to, amount, returned, totalFee);
    }

    /// @inheritdoc ILevrTreasury_v1
    function transfer(address to, uint256 amount) external onlyGovernor {
        IERC20(underlying).safeTransfer(to, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function applyBoost(uint256 amount) external onlyGovernor {
        _accrue(underlying, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function collectFees() external onlyGovernor {
        uint256 fees = collectedFees;
        if (fees == 0) return;
        collectedFees = 0;
        IERC20(underlying).safeTransfer(governor, fees);
        emit FeesCollected(fees);
    }

    /// @inheritdoc ILevrTreasury_v1
    function getUnderlyingBalance() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @inheritdoc ILevrTreasury_v1
    function getCollectedFees() external view returns (uint256) {
        return collectedFees;
    }

    /// @inheritdoc ILevrTreasury_v1
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ILevrTreasury_v1.InvalidAmount();
        // pull wrapper from user to treasury as staked balance holder
        IERC20(wrapper).safeTransferFrom(msg.sender, address(this), amount);
        // increase debt for all reward tokens proportionally to new stake
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            uint256 acc = _rewardInfo[rt].accPerShare;
            if (acc > 0) {
                _rewardDebt[msg.sender][rt] += int256(
                    (amount * acc) / ACC_SCALE
                );
            }
        }
        _stakedBalance[msg.sender] += amount;
        _totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function unstake(uint256 amount, address to) external nonReentrant {
        if (amount == 0) revert ILevrTreasury_v1.InvalidAmount();
        if (to == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        uint256 bal = _stakedBalance[msg.sender];
        if (bal < amount) revert ILevrTreasury_v1.InsufficientStake();
        // settle pending for all reward tokens before reducing stake
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            _settle(rt, msg.sender, to, bal);
        }
        _stakedBalance[msg.sender] = bal - amount;
        // update debts to reflect new balance
        uint256 newBal = _stakedBalance[msg.sender];
        for (uint256 i2 = 0; i2 < len; i2++) {
            address rt2 = _rewardTokens[i2];
            uint256 acc2 = _rewardInfo[rt2].accPerShare;
            _rewardDebt[msg.sender][rt2] = int256((newBal * acc2) / ACC_SCALE);
        }
        _totalStaked -= amount;
        IERC20(wrapper).safeTransfer(to, amount);
        emit Unstaked(msg.sender, to, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function stakedBalanceOf(
        address account
    ) external view returns (uint256 balance) {
        return _stakedBalance[account];
    }

    /// @inheritdoc ILevrTreasury_v1
    function totalStaked() external view returns (uint256 total) {
        return _totalStaked;
    }

    /// @inheritdoc ILevrTreasury_v1
    function accrueRewards(
        address token,
        uint256 amount
    ) external onlyGovernor {
        _accrue(token, amount);
    }

    /// @inheritdoc ILevrTreasury_v1
    function claimRewards(
        address[] calldata tokens,
        address to
    ) external nonReentrant {
        if (to == address(0)) revert ILevrTreasury_v1.ZeroAddress();
        uint256 bal = _stakedBalance[msg.sender];
        for (uint256 i = 0; i < tokens.length; i++) {
            _settle(tokens[i], msg.sender, to, bal);
        }
        // set debts to current after settlement
        for (uint256 j = 0; j < tokens.length; j++) {
            address rt = tokens[j];
            uint256 acc = _rewardInfo[rt].accPerShare;
            _rewardDebt[msg.sender][rt] = int256((bal * acc) / ACC_SCALE);
        }
    }

    function _accrue(address token, uint256 amount) internal {
        if (amount == 0) revert ILevrTreasury_v1.InvalidAmount();
        uint256 staked = _totalStaked;
        require(staked > 0, "NO_STAKE");
        if (!_rewardInfo[token].exists) {
            _rewardInfo[token] = ILevrTreasury_v1.RewardInfo({
                accPerShare: 0,
                exists: true
            });
            _rewardTokens.push(token);
        }
        ILevrTreasury_v1.RewardInfo storage info = _rewardInfo[token];
        info.accPerShare += (amount * ACC_SCALE) / staked;
        emit BoostApplied(token, amount, info.accPerShare);
    }

    function _settle(
        address token,
        address account,
        address to,
        uint256 bal
    ) internal {
        ILevrTreasury_v1.RewardInfo storage info = _rewardInfo[token];
        if (!info.exists) return;
        uint256 accumulated = (bal * info.accPerShare) / ACC_SCALE;
        int256 debt = _rewardDebt[account][token];
        if (accumulated > uint256(debt)) {
            uint256 pending = accumulated - uint256(debt);
            if (pending > 0) {
                IERC20(token).safeTransfer(to, pending);
                emit RewardsClaimed(account, to, token, pending);
            }
        }
    }

    function _calculateFees(
        uint256 amount
    ) internal view returns (uint256 protocolFee, uint256 projectFee) {
        uint16 protocolFeeBps = ILevrFactory_v1(factory).protocolFeeBps();
        uint16 projectShareBps = ILevrFactory_v1(factory)
            .projectFeeBpsOfProtocolFee();
        protocolFee = (amount * protocolFeeBps) / 10_000;
        projectFee = (protocolFee * projectShareBps) / 10_000;
    }
}
