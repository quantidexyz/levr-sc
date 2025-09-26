// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice Minimal v4 swap helper that performs on-chain PoolManager swaps to generate LP fees.
/// - Wraps ETH to WETH
/// - Swaps WETH->token to acquire output
/// - Swaps token->WETH (small portion) so fees accrue in token side
contract PoolManagerFeeHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    // Base Mainnet anchors
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant POOL_MANAGER =
        0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant STATIC_FEE_HOOK =
        0xb429d62f8f3bFFb98CdB9569533eA23bF0Ba28CC;
    bytes32 public constant CURRENCY_ETH = keccak256("ETH");
    uint24 public constant FEE = 8_388_608; // matches deploy
    int24 public constant TICK_SPACING = 200;

    enum OpKind {
        SwapExactIn,
        Donate
    }

    struct SwapOp {
        OpKind kind;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
    }

    // Transient storage for callback
    SwapOp private pending;

    receive() external payable {}

    function swapEthForToken(address token, uint256 amountIn) external payable {
        require(msg.value >= amountIn, "INSUFFICIENT_ETH");
        IWETH(WETH).deposit{value: amountIn}();

        (PoolKey memory key, bool wethIs0) = _poolKey(token);

        uint256 firstIn = amountIn / 2;
        // Attempt swap; fallback to donate if swap path reverts due to hook constraints
        try this._swapExactInExternal(key, wethIs0 ? true : false, firstIn) {
            // ok
        } catch {
            _donateFees(key, amountIn / 100); // donate 1% to generate fees
        }

        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        if (tokenBal > 0) {
            uint256 secondIn = tokenBal / 4;
            if (secondIn > 0) {
                bool zeroForOneTokenToWeth = !wethIs0;
                try
                    this._swapExactInExternal(
                        key,
                        zeroForOneTokenToWeth,
                        secondIn
                    )
                {} catch {
                    _donateFees(key, amountIn / 200);
                }
            }
        }
    }

    /// @notice Simple donate flow to accrue LP fees without swapping.
    /// Wraps ETH to WETH, transfers to PoolManager, and donates on the WETH side.
    function donateEthForFees(
        address token,
        uint256 donateAmount
    ) external payable {
        require(msg.value >= donateAmount, "INSUFFICIENT_ETH");
        (PoolKey memory key, bool wethIs0) = _poolKey(token);
        address donateToken = wethIs0
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        if (donateToken != WETH) revert("UNSUPPORTED_DONATE_TOKEN");

        IWETH(WETH).deposit{value: donateAmount}();

        uint256 nudge = donateAmount / 10;
        if (nudge > 0) {
            try this._swapExactInExternal(key, wethIs0, nudge) {} catch {}
        }

        uint256 remaining = IERC20(WETH).balanceOf(address(this));
        require(remaining > 0, "NO_DONATE_BAL");
        _donateFees(key, remaining);
    }

    function _swapExactInExternal(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) external {
        require(msg.sender == address(this), "ONLY_SELF");
        _swapExactIn(key, zeroForOne, amountIn);
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "ONLY_PM");
        SwapOp memory op = abi.decode(data, (SwapOp));
        pending = op;

        if (op.kind == OpKind.SwapExactIn) {
            Currency inCur = op.zeroForOne
                ? op.key.currency0
                : op.key.currency1;
            address inToken = Currency.unwrap(inCur);

            IPoolManager(pm()).sync(inCur);
            IERC20(inToken).transfer(pm(), op.amountIn);
            IPoolManager(pm()).settle();

            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: op.zeroForOne,
                amountSpecified: -int256(op.amountIn),
                sqrtPriceLimitX96: op.zeroForOne
                    ? uint160(4295128739)
                    : type(uint160).max
            });
            IPoolManager(pm()).swap(op.key, params, bytes(""));
        } else {
            bool wethIs0 = Currency.unwrap(op.key.currency0) == WETH;
            IPoolManager(pm()).sync(Currency.wrap(WETH));
            IERC20(WETH).transfer(pm(), op.amountIn);
            IPoolManager(pm()).settle();
            IPoolManager(pm()).donate(
                op.key,
                wethIs0 ? op.amountIn : 0,
                wethIs0 ? 0 : op.amountIn,
                bytes("")
            );
        }

        delete pending;
        return bytes("");
    }

    function _swapExactIn(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) internal {
        SwapOp memory op = SwapOp({
            kind: OpKind.SwapExactIn,
            key: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn
        });
        IPoolManager(pm()).unlock(abi.encode(op));
    }

    function _donateFees(PoolKey memory key, uint256 amount) internal {
        SwapOp memory op = SwapOp({
            kind: OpKind.Donate,
            key: key,
            zeroForOne: false,
            amountIn: amount
        });
        IPoolManager(pm()).unlock(abi.encode(op));
    }

    function _poolKey(
        address token
    ) internal pure returns (PoolKey memory key, bool wethIs0) {
        Currency cWeth = Currency.wrap(WETH);
        Currency cTok = Currency.wrap(token);
        wethIs0 = Currency.unwrap(cWeth) < Currency.unwrap(cTok);
        key = PoolKey({
            currency0: wethIs0 ? cWeth : cTok,
            currency1: wethIs0 ? cTok : cWeth,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(STATIC_FEE_HOOK)
        });
    }

    function pm() internal pure returns (address) {
        return POOL_MANAGER;
    }
}
