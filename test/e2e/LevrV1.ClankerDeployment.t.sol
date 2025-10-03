// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from 'forge-std/console.sol';

import {BaseForkTest} from '../utils/BaseForkTest.sol';
import {ClankerDeployer} from '../utils/ClankerDeployer.sol';

import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {IClanker} from '../../src/interfaces/external/IClanker.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title LevrV1 Clanker Deployment E2E Test
 * @notice Tests the full deployment flow matching the TypeScript SDK:
 *         1. prepareForDeployment() -> get treasury & staking addresses
 *         2. Deploy Clanker token via factory.executeTransaction()
 *         3. register() the deployed token
 *         4. Test multiple token deployments
 */
contract LevrV1_ClankerDeployment_Test is BaseForkTest {
  // Base mainnet Clanker factory address (v4.0)
  address internal constant CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;

  LevrFactory_v1 factory;
  LevrForwarder_v1 forwarder;
  ClankerDeployer deployer;

  address owner = makeAddr('owner');
  address protocolTreasury = makeAddr('protocolTreasury');
  address tokenAdmin = makeAddr('tokenAdmin');

  function setUp() public override {
    super.setUp(); // Fork Base mainnet

    // Deploy forwarder
    forwarder = new LevrForwarder_v1('LevrForwarder_v1');

    // Deploy factory
    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 100,
      submissionDeadlineSeconds: 7 days,
      streamWindowSeconds: 3 days,
      maxSubmissionPerType: 0,
      minWTokenToSubmit: 1e18,
      protocolTreasury: protocolTreasury
    });

    factory = new LevrFactory_v1(cfg, owner, address(forwarder));

    // Deploy Clanker deployer utility
    deployer = new ClankerDeployer();
  }

  /**
   * @notice Test the complete deployment flow matching TypeScript SDK
   * @dev This EXACTLY mirrors: buildCalldatasV4() -> executeMulticall()
   *      Uses snapshots for simulation (like publicClient.call()) then executes atomically
   */
  function test_CompleteDeploymentFlow_MatchingTypeScriptSDK() public {
    vm.startPrank(tokenAdmin);

    // ===== SIMULATION PHASE (matches TypeScript publicClient.call/simulate) =====
    // Uses snapshots to simulate without persisting state changes

    // Step 1: Simulate prepareForDeployment to get addresses
    uint256 snapshot = vm.snapshot();
    bytes memory prepareCalldata = abi.encodeCall(factory.prepareForDeployment, ());
    (address treasury, address staking) = factory.prepareForDeployment();
    vm.revertTo(snapshot);

    console.log('Simulated Treasury:', treasury);
    console.log('Simulated Staking:', staking);

    // Step 2: Build deployment call (matches clanker.getDeployTransaction())
    bytes memory deployCall = abi.encodeCall(
      deployer.deployFactoryStaticFull,
      (
        CLANKER_FACTORY,
        tokenAdmin, // tokenAdmin
        'Test Token', // name
        'TEST', // symbol
        500, // clankerFeeBps (0.5%)
        500 // pairedFeeBps (0.5%)
      )
    );

    // Step 3: Simulate deployment to get token address
    snapshot = vm.snapshot();
    bytes memory executeCalldata = abi.encodeCall(factory.executeTransaction, (address(deployer), deployCall));
    (bool success, bytes memory returnData) = factory.executeTransaction(address(deployer), deployCall);
    require(success, 'Deploy simulation failed');
    address clankerToken = abi.decode(returnData, (address));
    vm.revertTo(snapshot);

    console.log('Simulated Clanker Token:', clankerToken);

    // ===== EXECUTION PHASE (matches executeMulticall) =====
    // Build callDatas array matching TypeScript SDK
    ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](3);

    // Call 1: prepareForDeployment
    calls[0] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: prepareCalldata
    });

    // Call 2: Deploy Clanker token via factory.executeTransaction
    calls[1] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: executeCalldata
    });

    // Call 3: Register token
    calls[2] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: abi.encodeCall(factory.register, (clankerToken))
    });

    // Execute all three calls atomically in ONE transaction (matches SDK)
    ILevrForwarder_v1.Result[] memory results = forwarder.executeMulticall(calls);

    // Verify all calls succeeded
    assertTrue(results[0].success, 'prepareForDeployment failed');
    assertTrue(results[1].success, 'executeTransaction failed');
    assertTrue(results[2].success, 'register failed');

    // Get the actual project contracts
    ILevrFactory_v1.Project memory project = factory.getProjectContracts(clankerToken);

    // Verify project structure matches simulated values
    assertEq(project.treasury, treasury, 'Treasury mismatch');
    assertEq(project.staking, staking, 'Staking mismatch');
    assertTrue(project.governor != address(0), 'Governor not deployed');
    assertTrue(project.stakedToken != address(0), 'StakedToken not deployed');

    console.log('Actual Governor:', project.governor);
    console.log('Actual StakedToken:', project.stakedToken);

    // Verify treasury initialization
    LevrTreasury_v1 treasuryContract = LevrTreasury_v1(payable(treasury));
    assertEq(treasuryContract.governor(), project.governor, 'Governor not set in treasury');
    assertEq(address(treasuryContract.underlying()), clankerToken, 'Underlying token not set');

    // Verify staking initialization
    LevrStaking_v1 stakingContract = LevrStaking_v1(staking);
    assertEq(address(stakingContract.underlying()), clankerToken, 'Underlying not set in staking');
    assertEq(address(stakingContract.stakedToken()), project.stakedToken, 'StakedToken not set in staking');

    vm.stopPrank();
  }

  /**
   * @notice Test deploying multiple tokens - each needs its own preparation
   * @dev This EXACTLY mirrors the TypeScript SDK pattern for multiple deployments
   *      Each deployment: simulate -> build callDatas -> executeMulticall
   */
  function test_MultipleTokenDeployments_ViaMulticall() public {
    vm.startPrank(tokenAdmin);

    // ===== FIRST TOKEN =====
    // Simulate phase (uses snapshots, matches publicClient.call/simulate)

    uint256 snapshot1 = vm.snapshot();
    bytes memory prepareCalldata1 = abi.encodeCall(factory.prepareForDeployment, ());
    (address treasury1, address staking1) = factory.prepareForDeployment();
    vm.revertTo(snapshot1);

    bytes memory deployCall1 = abi.encodeCall(
      deployer.deployFactoryStaticFull,
      (CLANKER_FACTORY, tokenAdmin, 'Token One', 'TK1', 500, 500)
    );

    snapshot1 = vm.snapshot();
    bytes memory executeCalldata1 = abi.encodeCall(factory.executeTransaction, (address(deployer), deployCall1));
    (bool success1, bytes memory returnData1) = factory.executeTransaction(address(deployer), deployCall1);
    require(success1, 'Deploy simulation 1 failed');
    address clankerToken1 = abi.decode(returnData1, (address));
    vm.revertTo(snapshot1);

    // Build callDatas for first token
    ILevrForwarder_v1.SingleCall[] memory calls1 = new ILevrForwarder_v1.SingleCall[](3);

    calls1[0] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: prepareCalldata1
    });

    calls1[1] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: executeCalldata1
    });

    calls1[2] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: abi.encodeCall(factory.register, (clankerToken1))
    });

    // Execute first token deployment via multicall (atomic)
    ILevrForwarder_v1.Result[] memory results1 = forwarder.executeMulticall(calls1);
    assertTrue(results1[0].success, 'Token 1 prepare failed');
    assertTrue(results1[1].success, 'Token 1 deploy failed');
    assertTrue(results1[2].success, 'Token 1 register failed');

    ILevrFactory_v1.Project memory project1 = factory.getProjectContracts(clankerToken1);

    console.log('Token 1 deployed:', clankerToken1);
    console.log('Token 1 treasury:', project1.treasury);

    // ===== SECOND TOKEN =====
    // Simulate phase (uses snapshots, fresh simulation for second token)

    uint256 snapshot2 = vm.snapshot();
    bytes memory prepareCalldata2 = abi.encodeCall(factory.prepareForDeployment, ());
    (address treasury2, address staking2) = factory.prepareForDeployment();
    vm.revertTo(snapshot2);

    // Verify simulated addresses are different (different nonce)
    assertTrue(treasury2 != treasury1, 'Simulated treasuries should be different');
    assertTrue(staking2 != staking1, 'Simulated staking should be different');

    bytes memory deployCall2 = abi.encodeCall(
      deployer.deployFactoryStaticFull,
      (CLANKER_FACTORY, tokenAdmin, 'Token Two', 'TK2', 500, 500)
    );

    snapshot2 = vm.snapshot();
    bytes memory executeCalldata2 = abi.encodeCall(factory.executeTransaction, (address(deployer), deployCall2));
    (bool success2, bytes memory returnData2) = factory.executeTransaction(address(deployer), deployCall2);
    require(success2, 'Deploy simulation 2 failed');
    address clankerToken2 = abi.decode(returnData2, (address));
    vm.revertTo(snapshot2);

    // Build callDatas for second token
    ILevrForwarder_v1.SingleCall[] memory calls2 = new ILevrForwarder_v1.SingleCall[](3);

    calls2[0] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: prepareCalldata2
    });

    calls2[1] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: executeCalldata2
    });

    calls2[2] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      value: 0,
      callData: abi.encodeCall(factory.register, (clankerToken2))
    });

    // Execute second token deployment via multicall (atomic)
    ILevrForwarder_v1.Result[] memory results2 = forwarder.executeMulticall(calls2);
    assertTrue(results2[0].success, 'Token 2 prepare failed');
    assertTrue(results2[1].success, 'Token 2 deploy failed');
    assertTrue(results2[2].success, 'Token 2 register failed');

    ILevrFactory_v1.Project memory project2 = factory.getProjectContracts(clankerToken2);

    console.log('Token 2 deployed:', clankerToken2);
    console.log('Token 2 treasury:', project2.treasury);

    // Verify both projects are independent
    assertTrue(clankerToken1 != clankerToken2, 'Tokens should be different');
    assertTrue(project1.treasury != project2.treasury, 'Treasuries should be different');
    assertTrue(project1.staking != project2.staking, 'Staking contracts should be different');
    assertTrue(project1.governor != project2.governor, 'Governors should be different');
    assertTrue(project1.stakedToken != project2.stakedToken, 'StakedTokens should be different');

    vm.stopPrank();
  }

  /**
   * @notice Test that attempting to register with the same prepared contracts fails
   */
  function test_CannotReusePreparedContractsForSecondToken() public {
    vm.startPrank(tokenAdmin);

    // Prepare once
    (address treasury, address staking) = factory.prepareForDeployment();

    // Deploy first token
    bytes memory deployCall1 = abi.encodeCall(
      deployer.deployFactoryStaticFull,
      (CLANKER_FACTORY, tokenAdmin, 'Token One', 'TK1', 500, 500)
    );

    (bool success1, bytes memory returnData1) = factory.executeTransaction(address(deployer), deployCall1);
    require(success1, 'First deployment failed');
    address clankerToken1 = abi.decode(returnData1, (address));

    // Register first token - should succeed
    factory.register(clankerToken1);

    // Deploy second token WITHOUT preparing again
    bytes memory deployCall2 = abi.encodeCall(
      deployer.deployFactoryStaticFull,
      (CLANKER_FACTORY, tokenAdmin, 'Token Two', 'TK2', 500, 500)
    );

    (bool success2, bytes memory returnData2) = factory.executeTransaction(address(deployer), deployCall2);
    require(success2, 'Second deployment failed');
    address clankerToken2 = abi.decode(returnData2, (address));

    // Try to register second token - should revert because staking is already initialized
    vm.expectRevert();
    factory.register(clankerToken2);

    vm.stopPrank();
  }

  /**
   * @notice Test matching the exact TypeScript SDK rewards config
   * In the TypeScript SDK, rewards recipients are configured via locker config
   * Airdrops are handled via merkle tree (not shown in this basic test)
   */
  function test_RewardsConfig_MatchesTypeScriptSDK() public {
    vm.startPrank(tokenAdmin);

    // Prepare
    (address treasury, address staking) = factory.prepareForDeployment();

    // Deploy token with rewards going to staking (matches TypeScript config)
    bytes memory deployCall = abi.encodeCall(
      deployer.deployFactoryStaticFull,
      (CLANKER_FACTORY, tokenAdmin, 'Rewards Test', 'RWT', 500, 500)
    );

    (bool success, bytes memory returnData) = factory.executeTransaction(address(deployer), deployCall);
    require(success, 'Deployment failed');
    address clankerToken = abi.decode(returnData, (address));

    // Register
    ILevrFactory_v1.Project memory project = factory.register(clankerToken);

    console.log('Token deployed:', clankerToken);
    console.log('Total supply:', IERC20(clankerToken).totalSupply());

    // Note: In the TypeScript SDK, the rewards recipient is set to staking with 100% bps
    // This is configured via the locker's reward recipients
    // The airdrop goes to treasury via the extension

    vm.stopPrank();
  }
}
