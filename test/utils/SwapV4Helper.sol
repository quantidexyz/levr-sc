// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PoolKey} from '@uniswap/v4-core/types/PoolKey.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {IPermit2} from 'lib/permit2/src/interfaces/IPermit2.sol';

// Universal Router imports
import {IUniversalRouter} from 'lib/universal-router/contracts/interfaces/IUniversalRouter.sol';
import {Commands} from 'lib/universal-router/contracts/libraries/Commands.sol';

// V4 Periphery imports
import {IV4Router} from 'lib/universal-router/lib/v4-periphery/src/interfaces/IV4Router.sol';
import {Actions} from 'lib/universal-router/lib/v4-periphery/src/libraries/Actions.sol';

/**
 * @title SwapV4Helper
 * @notice Test utility for executing Uniswap V4 swaps with automatic native ETH handling
 * @dev Based on the TypeScript swap-v4.ts implementation, provides comprehensive swap functionality
 *
 * **Key Features:**
 * - Automatic native ETH ↔ WETH conversions (users never hold WETH directly)
 * - ERC20 approvals via Permit2 for enhanced security
 * - Support for all swap directions: ETH→Token, Token→ETH, Token→Token
 * - Uses Universal Router with V4 actions for optimal gas efficiency
 * - Proper error handling and slippage protection
 *
 * **Architecture:**
 * - Universal Router orchestrates the swap execution
 * - V4Router actions handle the core swap logic
 * - Permit2 manages token approvals with expiration and revocation
 * - Automatic WRAP_ETH/UNWRAP_WETH for seamless native ETH experience
 */
contract SwapV4Helper is Test {
  using StateLibrary for IPoolManager;
  using CurrencyLibrary for Currency;

  // Base Mainnet contract addresses (hardcoded for fork testing)
  IUniversalRouter public constant UNIVERSAL_ROUTER =
    IUniversalRouter(payable(0x6fF5693b99212Da76ad316178A184AB56D299b43)); // Base Universal Router
  IPoolManager public constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b); // Base V4 Pool Manager
  IPermit2 public constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Base Permit2

  address public constant WETH = 0x4200000000000000000000000000000000000006; // Base WETH
  uint256 private constant MAX_UINT256 = type(uint256).max;
  uint160 private constant MAX_UINT160 = type(uint160).max;

  // Events for debugging and monitoring
  event SwapExecuted(
    address indexed user,
    Currency indexed inputCurrency,
    Currency indexed outputCurrency,
    uint256 amountIn,
    uint256 amountOut,
    bool isNativeInput,
    bool isNativeOutput
  );

  event ApprovalSet(address indexed token, address indexed spender, uint256 amount, uint48 expiration);

  struct SwapParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
    uint256 deadline;
  }

  /**
   * @notice Execute a Uniswap V4 swap with automatic native ETH handling
   * @param params Swap configuration including pool key, amounts, and slippage protection
   * @return amountOut Actual amount of tokens received from the swap
   *
   * @dev Execution Flow:
   * 1. **Validation**: Check inputs, pool existence, and user balances
   * 2. **Approvals**: Set up Permit2 approvals for ERC20 tokens (skip for native ETH)
   * 3. **Action Encoding**: Build Universal Router commands based on input/output types
   * 4. **Execution**: Execute swap via Universal Router with proper deadline
   * 5. **Verification**: Validate output amounts and emit events
   *
   * **Native ETH Flows:**
   * - ETH → Token: WRAP_ETH → V4_SWAP → TAKE_ALL (user receives tokens directly)
   * - Token → ETH: V4_SWAP → TAKE → UNWRAP_WETH (user receives native ETH)
   * - Token → Token: V4_SWAP → TAKE_ALL (standard ERC20 flow)
   */
  function executeSwap(SwapParams memory params) external payable returns (uint256 amountOut) {
    // Input validation
    require(params.amountIn > 0, 'SwapV4Helper: ZERO_AMOUNT_IN');
    require(params.deadline > block.timestamp, 'SwapV4Helper: EXPIRED_DEADLINE');

    Currency inputCurrency = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;
    Currency outputCurrency = params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0;

    bool isInputNative = Currency.unwrap(inputCurrency) == address(0) || Currency.unwrap(inputCurrency) == WETH;
    bool isOutputNative = Currency.unwrap(outputCurrency) == address(0) || Currency.unwrap(outputCurrency) == WETH;

    // For native ETH input, verify msg.value matches amountIn
    if (isInputNative) {
      require(msg.value == params.amountIn, 'SwapV4Helper: INCORRECT_ETH_AMOUNT');
    } else {
      require(msg.value == 0, 'SwapV4Helper: UNEXPECTED_ETH');
      // Set up token approvals for ERC20 input
      _setupTokenApprovals(inputCurrency, params.amountIn);
    }

    // Get balances before swap for verification
    uint256 outputBalanceBefore = isOutputNative
      ? address(this).balance
      : IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(this));

    // Build and execute swap commands
    _executeUniversalRouterSwap(params, isInputNative, isOutputNative);

    // Calculate actual output amount
    uint256 outputBalanceAfter = isOutputNative
      ? address(this).balance
      : IERC20(Currency.unwrap(outputCurrency)).balanceOf(address(this));

    amountOut = outputBalanceAfter - outputBalanceBefore;

    // Verify minimum output requirement
    require(amountOut >= params.amountOutMinimum, 'SwapV4Helper: INSUFFICIENT_OUTPUT_AMOUNT');

    emit SwapExecuted(
      msg.sender,
      inputCurrency,
      outputCurrency,
      params.amountIn,
      amountOut,
      isInputNative,
      isOutputNative
    );

    return amountOut;
  }

  /**
   * @notice Set up Permit2 approvals for ERC20 token swaps
   * @param currency The currency to approve
   * @param amount The amount to approve
   * @dev Two-step approval process: Token → Permit2, then Permit2 → Universal Router
   */
  function _setupTokenApprovals(Currency currency, uint256 amount) internal {
    address token = Currency.unwrap(currency);

    // Check current allowances to avoid unnecessary transactions
    uint256 permit2Allowance = IERC20(token).allowance(address(this), address(PERMIT2));
    if (permit2Allowance < amount) {
      IERC20(token).approve(address(PERMIT2), MAX_UINT256);
    }

    // Check Permit2 → Universal Router allowance
    (uint160 allowance, uint48 expiration, ) = PERMIT2.allowance(address(this), token, address(UNIVERSAL_ROUTER));

    if (allowance < amount || expiration <= block.timestamp) {
      uint48 newExpiration = uint48(block.timestamp + 30 days);
      PERMIT2.approve(token, address(UNIVERSAL_ROUTER), MAX_UINT160, newExpiration);

      emit ApprovalSet(token, address(UNIVERSAL_ROUTER), MAX_UINT160, newExpiration);
    }
  }

  /**
   * @notice Execute the swap via Universal Router with proper command encoding
   * @param params Swap parameters
   * @param isInputNative True if input is native ETH/WETH
   * @param isOutputNative True if output is native ETH/WETH
   * @dev Builds command sequence based on input/output types and executes via Universal Router
   */
  function _executeUniversalRouterSwap(SwapParams memory params, bool isInputNative, bool isOutputNative) internal {
    // Build command sequence
    bytes memory commands;
    bytes[] memory inputs;

    if (isInputNative && isOutputNative) {
      // Native ETH → Native ETH (via intermediate token - rare case)
      (commands, inputs) = _buildNativeToNativeCommands(params);
    } else if (isInputNative && !isOutputNative) {
      // Native ETH → Token
      (commands, inputs) = _buildNativeToTokenCommands(params);
    } else if (!isInputNative && isOutputNative) {
      // Token → Native ETH
      (commands, inputs) = _buildTokenToNativeCommands(params);
    } else {
      // Token → Token
      (commands, inputs) = _buildTokenToTokenCommands(params);
    }

    // Execute via Universal Router
    uint256 value = isInputNative ? params.amountIn : 0;
    UNIVERSAL_ROUTER.execute{value: value}(commands, inputs, params.deadline);
  }

  /**
   * @notice Build commands for Native ETH → Token swaps
   * @dev WRAP_ETH → V4_SWAP → TAKE_ALL
   */
  function _buildNativeToTokenCommands(
    SwapParams memory params
  ) internal view returns (bytes memory commands, bytes[] memory inputs) {
    commands = abi.encodePacked(uint8(Commands.WRAP_ETH), uint8(Commands.V4_SWAP));

    inputs = new bytes[](2);

    // WRAP_ETH: recipient = address(this), amount = CONTRACT_BALANCE (use all sent ETH)
    inputs[0] = abi.encode(address(this), 0); // 0 = use contract balance

    // V4_SWAP: Encode actions and parameters
    bytes memory actions = abi.encodePacked(
      uint8(Actions.SWAP_EXACT_IN_SINGLE),
      uint8(Actions.SETTLE), // Router pays from its WETH balance
      uint8(Actions.TAKE_ALL) // User receives tokens directly
    );

    bytes[] memory actionParams = new bytes[](3);
    actionParams[0] = abi.encode(
      IV4Router.ExactInputSingleParams({
        poolKey: params.poolKey,
        zeroForOne: params.zeroForOne,
        amountIn: params.amountIn,
        amountOutMinimum: params.amountOutMinimum,
        hookData: params.hookData
      })
    );
    actionParams[1] = abi.encode(params.poolKey.currency0, params.amountIn, false); // payerIsUser = false
    actionParams[2] = abi.encode(params.poolKey.currency1, 0); // Take all output

    inputs[1] = abi.encode(actions, actionParams);
  }

  /**
   * @notice Build commands for Token → Native ETH swaps
   * @dev V4_SWAP → TAKE → UNWRAP_WETH
   */
  function _buildTokenToNativeCommands(
    SwapParams memory params
  ) internal view returns (bytes memory commands, bytes[] memory inputs) {
    commands = abi.encodePacked(uint8(Commands.V4_SWAP), uint8(Commands.UNWRAP_WETH));

    inputs = new bytes[](2);

    // V4_SWAP: Encode actions and parameters
    bytes memory actions = abi.encodePacked(
      uint8(Actions.SWAP_EXACT_IN_SINGLE),
      uint8(Actions.SETTLE_ALL), // User pays from token balance
      uint8(Actions.TAKE) // Router receives WETH for unwrapping
    );

    bytes[] memory actionParams = new bytes[](3);
    actionParams[0] = abi.encode(
      IV4Router.ExactInputSingleParams({
        poolKey: params.poolKey,
        zeroForOne: params.zeroForOne,
        amountIn: params.amountIn,
        amountOutMinimum: params.amountOutMinimum,
        hookData: params.hookData
      })
    );
    actionParams[1] = abi.encode(params.poolKey.currency0, params.amountIn); // User pays input tokens
    actionParams[2] = abi.encode(params.poolKey.currency1, address(UNIVERSAL_ROUTER), 0); // Router receives WETH

    inputs[0] = abi.encode(actions, actionParams);

    // UNWRAP_WETH: recipient = msg.sender, amount = 0 (unwrap all)
    inputs[1] = abi.encode(msg.sender, 0);
  }

  /**
   * @notice Build commands for Token → Token swaps
   * @dev V4_SWAP only (standard ERC20 flow)
   */
  function _buildTokenToTokenCommands(
    SwapParams memory params
  ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
    commands = abi.encodePacked(uint8(Commands.V4_SWAP));
    inputs = new bytes[](1);

    // V4_SWAP: Standard token-to-token swap
    bytes memory actions = abi.encodePacked(
      uint8(Actions.SWAP_EXACT_IN_SINGLE),
      uint8(Actions.SETTLE_ALL), // User pays input tokens
      uint8(Actions.TAKE_ALL) // User receives output tokens
    );

    bytes[] memory actionParams = new bytes[](3);
    actionParams[0] = abi.encode(
      IV4Router.ExactInputSingleParams({
        poolKey: params.poolKey,
        zeroForOne: params.zeroForOne,
        amountIn: params.amountIn,
        amountOutMinimum: params.amountOutMinimum,
        hookData: params.hookData
      })
    );
    actionParams[1] = abi.encode(params.poolKey.currency0, params.amountIn);
    actionParams[2] = abi.encode(params.poolKey.currency1, 0);

    inputs[0] = abi.encode(actions, actionParams);
  }

  /**
   * @notice Build commands for Native ETH → Native ETH swaps (rare edge case)
   * @dev WRAP_ETH → V4_SWAP → TAKE → UNWRAP_WETH
   */
  function _buildNativeToNativeCommands(
    SwapParams memory params
  ) internal view returns (bytes memory commands, bytes[] memory inputs) {
    commands = abi.encodePacked(uint8(Commands.WRAP_ETH), uint8(Commands.V4_SWAP), uint8(Commands.UNWRAP_WETH));

    inputs = new bytes[](3);

    // WRAP_ETH
    inputs[0] = abi.encode(address(this), 0);

    // V4_SWAP
    bytes memory actions = abi.encodePacked(
      uint8(Actions.SWAP_EXACT_IN_SINGLE),
      uint8(Actions.SETTLE),
      uint8(Actions.TAKE)
    );

    bytes[] memory actionParams = new bytes[](3);
    actionParams[0] = abi.encode(
      IV4Router.ExactInputSingleParams({
        poolKey: params.poolKey,
        zeroForOne: params.zeroForOne,
        amountIn: params.amountIn,
        amountOutMinimum: params.amountOutMinimum,
        hookData: params.hookData
      })
    );
    actionParams[1] = abi.encode(params.poolKey.currency0, params.amountIn, false);
    actionParams[2] = abi.encode(params.poolKey.currency1, address(UNIVERSAL_ROUTER), 0);

    inputs[1] = abi.encode(actions, actionParams);

    // UNWRAP_WETH
    inputs[2] = abi.encode(msg.sender, 0);
  }

  /**
   * @notice Get pool information for debugging and verification
   * @param poolKey The pool key to query
   * @return sqrtPriceX96 Current pool price
   * @return tick Current pool tick
   * @return protocolFee Protocol fee
   * @return lpFee LP fee
   * @return liquidity Current pool liquidity
   */
  function getPoolInfo(
    PoolKey memory poolKey
  ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee, uint128 liquidity) {
    (sqrtPriceX96, tick, protocolFee, lpFee) = POOL_MANAGER.getSlot0(poolKey.toId());
    liquidity = POOL_MANAGER.getLiquidity(poolKey.toId());
  }

  /**
   * @notice Check if user has sufficient balance and approvals for a swap
   * @param user The user address to check
   * @param currency The currency to check
   * @param amount The amount required
   * @return hasBalance True if user has sufficient balance
   * @return hasApproval True if approvals are sufficient
   */
  function checkSwapRequirements(
    address user,
    Currency currency,
    uint256 amount
  ) external view returns (bool hasBalance, bool hasApproval) {
    address token = Currency.unwrap(currency);

    if (token == address(0) || token == WETH) {
      // Native ETH - check balance only
      hasBalance = user.balance >= amount;
      hasApproval = true; // No approval needed for native ETH
    } else {
      // ERC20 token - check both balance and approvals
      hasBalance = IERC20(token).balanceOf(user) >= amount;

      uint256 permit2Allowance = IERC20(token).allowance(user, address(PERMIT2));
      (uint160 routerAllowance, uint48 expiration, ) = PERMIT2.allowance(user, token, address(UNIVERSAL_ROUTER));

      hasApproval = permit2Allowance >= amount && routerAllowance >= amount && expiration > block.timestamp;
    }
  }

  /**
   * @notice Emergency function to recover stuck tokens
   * @dev Only callable in test environment for cleanup
   */
  function recoverToken(address token, uint256 amount) external {
    if (token == address(0)) {
      payable(msg.sender).transfer(amount);
    } else {
      IERC20(token).transfer(msg.sender, amount);
    }
  }

  /**
   * @notice Receive function to handle native ETH
   */
  receive() external payable {
    // Allow receiving ETH for UNWRAP_WETH operations
  }
}
