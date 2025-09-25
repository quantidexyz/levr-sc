// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILevrStaking_v1} from "./interfaces/ILevrStaking_v1.sol";
import {ILevrStakedToken_v1} from "./interfaces/ILevrStakedToken_v1.sol";

contract LevrStaking_v1 is ILevrStaking_v1, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public underlying;
    address public stakedToken;
    address public treasury; // for future integrations

    uint256 private _totalStaked;
    mapping(address => uint256) private _staked;

    struct RewardInfo {
        uint256 accPerShare;
        bool exists;
    }
    address[] private _rewardTokens;
    mapping(address => RewardInfo) private _rewardInfo;
    mapping(address => mapping(address => int256)) private _rewardDebt;
    uint256 private constant ACC_SCALE = 1e18;

    function initialize(
        address underlying_,
        address stakedToken_,
        address treasury_
    ) external {
        if (underlying != address(0)) revert();
        if (
            underlying_ == address(0) ||
            stakedToken_ == address(0) ||
            treasury_ == address(0)
        ) revert ZeroAddress();
        underlying = underlying_;
        stakedToken = stakedToken_;
        treasury = treasury_;
        _rewardInfo[underlying_] = RewardInfo({accPerShare: 0, exists: true});
        _rewardTokens.push(underlying_);
    }

    /// @inheritdoc ILevrStaking_v1
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        _increaseDebtForAll(msg.sender, amount);
        _staked[msg.sender] += amount;
        _totalStaked += amount;
        ILevrStakedToken_v1(stakedToken).mint(msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function unstake(uint256 amount, address to) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = _staked[msg.sender];
        if (bal < amount) revert InsufficientStake();
        _settleAll(msg.sender, to, bal);
        _staked[msg.sender] = bal - amount;
        _updateDebtAll(msg.sender, _staked[msg.sender]);
        _totalStaked -= amount;
        ILevrStakedToken_v1(stakedToken).burn(msg.sender, amount);
        IERC20(underlying).safeTransfer(to, amount);
        emit Unstaked(msg.sender, to, amount);
    }

    /// @inheritdoc ILevrStaking_v1
    function claimRewards(
        address[] calldata tokens,
        address to
    ) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = _staked[msg.sender];
        for (uint256 i = 0; i < tokens.length; i++) {
            _settle(tokens[i], msg.sender, to, bal);
            uint256 acc = _rewardInfo[tokens[i]].accPerShare;
            _rewardDebt[msg.sender][tokens[i]] = int256(
                (bal * acc) / ACC_SCALE
            );
        }
    }

    /// @inheritdoc ILevrStaking_v1
    function accrueRewards(address token, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        uint256 staked = _totalStaked;
        require(staked > 0, "NO_STAKE");
        if (!_rewardInfo[token].exists) {
            _rewardInfo[token] = RewardInfo({accPerShare: 0, exists: true});
            _rewardTokens.push(token);
        }
        RewardInfo storage info = _rewardInfo[token];
        info.accPerShare += (amount * ACC_SCALE) / staked;
        emit RewardsAccrued(token, amount, info.accPerShare);
    }

    /// @inheritdoc ILevrStaking_v1
    function stakedBalanceOf(address account) external view returns (uint256) {
        return _staked[account];
    }

    /// @inheritdoc ILevrStaking_v1
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    function _increaseDebtForAll(address account, uint256 amount) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            uint256 acc = _rewardInfo[rt].accPerShare;
            if (acc > 0) {
                _rewardDebt[account][rt] += int256((amount * acc) / ACC_SCALE);
            }
        }
    }

    function _updateDebtAll(address account, uint256 newBal) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address rt = _rewardTokens[i];
            uint256 acc = _rewardInfo[rt].accPerShare;
            _rewardDebt[account][rt] = int256((newBal * acc) / ACC_SCALE);
        }
    }

    function _settle(
        address token,
        address account,
        address to,
        uint256 bal
    ) internal {
        RewardInfo storage info = _rewardInfo[token];
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

    function _settleAll(address account, address to, uint256 bal) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _settle(_rewardTokens[i], account, to, bal);
        }
    }
}
