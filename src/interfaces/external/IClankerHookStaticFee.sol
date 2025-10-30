// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from '@uniswapV4-core/types/PoolId.sol';

interface IClankerHookStaticFee {
    error ClankerFeeTooHigh();
    error PairedFeeTooHigh();

    event PoolInitialized(PoolId poolId, uint24 clankerFee, uint24 pairedFee);

    struct PoolStaticConfigVars {
        uint24 clankerFee;
        uint24 pairedFee;
    }

    function clankerFee(PoolId poolId) external view returns (uint24);
    function pairedFee(PoolId poolId) external view returns (uint24);
}
