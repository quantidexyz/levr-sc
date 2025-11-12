// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Minimal Token Contract for DOS Attack Testing
/// @notice Ultra-minimal ERC20-like contract with only balanceOf function
/// @dev Used to test if reward token array can be bloated with minimal contracts
contract MinimalToken {
    /// @notice Returns a fixed balance of 1 wei for any account
    /// @dev This is the bare minimum to pass token checks
    function balanceOf(address /*account*/) external pure returns (uint256) {
        return 1;
    }
}

/// @title DOS Attack Validation Tests for LevrStaking_v1
/// @notice Tests to validate external auditor's claim of DOS vulnerability
/// @dev Based on Shu Ib's report from November 10, 2025
contract LevrStakingV1_DOS_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);
    address internal tokenAdmin;

    // Gas limit constants for validation
    uint256 internal constant BASE_BLOCK_GAS_LIMIT = 30_000_000; // Base mainnet current
    uint256 internal constant POST_EIP_7825_LIMIT = 17_000_000; // Post-Fusaka limit
    uint256 internal constant CLAIMED_STAKE_GAS = 9_700_000; // Auditor's claim
    uint256 internal constant CLAIMED_UNSTAKE_GAS = 18_300_000; // Auditor's claim

    // Mock factory functions for testing
    function clankerFactory() external pure returns (address) {
        return address(0);
    }

    function streamWindowSeconds(address) external pure returns (uint32) {
        return 3 days;
    }

    function setUp() public {
        // Create mock underlying token with admin role
        underlying = new MockERC20('Token', 'TKN');
        tokenAdmin = address(this); // Test contract is admin for simplicity

        // Deploy staking contracts
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked Token',
            'sTKN',
            18,
            address(underlying),
            address(staking)
        );

        // Initialize staking
        initializeStakingWithRewardTokens(
            staking,
            address(underlying),
            address(sToken),
            treasury,
            address(this),
            new address[](0)
        );

        // Fund test account
        underlying.mint(address(this), 1_000_000 ether);
    }

    /// @notice Test 1a: Attempt DOS attack WITHOUT whitelisting tokens (dust amounts)
    /// @dev This test verifies MIN_REWARD_AMOUNT prevents dust attacks
    /// @dev Should revert with RewardTooSmall for dust amounts
    function test_dos_attack_dust_amounts_blocked() public {
        uint256 attackTokenCount = 10;

        for (uint256 i = 0; i < attackTokenCount; i++) {
            MinimalToken dosToken = new MinimalToken();

            // EXPECTED: Should revert with RewardTooSmall (MIN_REWARD_AMOUNT = 1e15)
            // MinimalToken.balanceOf() returns 1 wei, which is < 1e15
            vm.expectRevert(ILevrStaking_v1.RewardTooSmall.selector);
            staking.accrueRewards(address(dosToken));
        }

        console.log('[PASS] MIN_REWARD_AMOUNT prevents dust token DOS');
    }

    /// @notice Test 1b: Attempt DOS with sufficient reward amount but NO whitelist
    /// @dev This test verifies whitelist enforcement when amount >= MIN_REWARD_AMOUNT
    /// @dev Should revert with TokenNotWhitelisted even with sufficient balance
    function test_dos_attack_without_whitelist_sufficient_amount() public {
        uint256 minRewardAmount = staking.MIN_REWARD_AMOUNT(); // 1e15

        // Create a real ERC20 token (not MinimalToken) with sufficient balance
        MockERC20 attackToken = new MockERC20('Attack', 'ATK');
        attackToken.mint(address(staking), minRewardAmount);

        // EXPECTED: Should revert with TokenNotWhitelisted
        // Even though balance is sufficient, token is not whitelisted
        vm.expectRevert(ILevrStaking_v1.TokenNotWhitelisted.selector);
        staking.accrueRewards(address(attackToken));

        console.log('[PASS] Whitelist check prevents non-whitelisted token accrual');
    }

    /// @notice Test 2: Measure gas impact with legitimate whitelisted tokens
    /// @dev Tests if admin can whitelist many tokens and cause DOS
    /// @dev This demonstrates admin abuse vector, not external attack
    function test_dos_attack_with_whitelist_gasAnalysis() public {
        uint256 tokenCount = 100; // Start with 100 tokens for manageable test time

        console.log('=== DOS Attack Gas Analysis (Whitelisted Tokens) ===');
        console.log('Token Count:');
        console.log(tokenCount);

        // First stake to establish baseline (with only underlying token in array)
        underlying.approve(address(staking), 10 ether);
        staking.stake(1 ether);

        // Measure baseline gas (1 token in array)
        uint256 baselineStakeGas = _measureStakeGas(1 ether);
        console.log('Baseline stake() gas (1 token):');
        console.log(baselineStakeGas);

        // Now whitelist many MockERC20 tokens (not MinimalToken to avoid balance issues)
        for (uint256 i = 0; i < tokenCount; i++) {
            MockERC20 token = new MockERC20('Token', 'TKN');
            staking.whitelistToken(address(token));
        }

        // Now measure with bloated array
        uint256 bloatedStakeGas = _measureStakeGas(1 ether);
        console.log('Bloated stake() gas:');
        console.log(bloatedStakeGas);

        uint256 bloatedUnstakeGas = _measureUnstakeGas(1 ether);
        console.log('Bloated unstake() gas:');
        console.log(bloatedUnstakeGas);

        console.log('Gas increase for stake():');
        console.log(bloatedStakeGas - baselineStakeGas);

        // Check if gas exceeds limits
        bool exceedsPostFusakaLimit = bloatedStakeGas > POST_EIP_7825_LIMIT ||
            bloatedUnstakeGas > POST_EIP_7825_LIMIT;

        console.log('Exceeds post-Fusaka limit (17M):');
        console.log(exceedsPostFusakaLimit);

        // This test FAILS if gas costs become prohibitive
        // We set threshold at 50% of post-EIP-7825 limit for safety margin
        assertLt(
            bloatedStakeGas,
            POST_EIP_7825_LIMIT / 2,
            'stake() gas cost too high with bloated reward tokens'
        );
        assertLt(
            bloatedUnstakeGas,
            POST_EIP_7825_LIMIT / 2,
            'unstake() gas cost too high with bloated reward tokens'
        );
    }

    /// @notice Test 3: Exact reproduction of auditor's PoC
    /// @dev Attempts to reproduce the 1000-token attack described by Shu Ib
    /// @dev This test will take a long time to run - use smaller count for CI
    function test_SLOW_auditor_poc_exact_reproduction() public {
        uint256 count = 1000; // Auditor's exact scenario

        console.log('=== Reproducing Auditor PoC (1000 tokens) ===');
        console.log('WARNING: This test may take several minutes to complete');

        // Initial stake to avoid first-staker path (prevents dust accrual from MinimalTokens)
        underlying.approve(address(staking), 10 ether);
        staking.stake(10 ether);

        // Attempt to whitelist 1000 tokens
        for (uint256 i = 0; i < count; i++) {
            MinimalToken dosToken = new MinimalToken();

            // Whitelist token (this alone should work if admin)
            staking.whitelistToken(address(dosToken));

            if (i % 100 == 0) {
                console.log('Progress: whitelisted');
                console.log(i);
            }
        }

        console.log('Successfully whitelisted');
        console.log(count);

        // Now try to stake and measure gas (not first staker, measures realistic gas)
        underlying.approve(address(staking), 1);

        uint256 gasStart = gasleft();
        staking.stake(1);
        uint256 stakeGasUsed = gasStart - gasleft();

        console.log('stake() gas used:');
        console.log(stakeGasUsed);
        console.log('Claimed stake gas:');
        console.log(CLAIMED_STAKE_GAS);

        // Try unstake
        gasStart = gasleft();
        staking.unstake(1, address(this));
        uint256 unstakeGasUsed = gasStart - gasleft();

        console.log('unstake() gas used:');
        console.log(unstakeGasUsed);
        console.log('Claimed unstake gas:');
        console.log(CLAIMED_UNSTAKE_GAS);

        // Validate against limits
        console.log('');
        console.log('=== Gas Limit Analysis ===');
        console.log('Base block limit (current):', BASE_BLOCK_GAS_LIMIT);
        console.log('Post-EIP-7825 limit:', POST_EIP_7825_LIMIT);

        bool stakeFitsCurrentLimit = stakeGasUsed < BASE_BLOCK_GAS_LIMIT;
        bool stakeFitsPostFusaka = stakeGasUsed < POST_EIP_7825_LIMIT;
        bool unstakeFitsCurrentLimit = unstakeGasUsed < BASE_BLOCK_GAS_LIMIT;
        bool unstakeFitsPostFusaka = unstakeGasUsed < POST_EIP_7825_LIMIT;

        console.log('stake() fits current limit:', stakeFitsCurrentLimit);
        console.log('stake() fits post-Fusaka limit:', stakeFitsPostFusaka);
        console.log('unstake() fits current limit:', unstakeFitsCurrentLimit);
        console.log('unstake() fits post-Fusaka limit:', unstakeFitsPostFusaka);

        // TEST FAILS if gas exceeds post-Fusaka limit
        // This validates auditor's claim
        if (!stakeFitsPostFusaka || !unstakeFitsPostFusaka) {
            console.log('');
            console.log('[FAIL] DOS VULNERABILITY CONFIRMED');
            console.log('Functions become unusable post-EIP-7825');
            revert('DOS attack successful - gas limits exceeded');
        } else {
            console.log('');
            console.log('[PASS] No DOS vulnerability');
            console.log('Gas costs within acceptable limits');
        }
    }

    /// @notice Test 4: Gas scaling analysis across different token counts
    /// @dev Measures how gas scales with number of reward tokens
    function test_gas_scaling_analysis() public {
        uint256[] memory tokenCounts = new uint256[](5);
        tokenCounts[0] = 10;
        tokenCounts[1] = 50;
        tokenCounts[2] = 100;
        tokenCounts[3] = 200;
        tokenCounts[4] = 500;

        console.log('=== Gas Scaling Analysis ===');
        console.log('Token Count | stake() Gas | unstake() Gas | Exceeds 17M');
        console.log('----------------------------------------------------------------');

        for (uint256 j = 0; j < tokenCounts.length; j++) {
            uint256 count = tokenCounts[j];

            // Create fresh staking instance for each test
            LevrStaking_v1 testStaking = new LevrStaking_v1(address(0));
            LevrStakedToken_v1 testSToken = new LevrStakedToken_v1(
                'Test Staked',
                'tSTK',
                18,
                address(underlying),
                address(testStaking)
            );

            initializeStakingWithRewardTokens(
                testStaking,
                address(underlying),
                address(testSToken),
                treasury,
                address(this),
                new address[](0)
            );

            // Initial stake to avoid first-staker path
            underlying.approve(address(testStaking), 10 ether);
            testStaking.stake(1 ether);

            // Whitelist tokens
            for (uint256 i = 0; i < count; i++) {
                MinimalToken dosToken = new MinimalToken();
                testStaking.whitelistToken(address(dosToken));
            }

            uint256 stakeGas = _measureStakeGasFor(testStaking, 1 ether);
            uint256 unstakeGas = _measureUnstakeGasFor(testStaking, 1 ether);

            bool exceedsLimit = stakeGas > POST_EIP_7825_LIMIT || unstakeGas > POST_EIP_7825_LIMIT;

            console.log(count);
            console.log(stakeGas);
            console.log(unstakeGas);
            console.log(exceedsLimit);
        }
    }

    /// @notice Test 5: Verify cleanup mechanism can mitigate array bloat
    /// @dev Tests if cleanupFinishedRewardToken reduces gas costs
    function test_cleanup_mechanism_reduces_gas() public {
        uint256 tokenCount = 100;

        console.log('=== Cleanup Mechanism Test ===');

        // Initial stake to avoid first-staker path (which tries to credit dust from MinimalTokens)
        underlying.approve(address(staking), 10 ether);
        staking.stake(10 ether);

        // Whitelist tokens
        address[] memory tokens = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            MinimalToken dosToken = new MinimalToken();
            tokens[i] = address(dosToken);
            staking.whitelistToken(address(dosToken));
        }

        // Measure gas with bloated array (not first staker, avoids dust accrual)
        uint256 gasWithBloat = _measureStakeGas(1 ether);
        console.log('Gas with tokens:');
        console.log(tokenCount);
        console.log(gasWithBloat);

        // Unwhitelist and cleanup tokens
        for (uint256 i = 0; i < tokenCount; i++) {
            // Unwhitelist (requires admin)
            staking.unwhitelistToken(tokens[i]);

            // Cleanup (permissionless)
            staking.cleanupFinishedRewardToken(tokens[i]);
        }

        // Measure gas after cleanup
        uint256 gasAfterCleanup = _measureStakeGas(1 ether);
        console.log('Gas after cleanup:');
        console.log(gasAfterCleanup);
        console.log('Gas reduction:');
        console.log(gasWithBloat - gasAfterCleanup);

        // Cleanup should significantly reduce gas
        assertLt(gasAfterCleanup, gasWithBloat, 'Cleanup should reduce gas costs');
    }

    // ============ Helper Functions ============

    /// @notice Measure gas cost of stake() operation
    /// @param amount Amount to stake
    /// @return gasUsed Gas consumed by stake()
    function _measureStakeGas(uint256 amount) internal returns (uint256 gasUsed) {
        underlying.approve(address(staking), amount);
        uint256 gasStart = gasleft();
        staking.stake(amount);
        gasUsed = gasStart - gasleft();
    }

    /// @notice Measure gas cost of stake() for specific staking contract
    function _measureStakeGasFor(
        LevrStaking_v1 _staking,
        uint256 amount
    ) internal returns (uint256 gasUsed) {
        underlying.approve(address(_staking), amount);
        uint256 gasStart = gasleft();
        _staking.stake(amount);
        gasUsed = gasStart - gasleft();
    }

    /// @notice Measure gas cost of unstake() operation
    /// @param amount Amount to unstake
    /// @return gasUsed Gas consumed by unstake()
    function _measureUnstakeGas(uint256 amount) internal returns (uint256 gasUsed) {
        uint256 gasStart = gasleft();
        staking.unstake(amount, address(this));
        gasUsed = gasStart - gasleft();
    }

    /// @notice Measure gas cost of unstake() for specific staking contract
    function _measureUnstakeGasFor(
        LevrStaking_v1 _staking,
        uint256 amount
    ) internal returns (uint256 gasUsed) {
        uint256 gasStart = gasleft();
        _staking.unstake(amount, address(this));
        gasUsed = gasStart - gasleft();
    }
}
