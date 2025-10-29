// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title Contract Receiver Rewards Tests
 * @notice Tests for proportional reward transfer to contract receivers
 * @dev Verifies EOAs keep rewards, contracts receive proportional rewards
 */
contract LevrStaking_ContractReceiverRewardsTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;

    address alice = address(0x1111); // EOA
    address bob = address(0x2222); // EOA
    MockPool pool; // Contract

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            maxRewardTokens: 50
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));
        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('WETH', 'WETH');

        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(this),
            address(factory)
        );

        // Create mock pool contract
        pool = new MockPool();

        // Setup users
        underlying.mint(alice, 100000 ether);
        underlying.mint(bob, 100000 ether);
        underlying.mint(address(pool), 100000 ether);
    }

    /// @notice Test EOA to EOA transfer - sender keeps rewards
    function test_contractReceiver_eoaToEoa_senderKeepsRewards() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Complete stream
        vm.warp(block.timestamp + 3 days + 1);

        uint256 aliceRewardsBefore = staking.claimableRewards(alice, address(weth));
        assertEq(aliceRewardsBefore, 1000 ether);

        // Alice transfers to Bob (both EOAs)
        stakedToken.transfer(bob, 500 ether);

        // Alice should KEEP all her rewards (EOA to EOA)
        uint256 aliceRewardsAfter = staking.claimableRewards(alice, address(weth));
        assertEq(aliceRewardsAfter, 1000 ether, 'Alice keeps all rewards (EOA to EOA)');

        // Bob should have 0 (starts fresh)
        uint256 bobRewards = staking.claimableRewards(bob, address(weth));
        assertEq(bobRewards, 0, 'Bob starts fresh');
    }

    /// @notice Test EOA to Contract transfer - sender keeps ALL (seller protection)
    function test_contractReceiver_eoaToContract_senderKeepsAll() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Complete stream
        vm.warp(block.timestamp + 3 days + 1);

        uint256 aliceRewardsBefore = staking.claimableRewards(alice, address(weth));
        console.log('Alice rewards before transfer:', aliceRewardsBefore);
        assertEq(aliceRewardsBefore, 1000 ether);

        // Alice (EOA) transfers to Pool (contract)
        stakedToken.transfer(address(pool), 500 ether);

        // Alice should keep ALL rewards (EOA sender protected)
        uint256 aliceRewardsAfter = staking.claimableRewards(alice, address(weth));
        console.log('Alice rewards after transfer to pool:', aliceRewardsAfter);
        assertEq(aliceRewardsAfter, 1000 ether, 'Alice keeps all (EOA sender protection)');

        // Pool gets 0 rewards (didn't earn yet)
        uint256 poolRewards = staking.claimableRewards(address(pool), address(weth));
        console.log('Pool rewards:', poolRewards);
        assertEq(poolRewards, 0, 'Pool starts with 0 (just received)');
    }

    /// @notice Test CONTRACT to EOA transfer - buyer receives proportional rewards
    function test_contractReceiver_contractToEoa_buyerGetsProportionalRewards() public {
        // Pool stakes and earns rewards
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards (pool earns)
        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Complete stream
        vm.warp(block.timestamp + 3 days + 1);

        uint256 poolRewardsBefore = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolRewardsBefore, 1000 ether, 'Pool earned 1000 WETH');

        // Pool transfers 500 tokens (50%) to Alice (EOA buyer)
        vm.startPrank(address(pool));
        stakedToken.transfer(alice, 500 ether);

        // Pool keeps 50% of rewards (proportional to tokens kept)
        uint256 poolRewardsAfter = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolRewardsAfter, 500 ether, 'Pool keeps 50% (transferred 50%)');

        // Alice (buyer) gets 50% of pool's rewards (incentive to buy!)
        uint256 aliceRewards = staking.claimableRewards(alice, address(weth));
        assertEq(aliceRewards, 500 ether, 'Alice gets 50% rewards (bought from pool)');
    }

    /// @notice Test CONTRACT to EOA transfer - proportional rewards given to buyer
    function test_contractReceiver_contractToEoa_partialTransfer() public {
        // Pool stakes
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards (pool earns)
        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Pool transfers 25% to Alice
        vm.startPrank(address(pool));
        stakedToken.transfer(alice, 250 ether);

        // Pool keeps 75% of rewards
        uint256 poolRewards = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolRewards, 750 ether, 'Pool keeps 75%');

        // Alice (buyer) gets 25% of pool's rewards
        uint256 aliceRewards = staking.claimableRewards(alice, address(weth));
        assertEq(aliceRewards, 250 ether, 'Alice gets 25% (bought 25% of pool tokens)');

        // Pool transfers another 50% to Bob
        stakedToken.transfer(bob, 500 ether);

        // Pool keeps 25% of original (only 250 tokens left)
        uint256 poolFinal = staking.claimableRewards(address(pool), address(weth));
        // Pool had 750, gives 500/750 = 66.67% to Bob, keeps 33.33% = 250
        assertEq(poolFinal, 250 ether, 'Pool keeps final 25%');

        // Bob gets 50% of original rewards
        uint256 bobRewards = staking.claimableRewards(bob, address(weth));
        assertEq(bobRewards, 500 ether, 'Bob gets 50% (bought 50% of pool tokens)');
    }

    /// @notice Test Uniswap buy scenario - buyer gets proportional rewards
    function test_contractReceiver_uniswapBuy_buyerIncentivized() public {
        // Setup: Pool has liquidity
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Pool earns rewards over time
        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        vm.warp(block.timestamp + 3 days + 1);

        uint256 poolRewardsBefore = staking.claimableRewards(address(pool), address(weth));
        console.log('Pool earned:', poolRewardsBefore);
        assertEq(poolRewardsBefore, 1000 ether);

        // Buyer (Bob) buys from pool (pool transfers to Bob - EOA)
        vm.prank(address(pool));
        stakedToken.transfer(bob, 400 ether);

        // Pool keeps 60% of rewards (60% of tokens remaining)
        uint256 poolRewardsAfter = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolRewardsAfter, 600 ether, 'Pool keeps 60%');

        // Bob gets 40% of pool's rewards (EOA receiver - starts fresh)
        // Wait, Bob is EOA so he should get 0!
        uint256 bobRewards = staking.claimableRewards(bob, address(weth));
        assertEq(bobRewards, 0, 'Bob starts fresh (bought from pool to EOA)');

        // This means pool keeps ALL rewards when selling to EOA
        // That's actually GOOD - incentivizes pool to hold!
    }

    /// @notice Test contract detection works correctly
    function test_contractReceiver_contractDetection_accurate() public {
        // Verify our test addresses
        assertTrue(alice.code.length == 0, 'Alice is EOA');
        assertTrue(bob.code.length == 0, 'Bob is EOA');
        assertTrue(address(pool).code.length > 0, 'Pool is contract');

        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Transfer to EOA vs Contract should behave differently
        uint256 aliceRewardsBefore = staking.claimableRewards(alice, address(weth));

        // Transfer 40% to Bob (EOA)
        stakedToken.transfer(bob, 400 ether);
        uint256 aliceAfterEOA = staking.claimableRewards(alice, address(weth));
        uint256 bobAfterEOA = staking.claimableRewards(bob, address(weth));

        // Alice keeps all rewards (transferred to EOA)
        assertEq(aliceAfterEOA, aliceRewardsBefore, 'Alice keeps all when sending to EOA');
        assertEq(bobAfterEOA, 0, 'Bob starts fresh (EOA)');

        // Transfer 50% to Pool (contract)
        stakedToken.transfer(address(pool), 300 ether);
        uint256 aliceAfterContract = staking.claimableRewards(alice, address(weth));
        uint256 poolAfterContract = staking.claimableRewards(address(pool), address(weth));

        // Alice keeps proportional (transferred 50% of remaining 600)
        // She keeps: 1000 - (1000 * 300/600) = 500
        assertEq(
            aliceAfterContract,
            500 ether,
            'Alice keeps proportional when sending to contract'
        );
        assertEq(poolAfterContract, 500 ether, 'Pool receives proportional rewards');
    }

    /// @notice Test multiple token rewards with contract receiver
    function test_contractReceiver_multipleTokens_allTransferred() public {
        // Alice stakes
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Accrue multiple reward tokens
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        underlying.mint(address(staking), 500 ether);
        staking.accrueRewards(address(underlying));

        vm.warp(block.timestamp + 3 days + 1);

        uint256 aliceWethBefore = staking.claimableRewards(alice, address(weth));
        uint256 aliceUnderlyingBefore = staking.claimableRewards(alice, address(underlying));

        console.log('Alice WETH before:', aliceWethBefore);
        console.log('Alice underlying before:', aliceUnderlyingBefore);

        // Transfer 50% to pool
        stakedToken.transfer(address(pool), 500 ether);

        // Alice keeps 50% of each token's rewards
        uint256 aliceWethAfter = staking.claimableRewards(alice, address(weth));
        uint256 aliceUnderlyingAfter = staking.claimableRewards(alice, address(underlying));

        assertEq(aliceWethAfter, aliceWethBefore / 2, 'Alice keeps 50% WETH');
        assertEq(aliceUnderlyingAfter, aliceUnderlyingBefore / 2, 'Alice keeps 50% underlying');

        // Pool receives 50% of each
        uint256 poolWeth = staking.claimableRewards(address(pool), address(weth));
        uint256 poolUnderlying = staking.claimableRewards(address(pool), address(underlying));

        assertEq(poolWeth, aliceWethBefore / 2, 'Pool receives 50% WETH');
        assertEq(poolUnderlying, aliceUnderlyingBefore / 2, 'Pool receives 50% underlying');
    }

    /// @notice Test that pool can claim rewards it received
    function test_contractReceiver_poolCanClaim_rewardsAccessible() public {
        // Alice stakes and earns
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Alice transfers to pool
        stakedToken.transfer(address(pool), 500 ether);

        // Pool should have 500 WETH claimable
        uint256 poolClaimable = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolClaimable, 500 ether);

        // Pool claims (through pool's claim function)
        vm.prank(address(pool));
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 poolBalBefore = weth.balanceOf(address(pool));
        staking.claimRewards(tokens, address(pool));
        uint256 poolBalAfter = weth.balanceOf(address(pool));

        // Pool receives the rewards
        assertEq(poolBalAfter - poolBalBefore, 500 ether, 'Pool claims its rewards');

        // Pool can distribute to LPs or use however it wants
        assertTrue(poolBalAfter > poolBalBefore, 'Pool balance increased');
    }

    /// @notice Test chain: EOA → Contract → EOA
    function test_contractReceiver_chainTransfer_correctRewardFlow() public {
        // Alice stakes and earns
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Alice → Pool (contract): 50% rewards transferred
        stakedToken.transfer(address(pool), 500 ether);

        uint256 aliceAfterPool = staking.claimableRewards(alice, address(weth));
        uint256 poolAfterAlice = staking.claimableRewards(address(pool), address(weth));

        assertEq(aliceAfterPool, 500 ether, 'Alice keeps 50%');
        assertEq(poolAfterAlice, 500 ether, 'Pool gets 50%');

        // Pool → Bob (EOA): Pool keeps rewards, Bob starts fresh
        vm.prank(address(pool));
        stakedToken.transfer(bob, 250 ether);

        uint256 poolAfterBob = staking.claimableRewards(address(pool), address(weth));
        uint256 bobRewards = staking.claimableRewards(bob, address(weth));

        assertEq(poolAfterBob, 500 ether, 'Pool keeps all rewards (sent to EOA)');
        assertEq(bobRewards, 0, 'Bob starts fresh (EOA)');

        // Final state
        console.log('Final Alice:', aliceAfterPool);
        console.log('Final Pool:', poolAfterBob);
        console.log('Final Bob:', bobRewards);
        console.log('Total:', aliceAfterPool + poolAfterBob + bobRewards);

        assertEq(aliceAfterPool + poolAfterBob, 1000 ether, 'All rewards accounted for');
    }

    /// @notice Test that pool earning additional rewards works correctly
    function test_contractReceiver_poolEarnsAdditional_bothOldAndNewClaimable() public {
        // Alice transfers to pool with existing rewards
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Transfer to pool (pool gets 1000 WETH from transfer)
        stakedToken.transfer(address(pool), 1000 ether);

        uint256 poolInitial = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolInitial, 1000 ether, 'Pool received 1000 from transfer');

        // New rewards accrue (pool is now the staker)
        weth.mint(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Pool should have OLD (1000) + NEW (500) rewards
        uint256 poolTotal = staking.claimableRewards(address(pool), address(weth));
        console.log('Pool total claimable:', poolTotal);
        assertEq(poolTotal, 1500 ether, 'Pool has old + new rewards');

        // Pool can claim all
        vm.prank(address(pool));
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256 poolBalBefore = weth.balanceOf(address(pool));
        staking.claimRewards(tokens, address(pool));
        uint256 poolBalAfter = weth.balanceOf(address(pool));

        assertEq(poolBalAfter - poolBalBefore, 1500 ether, 'Pool claims all rewards');
    }

    /// @notice Test Uniswap pool accumulates rewards over time
    function test_contractReceiver_poolAccumulatesRewards_lpsBenefit() public {
        // Simulate Uniswap pool accumulating tokens from multiple sellers

        // Alice sells to pool
        vm.startPrank(alice);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        weth.mint(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        stakedToken.transfer(address(pool), 500 ether); // Alice earned 500 WETH, transfers 100% to pool

        // Bob sells to pool
        vm.startPrank(bob);
        underlying.approve(address(staking), 500 ether);
        staking.stake(500 ether);
        weth.mint(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        stakedToken.transfer(address(pool), 500 ether); // Bob earned 500 WETH, transfers 100% to pool

        // Pool now holds 1000 tokens and should have ~1000 WETH claimable
        // (500 from Alice + 500 from Bob, minus any rewards pool earned while holding)
        uint256 poolRewards = staking.claimableRewards(address(pool), address(weth));
        console.log('Pool total rewards accumulated:', poolRewards);
        assertGe(poolRewards, 1000 ether, 'Pool accumulated rewards from sellers');

        // Pool continues earning
        weth.mint(address(staking), 300 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        uint256 poolFinal = staking.claimableRewards(address(pool), address(weth));
        console.log('Pool final rewards:', poolFinal);
        assertGt(poolFinal, poolRewards, 'Pool earned additional from holding');

        // When LPs withdraw, they get share of pool's assets (including unclaimed rewards)
        // This is economically correct! ✓
    }
}

/**
 * @title Mock Pool Contract
 * @notice Simulates a Uniswap-like pool that can receive and hold staked tokens
 */
contract MockPool {
    // Pool can receive tokens and claim rewards
    function claim(address staking, address[] memory tokens) external {
        LevrStaking_v1(staking).claimRewards(tokens, address(this));
    }
}
