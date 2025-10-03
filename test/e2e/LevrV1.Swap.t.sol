// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from 'forge-std/console.sol';

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IClankerLpLocker} from '../../src/interfaces/external/IClankerLPLocker.sol';
import {PoolKey} from '@uniswap/v4-core/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/types/PoolId.sol';
import {Currency} from '@uniswap/v4-core/types/Currency.sol';
import {IV4Router} from '@uniswap/v4-periphery/interfaces/IV4Router.sol';

/**
 * @title LevrV1 Swap E2E Test
 * @notice Tests swapping on V4 pools with Clanker hooks to diagnose SDK issues
 * @dev This test mirrors the TypeScript deploy-swap.test.ts to debug router reverts
 */
contract LevrV1_SwapE2E is BaseForkTest {
  using PoolIdLibrary for PoolKey;
  // Base mainnet addresses
  address internal constant CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
  address internal constant V4_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
  address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
  address internal constant V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
  address internal constant WETH = 0x4200000000000000000000000000000000000006;
  address internal constant LP_LOCKER = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
  address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

  // Use Position Manager directly instead of Universal Router for swaps
  address internal constant SWAP_ROUTER = V4_POSITION_MANAGER;

  ClankerDeployer deployer;
  address tokenAdmin = makeAddr('tokenAdmin');
  address clankerToken;

  // UniversalRouter Commands (from Universal Router docs)
  uint256 constant PERMIT2_TRANSFER_FROM = 0x02;
  uint256 constant SWEEP = 0x04; // Sweep tokens from router to recipient
  uint256 constant WRAP_ETH = 0x0b;
  uint256 constant UNWRAP_WETH = 0x0c;
  uint256 constant V4_SWAP = 0x10;

  // V4Router Actions (from v4-periphery/src/libraries/Actions.sol)
  uint256 constant SWAP_EXACT_IN_SINGLE = 0x06;
  uint256 constant SWAP_EXACT_IN = 0x07; // Multi-hop swap
  uint256 constant SETTLE = 0x0b; // Settle with payer specification
  uint256 constant SETTLE_ALL = 0x0c;
  uint256 constant TAKE = 0x0e; // Take with recipient specification
  uint256 constant TAKE_ALL = 0x0f;
  uint256 constant WRAP = 0x15;

  // ActionConstants (from v4-periphery/src/libraries/ActionConstants.sol)
  address constant MSG_SENDER = address(1); // Recipient = original caller
  address constant ADDRESS_THIS = address(2); // Recipient = router itself
  uint256 constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

  function setUp() public override {
    super.setUp(); // Fork Base mainnet

    deployer = new ClankerDeployer();

    // Give tokenAdmin some ETH for transactions
    vm.deal(tokenAdmin, 100 ether);
  }

  /**
   * @notice Test deploying a Clanker token and performing WETH->Token swap (like DevBuy)
   * @dev Uses the EXACT same pattern as ClankerUniv4EthDevBuy extension
   *      DevBuy successfully demonstrates WETH->Token swaps work perfectly
   */
  function test_DeployAndSwap() public {
    vm.startPrank(tokenAdmin);

    console.log('\n=== DEPLOYING CLANKER TOKEN (NO DEVBUY) ===');

    // Deploy WITHOUT DevBuy so we can manually swap WETH->Token
    clankerToken = deployer.deployFactoryStaticFull({
      clankerFactory: CLANKER_FACTORY,
      tokenAdmin: tokenAdmin,
      name: 'Swap Test Token',
      symbol: 'SWAP',
      clankerFeeBps: 500, // 0.5%
      pairedFeeBps: 500 // 0.5%
    });

    console.log('Token deployed:', clankerToken);
    console.log('Total supply:', IERC20(clankerToken).totalSupply());

    // Get pool info from LP locker using interface
    IClankerLpLocker.TokenRewardInfo memory rewardInfo = IClankerLpLocker(LP_LOCKER).tokenRewards(clankerToken);
    PoolKey memory poolKey = rewardInfo.poolKey;

    console.log('\n=== POOL INFO ===');
    console.log('currency0:', Currency.unwrap(poolKey.currency0));
    console.log('currency1:', Currency.unwrap(poolKey.currency1));
    console.log('fee:', poolKey.fee);
    console.log('tickSpacing:', uint256(uint24(poolKey.tickSpacing)));
    console.log('hooks:', address(poolKey.hooks));

    // Verify pool key matches what we expect
    require(Currency.unwrap(poolKey.currency0) == clankerToken, 'currency0 should be clanker token');
    require(Currency.unwrap(poolKey.currency1) == WETH, 'currency1 should be WETH');

    // Determine swap direction (WETH -> Token, like DevBuy does)
    address tokenIn = WETH;
    address tokenOut = clankerToken;
    uint128 amountIn = 0.01 ether; // Swap 0.01 WETH for tokens
    uint128 amountOutMinimum = 1; // Minimum tokens to receive

    // Determine token ordering in pool
    bool tokenInIsToken0 = Currency.unwrap(poolKey.currency0) == tokenIn;
    bool zeroForOne = tokenInIsToken0;

    console.log('\n=== SWAP PARAMETERS ===');
    console.log('Token In (WETH):', tokenIn);
    console.log('Token Out (Token):', tokenOut);
    console.log('zeroForOne:', zeroForOne);
    console.log('amountIn:', amountIn);

    // Wait for MEV protection delay - need to wait from pool creation time
    console.log('\n=== WAITING FOR MEV DELAY ===');
    console.log('Current timestamp:', block.timestamp);
    // Query hook for pool creation time and max delay
    (bool success, bytes memory data) = address(poolKey.hooks).staticcall(
      abi.encodeWithSignature('poolCreationTimestamp(bytes32)', poolKey.toId())
    );
    require(success, 'Failed to get pool creation timestamp');
    uint256 poolCreationTime = abi.decode(data, (uint256));
    console.log('Pool creation time:', poolCreationTime);

    (success, data) = address(poolKey.hooks).staticcall(abi.encodeWithSignature('MAX_MEV_MODULE_DELAY()'));
    require(success, 'Failed to get MEV delay');
    uint256 maxMevDelay = abi.decode(data, (uint256));
    console.log('Max MEV delay (seconds):', maxMevDelay);

    // Warp to after MEV delay expires
    uint256 unlockTime = poolCreationTime + maxMevDelay + 1;
    if (block.timestamp < unlockTime) {
      console.log('Warping to unlock time:', unlockTime);
      vm.warp(unlockTime);
    }
    console.log('New timestamp after warp:', block.timestamp);

    // Wrap ETH to WETH (like DevBuy does)
    console.log('\n=== WRAPPING ETH TO WETH ===');
    (bool wrapSuccess, ) = WETH.call{value: amountIn}(abi.encodeWithSignature('deposit()'));
    require(wrapSuccess, 'ETH wrap failed');
    console.log('Wrapped ETH to WETH:', amountIn);

    // Approve Position Manager directly (simpler approach)
    console.log('\n=== APPROVING TOKEN TO PERMIT2 ===');
    IERC20(tokenIn).approve(PERMIT2, type(uint256).max);
    console.log('Token approved to Permit2');

    // Approve Universal Router via Permit2
    (bool approveSuccess, ) = PERMIT2.call(
      abi.encodeWithSignature(
        'approve(address,address,uint160,uint48)',
        tokenIn,
        V4_UNIVERSAL_ROUTER,
        type(uint160).max,
        uint48(block.timestamp + 1 days)
      )
    );
    require(approveSuccess, 'Permit2 approval of Universal Router failed');
    console.log('Universal Router approved via Permit2');

    // Try using the Universal Router but with proper encoding
    console.log('\n=== BUILDING SWAP (Universal Router V4) ===');

    // Commands: V4_SWAP only
    bytes memory commands = abi.encodePacked(uint8(V4_SWAP));

    // Actions: SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL
    bytes memory actions = abi.encodePacked(uint8(SWAP_EXACT_IN_SINGLE), uint8(SETTLE_ALL), uint8(TAKE_ALL));

    // Params array
    bytes[] memory params = new bytes[](3);

    // SWAP_EXACT_IN_SINGLE params (ExactInputSingleParams struct)
    params[0] = abi.encode(
      IV4Router.ExactInputSingleParams({
        poolKey: poolKey,
        zeroForOne: zeroForOne,
        amountIn: amountIn,
        amountOutMinimum: amountOutMinimum,
        hookData: bytes('')
      })
    );

    // SETTLE_ALL params: (address token, uint256 amount)
    params[1] = abi.encode(tokenIn, uint256(amountIn));

    // TAKE_ALL params: (address token, uint256 minAmount)
    params[2] = abi.encode(tokenOut, uint256(1));

    // Combine actions and params into inputs
    bytes[] memory inputs = new bytes[](1);
    inputs[0] = abi.encode(actions, params);

    console.log('Actions: SWAP_EXACT_IN_SINGLE (0x06), SETTLE_ALL (0x0C), TAKE_ALL (0x0F)');

    // Execute the swap via Universal Router
    console.log('\n=== EXECUTING SWAP ===');
    console.log('Calling Universal Router with V4_SWAP command');

    uint256 wethBalanceBefore = IERC20(WETH).balanceOf(tokenAdmin);

    // Use the interface properly - execute(bytes commands, bytes[] inputs, uint256 deadline)
    (bool swapSuccess, bytes memory returnData) = V4_UNIVERSAL_ROUTER.call{value: 0}(
      abi.encodeWithSignature('execute(bytes,bytes[],uint256)', commands, inputs, block.timestamp)
    );

    if (!swapSuccess) {
      console.log('\n=== SWAP FAILED ===');
      console.log('Return data length:', returnData.length);
      if (returnData.length > 0) {
        console.log('Return data:');
        console.logBytes(returnData);

        // Try to decode the error
        if (returnData.length >= 4) {
          bytes4 errorSelector;
          assembly {
            errorSelector := mload(add(returnData, 0x20))
          }
          console.log('Error selector:');
          console.logBytes4(errorSelector);
        }
      }

      // Revert with the original error
      assembly {
        revert(add(returnData, 0x20), mload(returnData))
      }
    }

    console.log('\n=== SWAP SUCCESS ===');

    // Check tokens received (output currency)
    uint256 tokensReceived = IERC20(tokenOut).balanceOf(tokenAdmin);
    console.log('Tokens received from swap:', tokensReceived);

    // Check WETH balance after swap
    uint256 wethBalanceAfter = IERC20(WETH).balanceOf(tokenAdmin);
    uint256 wethSpent = wethBalanceBefore - wethBalanceAfter;
    console.log('WETH spent on swap:', wethSpent);
    console.log('Exchange rate:', tokensReceived / 1e18, 'tokens per WETH');

    assertTrue(tokensReceived > 0, 'Should have received tokens from swap');
    assertTrue(wethSpent > 0, 'Should have spent WETH on swap');

    vm.stopPrank();
  }
}
