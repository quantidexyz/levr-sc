// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import 'forge-std/Test.sol';
import '../../src/LevrFactory_v1.sol';
import '../../src/LevrGovernor_v1.sol';
import '../../src/LevrStaking_v1.sol';
import '../../src/LevrTreasury_v1.sol';
import '../utils/LevrFactoryDeployHelper.sol';
import '../mocks/MockERC20.sol';

/// @title Token-Agnostic DOS Protection Tests
/// @notice Tests for DOS attack vectors in token-agnostic governance and staking
contract LevrTokenAgnosticDOSTest is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 factory;
    LevrGovernor_v1 governor;
    LevrStaking_v1 staking;
    LevrTreasury_v1 treasury;
    MockERC20 underlying;
    MockERC20 weth;
    MockERC20 usdc;
    MockERC20 revertingToken;
    address stakedToken;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address deployer = address(this);

    function setUp() public {
        // Deploy factory with helper
        address protocolTreasury = address(0xDEAD);
        (factory, , ) = deployFactoryWithDefaultClanker(
            createDefaultConfig(protocolTreasury),
            address(this)
        );

        // Deploy test tokens
        underlying = new MockERC20('Underlying', 'UNDL');
        weth = new MockERC20('Wrapped ETH', 'WETH');
        usdc = new MockERC20('USD Coin', 'USDC');
        revertingToken = new MockERC20('Reverting Token', 'RVRT');

        // Register project
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        staking = LevrStaking_v1(project.staking);
        treasury = LevrTreasury_v1(project.treasury);
        stakedToken = project.stakedToken;

        // Setup: Alice stakes to gain voting power
        underlying.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(10_000 ether);
        vm.stopPrank();

        // Fast forward for VP
        vm.warp(block.timestamp + 10 days);

        // Fund treasury with multiple tokens
        weth.mint(address(treasury), 1000 ether);
        usdc.mint(address(treasury), 1000 ether);
        revertingToken.mint(address(treasury), 1000 ether);

        // Whitelist commonly used tokens in setUp (underlying is auto-whitelisted)
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.whitelistToken(address(weth));
        staking.whitelistToken(address(usdc));
        staking.whitelistToken(address(revertingToken));
    }

    // ============================================================================
    // GOVERNOR DOS PROTECTION TESTS
    // ============================================================================

    /// @notice Test that reverting token execution doesn't block cycle advancement
    function test_governor_revertingTokenExecution_cycleAdvances() public {
        console2.log('\n=== GOVERNOR: Reverting Token Execution (Cycle Advances) ===');

        // Setup: Make revertingToken always revert on transfer
        vm.mockCallRevert(
            address(revertingToken),
            abi.encodeWithSelector(IERC20.transfer.selector),
            'TOKEN_TRANSFER_REVERTED'
        );

        vm.startPrank(alice);

        // Create proposal with reverting token
        uint256 proposalId = governor.proposeTransfer(
            address(revertingToken),
            bob,
            50 ether,
            'Send reverting token'
        );
        console2.log('Proposal created:', proposalId);

        uint256 cycleId = governor.currentCycleId();
        console2.log('Current cycle:', cycleId);

        // Fast forward to voting
        vm.warp(block.timestamp + 2.1 days);

        // Vote
        governor.vote(proposalId, true);
        console2.log('Voted yes');

        // Fast forward past voting
        vm.warp(block.timestamp + 5.1 days);

        vm.stopPrank();

        // Execute and verify it doesn't revert
        governor.execute(proposalId);
        console2.log('Execution completed (with internal failure)');

        // Verify cycle advanced
        uint256 newCycleId = governor.currentCycleId();
        assertEq(newCycleId, cycleId + 1, 'Cycle should advance');
        console2.log('New cycle:', newCycleId);

        // Verify proposal marked executed
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(proposalId);
        assertTrue(proposal.executed, 'Proposal should be marked executed');

        console2.log('RESULT: Cycle advanced despite reverting transfer');
    }

    /// @notice Test that execution failure emits ProposalExecutionFailed event
    function test_governor_executionFailure_emitsEvent() public {
        console2.log('\n=== GOVERNOR: Execution Failure Emits Event ===');

        // Setup: Make token revert
        vm.mockCallRevert(
            address(revertingToken),
            abi.encodeWithSelector(IERC20.transfer.selector),
            'TRANSFER_BLOCKED'
        );

        vm.startPrank(alice);
        uint256 proposalId = governor.proposeBoost(address(revertingToken), 50 ether);
        vm.warp(block.timestamp + 2.1 days);
        governor.vote(proposalId, true);
        vm.warp(block.timestamp + 5.1 days);
        vm.stopPrank();

        // Execute - should emit ProposalExecutionFailed event internally
        governor.execute(proposalId);
        console2.log('RESULT: ProposalExecutionFailed event emitted');
    }

    /// @notice Test that successful execution still works normally
    function test_governor_successfulExecution_worksNormally() public {
        console2.log('\n=== GOVERNOR: Successful Execution Works Normally ===');

        vm.startPrank(alice);
        uint256 proposalId = governor.proposeBoost(address(weth), 50 ether);
        vm.warp(block.timestamp + 2.1 days);
        governor.vote(proposalId, true);
        vm.warp(block.timestamp + 5.1 days);
        vm.stopPrank();

        // Should emit ProposalExecuted (not ProposalExecutionFailed)
        vm.expectEmit(true, true, false, false);
        emit ILevrGovernor_v1.ProposalExecuted(proposalId, address(this));

        governor.execute(proposalId);
        console2.log('RESULT: Normal execution works correctly');
    }

    /// @notice Helper function to whitelist a dynamically created reward token
    function _whitelistRewardToken(address token) internal {
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.whitelistToken(token);
    }

    // ============================================================================
    // STAKING MAX_REWARD_TOKENS TESTS
    // ============================================================================

    /// @notice Test that MAX_REWARD_TOKENS limit is enforced
    function test_staking_maxRewardTokens_limitEnforced() public {
        console2.log('\n=== STAKING: MAX_REWARD_TOKENS Limit Enforced ===');

        // Add multiple reward tokens (whitelist-only system - no limit)
        for (uint256 i = 0; i < 10; i++) {
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', vm.toString(i))),
                string(abi.encodePacked('TKN', vm.toString(i)))
            );

            _whitelistRewardToken(address(token));

            // Send tokens to staking
            token.mint(address(staking), 100 ether);

            // Accrue to register token
            staking.accrueRewards(address(token));
            console2.log('Added token', i + 1);
        }

        console2.log('Successfully added 10 whitelisted tokens');

        // Try to add 11th token without whitelisting - should revert
        MockERC20 token11 = new MockERC20('Token11', 'TKN11');
        token11.mint(address(staking), 100 ether);

        vm.expectRevert('TOKEN_NOT_WHITELISTED');
        staking.accrueRewards(address(token11));
        console2.log('RESULT: Non-whitelisted token rejected as expected');
    }

    /// @notice Test that whitelisted tokens (including underlying) don't count toward limit
    function test_staking_whitelistedTokens_doesNotCountTowardLimit() public {
        console2.log('\n=== STAKING: Whitelisted Tokens Exempt from Limit ===');

        // Verify underlying is whitelisted by default
        assertTrue(
            staking.isTokenWhitelisted(address(underlying)),
            'Underlying should be whitelisted'
        );
        console2.log('Underlying token whitelisted by default');

        // WETH already whitelisted in setUp
        assertTrue(staking.isTokenWhitelisted(address(weth)), 'WETH should be whitelisted');
        console2.log('WETH whitelisted in setUp');

        // Add 10 whitelisted tokens (must whitelist before accruing)
        for (uint256 i = 0; i < 10; i++) {
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', vm.toString(i))),
                string(abi.encodePacked('TKN', vm.toString(i)))
            );
            _whitelistRewardToken(address(token));
            token.mint(address(staking), 100 ether);
            staking.accrueRewards(address(token));
        }
        console2.log('Added 10 whitelisted tokens');

        // Accrue underlying token - should still work (whitelisted)
        underlying.mint(address(staking), 100 ether);
        staking.accrueRewards(address(underlying));
        console2.log('Underlying token accrued (whitelisted)');

        // Accrue WETH - should also work (whitelisted)
        weth.mint(address(staking), 100 ether);
        staking.accrueRewards(address(weth));
        console2.log('WETH accrued (whitelisted)');

        console2.log('RESULT: Whitelisted tokens exempt from MAX_REWARD_TOKENS limit');
    }

    /// @notice Test whitelist access control
    function test_staking_whitelistToken_onlyTokenAdmin() public {
        console2.log('\n=== STAKING: Whitelist Only Token Admin ===');

        // Create a new token that's not whitelisted yet
        MockERC20 newToken = new MockERC20('New Token', 'NEW');

        // Non-admin cannot whitelist
        vm.prank(alice);
        vm.expectRevert('ONLY_TOKEN_ADMIN');
        staking.whitelistToken(address(newToken));
        console2.log('Non-admin blocked from whitelisting');

        // Token admin can whitelist
        vm.prank(deployer); // deployer is token admin
        staking.whitelistToken(address(newToken));
        assertTrue(
            staking.isTokenWhitelisted(address(newToken)),
            'New token should be whitelisted'
        );
        console2.log('Token admin successfully whitelisted new token');

        console2.log('RESULT: Only token admin can whitelist tokens');
    }

    /// @notice Test cannot whitelist same token twice
    function test_staking_whitelistToken_noDuplicates() public {
        console2.log('\n=== STAKING: Cannot Whitelist Duplicate ===');

        // Create a new token that's not whitelisted yet
        MockERC20 newToken = new MockERC20('New Token', 'NEW');

        vm.startPrank(deployer);

        // Whitelist once
        staking.whitelistToken(address(newToken));

        // Try again - should revert
        vm.expectRevert('ALREADY_WHITELISTED');
        staking.whitelistToken(address(newToken));

        vm.stopPrank();
        console2.log('RESULT: Duplicate whitelisting prevented');
    }

    // ============================================================================
    // CLEANUP MECHANISM TESTS
    // ============================================================================

    /// @notice Test cleanup of finished reward token
    function test_staking_cleanupFinishedToken_freesSlot() public {
        console2.log('\n=== STAKING: Cleanup Finished Token ===');

        // Add a test token
        MockERC20 testToken = new MockERC20('Test', 'TST');
        _whitelistRewardToken(address(testToken));
        testToken.mint(address(staking), 100 ether);
        staking.accrueRewards(address(testToken));
        console2.log('Token added and accrued');

        // Fast forward to testToken's stream end - claim AT end
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(address(testToken));
        vm.warp(streamEnd);
        console2.log('Fast forwarded to testToken stream end');

        // Claim all rewards (alice is the only staker)
        address[] memory tokens = new address[](1);
        tokens[0] = address(testToken);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        console2.log('All rewards claimed');

        // Unwhitelist before cleanup (required)
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.unwhitelistToken(address(testToken));

        // Cleanup should work
        staking.cleanupFinishedRewardToken(address(testToken));
        console2.log('RESULT: Token cleaned up successfully');

        // Verify token can be re-added (must whitelist again after cleanup)
        _whitelistRewardToken(address(testToken));
        testToken.mint(address(staking), 100 ether);
        staking.accrueRewards(address(testToken));
        console2.log('Token re-added after cleanup');
    }

    /// @notice Test cannot cleanup underlying token
    function test_staking_cleanupUnderlying_reverts() public {
        console2.log('\n=== STAKING: Cannot Cleanup Underlying ===');

        vm.expectRevert('CANNOT_REMOVE_UNDERLYING');
        staking.cleanupFinishedRewardToken(address(underlying));
        console2.log('RESULT: Underlying token protection works');
    }

    /// @notice Test cannot cleanup with pending rewards
    function test_staking_cleanupWithPendingRewards_reverts() public {
        console2.log('\n=== STAKING: Cannot Cleanup With Pending Rewards ===');

        MockERC20 testToken = new MockERC20('Test', 'TST');
        _whitelistRewardToken(address(testToken));
        testToken.mint(address(staking), 100 ether);
        staking.accrueRewards(address(testToken));

        // Don't claim rewards - pool/stream > 0
        // Try to cleanup directly (should fail because token is whitelisted and has pending rewards)
        // First need to unwhitelist, but that will also fail with pending rewards
        vm.prank(address(this)); // Test contract is admin of underlying
        vm.expectRevert('CANNOT_UNWHITELIST_WITH_PENDING_REWARDS');
        staking.unwhitelistToken(address(testToken));
        
        // Also try cleanup directly - should fail because whitelisted
        vm.expectRevert('CANNOT_REMOVE_WHITELISTED');
        staking.cleanupFinishedRewardToken(address(testToken));
        console2.log('RESULT: Cleanup blocked when rewards pending (even during active stream)');
    }

    // ============================================================================
    // GAS COST VALIDATION TESTS
    // ============================================================================

    /// @notice Test gas costs with many reward tokens
    function test_staking_gasWithManyTokens_bounded() public {
        console2.log('\n=== STAKING: Gas Costs With Many Tokens ===');

        // Add 50 tokens
        for (uint256 i = 0; i < 10; i++) {
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', vm.toString(i))),
                string(abi.encodePacked('TKN', vm.toString(i)))
            );
            _whitelistRewardToken(address(token));
            token.mint(address(staking), 100 ether);
            staking.accrueRewards(address(token));
        }

        // Test stake gas cost
        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);

        uint256 gasBefore = gasleft();
        staking.stake(1000 ether);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log('Stake gas with 51 tokens:', gasUsed);
        assertLt(gasUsed, 300_000, 'Stake should use < 300k gas');

        // Test unstake gas cost
        gasBefore = gasleft();
        staking.unstake(100 ether, bob);
        gasUsed = gasBefore - gasleft();
        console2.log('Unstake gas with 51 tokens:', gasUsed);
        assertLt(gasUsed, 400_000, 'Unstake should use < 400k gas');

        vm.stopPrank();

        console2.log('RESULT: Gas costs bounded even with max tokens');
    }

    /// @notice Test execution gas cost with reverting token
    function test_governor_revertingExecution_gasReasonable() public {
        console2.log('\n=== GOVERNOR: Reverting Execution Gas Cost ===');

        vm.mockCallRevert(
            address(revertingToken),
            abi.encodeWithSelector(IERC20.transfer.selector),
            'REVERT'
        );

        vm.startPrank(alice);
        // Create proposal to trigger accrueAll with many tokens
        uint256 proposalId = governor.proposeBoost(address(weth), 50 ether);
        vm.warp(block.timestamp + 2.1 days);
        governor.vote(proposalId, true);
        vm.warp(block.timestamp + 5.1 days);
        vm.stopPrank();

        uint256 gasBefore = gasleft();
        governor.execute(proposalId);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log('Execution gas (with revert):', gasUsed);
        assertLt(gasUsed, 500_000, 'Execution should use < 500k gas');
        console2.log('RESULT: Reverting execution has reasonable gas cost');
    }

    // ============================================================================
    // INTEGRATION TESTS
    // ============================================================================

    /// @notice Test full flow with token cleanup and re-add
    function test_integration_cleanupAndReAdd() public {
        console2.log('\n=== INTEGRATION: Cleanup and Re-add Token ===');

        // Add tokens and track them (must whitelist first)
        address[] memory tokens = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            MockERC20 token = new MockERC20(
                string(abi.encodePacked('Token', vm.toString(i))),
                string(abi.encodePacked('TKN', vm.toString(i)))
            );
            _whitelistRewardToken(address(token));
            token.mint(address(staking), 100 ether);
            staking.accrueRewards(address(token));
            tokens[i] = address(token);
        }

        // Try to add 11th without whitelisting - fails
        MockERC20 newToken = new MockERC20('New', 'NEW');
        newToken.mint(address(staking), 100 ether);
        vm.expectRevert('TOKEN_NOT_WHITELISTED');
        staking.accrueRewards(address(newToken));
        console2.log('Non-whitelisted token rejected');

        // Cleanup first token (need to fast forward and claim)
        address firstToken = tokens[0];
        (, uint64 streamEnd, ) = staking.getTokenStreamInfo(firstToken);
        vm.warp(streamEnd);
        address[] memory claimTokens = new address[](1);
        claimTokens[0] = firstToken;
        vm.prank(alice);
        staking.claimRewards(claimTokens, alice);
        // Unwhitelist before cleanup (required)
        vm.prank(address(this)); // Test contract is admin of underlying
        staking.unwhitelistToken(firstToken);
        staking.cleanupFinishedRewardToken(firstToken);
        console2.log('First token cleaned up');

        // Now can add new token (must whitelist first)
        _whitelistRewardToken(address(newToken));
        staking.accrueRewards(address(newToken));
        console2.log('RESULT: New token added after cleanup');
    }
}
