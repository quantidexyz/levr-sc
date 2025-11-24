// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';

contract LevrStaking_v1_Exposed is LevrStaking_v1 {
    constructor(
        address factory_,
        address trustedForwarder
    ) LevrStaking_v1(factory_, trustedForwarder) {}

    function exposed_creditRewards(address token, uint256 amount) external {
        _creditRewards(token, amount);
    }

    function exposed_settlePoolForToken(address token) external {
        _settlePoolForToken(token);
    }

    function exposed_settleAllPools() external {
        _settleAllPools();
    }

    function exposed_resetStreamForToken(address token, uint256 amount) external {
        _resetStreamForToken(token, amount);
    }

    function exposed_protocolFeeConfig()
        external
        view
        returns (uint16 feeBps, address feeRecipient)
    {
        return _protocolFeeConfig();
    }

    function exposed_chargeProtocolFee(
        uint256 amount,
        address feeRecipient,
        uint16 feeBps
    ) external returns (uint256 feeAmount) {
        return _chargeProtocolFee(amount, feeRecipient, feeBps);
    }

    function exposed_getEffectiveDebt(
        address user,
        address token
    ) external returns (uint256 effectiveDebt) {
        return _getEffectiveDebt(user, token);
    }

    function exposed_availableUnaccountedRewards(address token) external view returns (uint256) {
        return _availableUnaccountedRewards(token);
    }

    function exposed_onStakeNewTimestamp(uint256 stakeAmount) external view returns (uint256) {
        return _onStakeNewTimestamp(stakeAmount);
    }

    function exposed_onUnstakeNewTimestamp(uint256 unstakeAmount) external view returns (uint256) {
        return _onUnstakeNewTimestamp(unstakeAmount);
    }

    function exposed_ensureRewardToken(
        address token,
        uint256 amount
    ) external view returns (ILevrStaking_v1.RewardTokenState memory) {
        return _ensureRewardToken(token, amount);
    }
}
