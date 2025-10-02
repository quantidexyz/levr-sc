// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ERC2771ContextBase} from './base/ERC2771ContextBase.sol';
import {ILevrStaking_v1} from './interfaces/ILevrStaking_v1.sol';
import {ILevrStakedToken_v1} from './interfaces/ILevrStakedToken_v1.sol';

interface IERC1363Receiver {
  function onTransferReceived(
    address operator,
    address from,
    uint256 value,
    bytes calldata data
  ) external returns (bytes4);
}

contract LevrStaking_v1 is ILevrStaking_v1, IERC1363Receiver, ReentrancyGuard, ERC2771ContextBase {
  using SafeERC20 for IERC20;

  constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {}

  address public underlying;
  address public stakedToken;
  address public treasury; // for future integrations
  uint32 private _streamWindowSeconds;
  uint64 private _streamStart;
  uint64 private _streamEnd;
  // Per-token streaming state for UI/APR
  mapping(address => uint64) private _streamStartByToken;
  mapping(address => uint64) private _streamEndByToken;
  mapping(address => uint256) private _streamTotalByToken;
  // Track last settlement timestamp per reward token to vest linearly
  mapping(address => uint64) private _lastUpdateByToken;

  uint256 private _totalStaked;
  mapping(address => uint256) private _staked;

  // use ILevrStaking_v1.RewardInfo
  address[] private _rewardTokens;
  mapping(address => ILevrStaking_v1.RewardInfo) private _rewardInfo;
  mapping(address => mapping(address => int256)) private _rewardDebt;
  uint256 private constant ACC_SCALE = 1e18;

  // Track escrowed principal per token to separate it from reward liquidity
  mapping(address => uint256) private _escrowBalance;

  // Track rewards that have been accounted (credited) but not yet claimed
  // for each reward token. Prevents double-accrual and enables liquidity checks.
  mapping(address => uint256) private _rewardReserve;

  function initialize(address underlying_, address stakedToken_, address treasury_) external {
    if (underlying != address(0)) revert();
    if (underlying_ == address(0) || stakedToken_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
    underlying = underlying_;
    stakedToken = stakedToken_;
    treasury = treasury_;
    _rewardInfo[underlying_] = ILevrStaking_v1.RewardInfo({accPerShare: 0, exists: true});
    _rewardTokens.push(underlying_);
  }

  /// @inheritdoc ILevrStaking_v1
  function stake(uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    address staker = _msgSender();
    // Settle streaming for all reward tokens before balance changes
    _settleStreamingAll();
    IERC20(underlying).safeTransferFrom(staker, address(this), amount);
    _escrowBalance[underlying] += amount;
    _increaseDebtForAll(staker, amount);
    _staked[staker] += amount;
    _totalStaked += amount;
    ILevrStakedToken_v1(stakedToken).mint(staker, amount);
    emit Staked(staker, amount);
  }

  /// @inheritdoc ILevrStaking_v1
  function unstake(uint256 amount, address to) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    if (to == address(0)) revert ZeroAddress();
    address staker = _msgSender();
    uint256 bal = _staked[staker];
    if (bal < amount) revert InsufficientStake();
    // Settle streaming before changing balances
    _settleStreamingAll();
    _settleAll(staker, to, bal);
    _staked[staker] = bal - amount;
    _updateDebtAll(staker, _staked[staker]);
    _totalStaked -= amount;
    ILevrStakedToken_v1(stakedToken).burn(staker, amount);
    uint256 esc = _escrowBalance[underlying];
    if (esc < amount) revert InsufficientEscrow();
    _escrowBalance[underlying] = esc - amount;
    IERC20(underlying).safeTransfer(to, amount);
    emit Unstaked(staker, to, amount);
  }

  /// @inheritdoc ILevrStaking_v1
  function claimRewards(address[] calldata tokens, address to) external nonReentrant {
    if (to == address(0)) revert ZeroAddress();
    address claimer = _msgSender();
    uint256 bal = _staked[claimer];
    for (uint256 i = 0; i < tokens.length; i++) {
      _settleStreamingForToken(tokens[i]);
      _settle(tokens[i], claimer, to, bal);
      uint256 acc = _rewardInfo[tokens[i]].accPerShare;
      _rewardDebt[claimer][tokens[i]] = int256((bal * acc) / ACC_SCALE);
    }
  }

  /// @inheritdoc ILevrStaking_v1
  function accrueRewards(address token, uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    uint256 available = _availableUnaccountedRewards(token);
    require(available >= amount, 'INSUFFICIENT_AVAILABLE');
    _creditRewards(token, amount);
  }

  /// @inheritdoc ILevrStaking_v1
  function accrueFromTreasury(address token, uint256 amount, bool pullFromTreasury) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    if (pullFromTreasury) {
      // Only treasury is allowed to initiate a pull from treasury funds
      require(_msgSender() == treasury, 'ONLY_TREASURY');
      uint256 beforeAvail = _availableUnaccountedRewards(token);
      IERC20(token).safeTransferFrom(treasury, address(this), amount);
      uint256 afterAvail = _availableUnaccountedRewards(token);
      uint256 delta = afterAvail > beforeAvail ? afterAvail - beforeAvail : 0;
      if (delta > 0) {
        _creditRewards(token, delta);
      }
    } else {
      uint256 available = _availableUnaccountedRewards(token);
      require(available >= amount, 'INSUFFICIENT_AVAILABLE');
      _creditRewards(token, amount);
    }
  }

  /// @inheritdoc ILevrStaking_v1
  function stakedBalanceOf(address account) external view returns (uint256) {
    return _staked[account];
  }

  /// @inheritdoc ILevrStaking_v1
  function totalStaked() external view returns (uint256) {
    return _totalStaked;
  }

  /// @inheritdoc ILevrStaking_v1
  function escrowBalance(address token) external view returns (uint256) {
    return _escrowBalance[token];
  }

  /// @inheritdoc ILevrStaking_v1
  function streamWindowSeconds() external view returns (uint32) {
    return _streamWindowSeconds;
  }

  /// @inheritdoc ILevrStaking_v1
  function streamStart() external view returns (uint64) {
    return _streamStart;
  }

  /// @inheritdoc ILevrStaking_v1
  function streamEnd() external view returns (uint64) {
    return _streamEnd;
  }

  /// @inheritdoc ILevrStaking_v1
  function rewardRatePerSecond(address token) external view returns (uint256) {
    uint64 start = _streamStartByToken[token];
    uint64 end = _streamEndByToken[token];
    if (end == 0 || end <= start) return 0;
    if (block.timestamp >= end) return 0;
    uint256 window = end - start;
    uint256 total = _streamTotalByToken[token];
    return total / window;
  }

  /// @inheritdoc ILevrStaking_v1
  function aprBps(address /* account */) external view returns (uint256) {
    if (_totalStaked == 0) return 0;
    // Use underlying stream for APR in native units
    uint64 start = _streamStartByToken[underlying];
    uint64 end = _streamEndByToken[underlying];
    if (end == 0 || end <= start) return 0;
    if (block.timestamp >= end) return 0;
    uint256 window = end - start;
    uint256 total = _streamTotalByToken[underlying];
    if (total == 0) return 0;
    // rate per second in underlying units
    uint256 rate = total / window;
    uint256 annual = rate * 365 days;
    // APR bps = annual / totalStaked * 10_000
    return (annual * 10_000) / _totalStaked;
  }

  function _resetStreamForToken(address token, uint256 amount) internal {
    uint32 window = _streamWindowSeconds;
    if (window == 0) {
      window = 3 days;
    }
    _streamWindowSeconds = window;
    _streamStart = uint64(block.timestamp);
    _streamEnd = uint64(block.timestamp + window);
    emit StreamReset(window, _streamStart, _streamEnd);
    _streamStartByToken[token] = uint64(block.timestamp);
    _streamEndByToken[token] = uint64(block.timestamp + window);
    _streamTotalByToken[token] = amount;
    _lastUpdateByToken[token] = uint64(block.timestamp);
  }

  // ERC-1363 auto-sync on transfer (optional if token supports ERC-1363)
  function onTransferReceived(
    address /*operator*/,
    address /*from*/,
    uint256 value,
    bytes calldata /*data*/
  ) external returns (bytes4) {
    address token = msg.sender;
    if (value > 0) {
      _creditRewards(token, value);
    }
    return IERC1363Receiver.onTransferReceived.selector;
  }

  function _creditRewards(address token, uint256 amount) internal {
    ILevrStaking_v1.RewardInfo storage info = _ensureRewardToken(token);
    // Settle current stream up to now before resetting
    _settleStreamingForToken(token);
    // Reset stream window with new amount only (no remaining carry-over)
    _resetStreamForToken(token, amount);
    // Increase reserve by newly provided amount only
    _rewardReserve[token] += amount;
    emit RewardsAccrued(token, amount, info.accPerShare);
  }

  function _ensureRewardToken(address token) internal returns (ILevrStaking_v1.RewardInfo storage info) {
    info = _rewardInfo[token];
    if (!info.exists) {
      _rewardInfo[token] = ILevrStaking_v1.RewardInfo({accPerShare: 0, exists: true});
      _rewardTokens.push(token);
      info = _rewardInfo[token];
    }
  }

  function _availableUnaccountedRewards(address token) internal view returns (uint256) {
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (token == underlying) {
      // exclude escrowed principal when token is the underlying
      if (bal > _escrowBalance[underlying]) {
        bal -= _escrowBalance[underlying];
      } else {
        bal = 0;
      }
    }
    uint256 accounted = _rewardReserve[token];
    return bal > accounted ? bal - accounted : 0;
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

  function _settle(address token, address account, address to, uint256 bal) internal {
    _settleStreamingForToken(token);
    ILevrStaking_v1.RewardInfo storage info = _rewardInfo[token];
    if (!info.exists) return;
    uint256 accumulated = (bal * info.accPerShare) / ACC_SCALE;
    int256 debt = _rewardDebt[account][token];
    if (accumulated > uint256(debt)) {
      uint256 pending = accumulated - uint256(debt);
      if (pending > 0) {
        uint256 reserve = _rewardReserve[token];
        if (reserve < pending) revert InsufficientRewardLiquidity();
        _rewardReserve[token] = reserve - pending;
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

  function _settleStreamingAll() internal {
    uint256 len = _rewardTokens.length;
    for (uint256 i = 0; i < len; i++) {
      _settleStreamingForToken(_rewardTokens[i]);
    }
  }

  function _settleStreamingForToken(address token) internal {
    uint64 start = _streamStartByToken[token];
    uint64 end = _streamEndByToken[token];
    if (end == 0 || start == 0) return;
    uint64 last = _lastUpdateByToken[token];
    uint64 from = last < start ? start : last;
    uint64 to = uint64(block.timestamp);
    if (to > end) to = end;
    if (to <= from) return;
    uint256 duration = end - start;
    uint256 total = _streamTotalByToken[token];
    if (duration == 0 || total == 0) {
      _lastUpdateByToken[token] = to;
      return;
    }
    uint256 vestAmount = (total * (to - from)) / duration;
    if (_totalStaked > 0 && vestAmount > 0) {
      ILevrStaking_v1.RewardInfo storage info = _rewardInfo[token];
      info.accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;
    }
    // Advance last update regardless; if no stakers, the stream time is consumed
    _lastUpdateByToken[token] = to;
  }
}
