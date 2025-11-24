// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from 'forge-std/Base.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';

import {LevrStaking_v1} from '../../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../../src/LevrStakedToken_v1.sol';
import {ERC20_Mock} from '../../mocks/ERC20_Mock.sol';

/// @title LevrStaking_v1 handler
/// @notice Exercises stake/unstake/claim flows for invariant testing
contract LevrStaking_v1_Handler is CommonBase, StdUtils {
    LevrStaking_v1 public immutable staking;
    LevrStakedToken_v1 public immutable stakedToken;
    ERC20_Mock public immutable underlying;

    uint256 internal _ghostTotalStaked;
    address[] internal _actors;

    constructor(LevrStaking_v1 staking_, LevrStakedToken_v1 stakedToken_, ERC20_Mock underlying_) {
        staking = staking_;
        stakedToken = stakedToken_;
        underlying = underlying_;

        // Seed a few actors with approvals & balances
        for (uint160 i = 1; i <= 5; i++) {
            address actor = address(i);
            _actors.push(actor);
            underlying_.mint(actor, 1_000_000 ether);

            vm.startPrank(actor);
            underlying_.approve(address(staking_), type(uint256).max);
            vm.stopPrank();
        }
    }

    ///////////////////////////////////////////////////////////////////////////
    // Handler Actions

    function stake(uint256 amountSeed, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 actorBalance = underlying.balanceOf(actor);
        uint256 minAmount = 1e15;
        if (actorBalance < minAmount) return;

        uint256 cap = actorBalance < 100_000e18 ? actorBalance : 100_000e18;
        if (cap < minAmount) return;

        uint256 amount = bound(amountSeed, minAmount, cap);

        vm.startPrank(actor);
        try staking.stake(amount) {
            _ghostTotalStaked += amount;
        } catch {
            // ignore failures to keep run going
        }
        vm.stopPrank();
    }

    function unstake(uint256 amountSeed, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 bal = stakedToken.balanceOf(actor);
        if (bal == 0) return;

        uint256 minAmount = 1;
        uint256 amount = bal <= minAmount ? bal : bound(amountSeed, minAmount, bal);

        vm.startPrank(actor);
        try staking.unstake(amount, actor) {
            if (_ghostTotalStaked >= amount) {
                _ghostTotalStaked -= amount;
            } else {
                _ghostTotalStaked = 0;
            }
        } catch {
            // ignore
        }
        vm.stopPrank();
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (stakedToken.balanceOf(actor) == 0) return;

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);

        vm.prank(actor);
        try staking.claimRewards(tokens, actor) {} catch {}
    }

    function accrue(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e18, 50_000e18);
        underlying.mint(address(staking), amount);
        try staking.accrueRewards(address(underlying)) {} catch {}
    }

    function advanceTime(uint256 secondsForward) external {
        uint256 delta = bound(secondsForward, 1, 30 days);
        vm.warp(block.timestamp + delta);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Ghost Getters

    function ghostTotalStaked() external view returns (uint256) {
        return _ghostTotalStaked;
    }

    ///////////////////////////////////////////////////////////////////////////
    // Helpers

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }
}
