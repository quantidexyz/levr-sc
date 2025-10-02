// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import 'forge-std/Test.sol';
import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrV1 Meta-Transaction Tests
 * @notice Demonstrates ERC2771 meta-transaction compatibility with TransactionForwarder_v1 pattern
 */
contract LevrV1MetaTxTest is Test {
  using ECDSA for bytes32;

  LevrFactory_v1 factory;
  LevrForwarder_v1 forwarder;
  MockERC20 clankerToken;

  ILevrFactory_v1.Project project;

  address owner = address(0x1);
  address relayer = address(0x2);

  // User that will sign meta-transactions
  uint256 userPrivateKey = 0xA11CE;
  address user;

  function setUp() public {
    user = vm.addr(userPrivateKey);

    // Deploy forwarder first (with multicall support)
    vm.prank(owner);
    forwarder = new LevrForwarder_v1('LevrForwarder_v1');

    // Deploy factory with forwarder
    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 100,
      submissionDeadlineSeconds: 7 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 100e18,
      protocolTreasury: address(0x999)
    });

    vm.prank(owner);
    factory = new LevrFactory_v1(cfg, owner, address(forwarder));

    // Prepare deployment
    vm.prank(user);
    (address treasury, address staking) = factory.prepareForDeployment();

    // Deploy mock Clanker token (admin is set to deployer in constructor)
    vm.prank(user);
    clankerToken = new MockERC20('Test Token', 'TEST');

    // Register project
    vm.prank(user);
    project = factory.register(address(clankerToken));

    // Give user some tokens
    clankerToken.mint(user, 1000e18);
  }

  /**
   * @notice Test meta-transaction staking flow
   * @dev User signs a stake transaction, relayer submits it via forwarder
   */
  function test_MetaTx_Stake() public {
    uint256 stakeAmount = 100e18;

    // User approves staking contract (done directly, not via meta-tx)
    vm.prank(user);
    clankerToken.approve(project.staking, stakeAmount);

    // Prepare the stake call
    bytes memory stakeCall = abi.encodeWithSelector(LevrStaking_v1.stake.selector, stakeAmount);

    // Create ERC2771 forward request
    ERC2771Forwarder.ForwardRequestData memory request = ERC2771Forwarder.ForwardRequestData({
      from: user,
      to: project.staking,
      value: 0,
      gas: 300000,
      deadline: uint48(block.timestamp + 1 hours),
      data: stakeCall,
      signature: ''
    });

    // Sign the request
    bytes32 digest = _getDigest(request);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
    request.signature = abi.encodePacked(r, s, v);

    // Relayer executes the meta-transaction
    vm.prank(relayer);
    forwarder.execute(request);

    // Verify stake was successful
    assertEq(LevrStaking_v1(project.staking).stakedBalanceOf(user), stakeAmount);
  }

  /**
   * @notice Test meta-transaction proposal submission
   * @dev User signs a proposal submission, relayer submits it
   */
  function test_MetaTx_ProposeTransfer() public {
    // First stake enough to meet proposal threshold
    uint256 stakeAmount = 200e18;
    vm.startPrank(user);
    clankerToken.approve(project.staking, stakeAmount);
    LevrStaking_v1(project.staking).stake(stakeAmount);
    vm.stopPrank();

    // Prepare the proposal call
    bytes memory proposalCall = abi.encodeWithSelector(
      LevrGovernor_v1.proposeTransfer.selector,
      address(0x777),
      10e18,
      'Test transfer proposal'
    );

    // Create ERC2771 forward request
    ERC2771Forwarder.ForwardRequestData memory request = ERC2771Forwarder.ForwardRequestData({
      from: user,
      to: project.governor,
      value: 0,
      gas: 300000,
      deadline: uint48(block.timestamp + 1 hours),
      data: proposalCall,
      signature: ''
    });

    // Sign the request
    bytes32 digest = _getDigest(request);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
    request.signature = abi.encodePacked(r, s, v);

    // Relayer executes the meta-transaction
    vm.prank(relayer);
    forwarder.execute(request);

    // Verify proposal was created (ID should be 1)
    ILevrGovernor_v1.Proposal memory proposal = LevrGovernor_v1(project.governor).getProposal(1);
    assertEq(proposal.proposer, user, 'Proposer should be user, not relayer');
  }

  /**
   * @notice Test meta-transaction unstaking flow
   */
  function test_MetaTx_Unstake() public {
    uint256 stakeAmount = 100e18;

    // User stakes directly first
    vm.startPrank(user);
    clankerToken.approve(project.staking, stakeAmount);
    LevrStaking_v1(project.staking).stake(stakeAmount);
    vm.stopPrank();

    // Prepare the unstake call
    bytes memory unstakeCall = abi.encodeWithSelector(LevrStaking_v1.unstake.selector, stakeAmount, user);

    // Create ERC2771 forward request
    ERC2771Forwarder.ForwardRequestData memory request = ERC2771Forwarder.ForwardRequestData({
      from: user,
      to: project.staking,
      value: 0,
      gas: 300000,
      deadline: uint48(block.timestamp + 1 hours),
      data: unstakeCall,
      signature: ''
    });

    // Sign the request
    bytes32 digest = _getDigest(request);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
    request.signature = abi.encodePacked(r, s, v);

    // Relayer executes the meta-transaction
    vm.prank(relayer);
    forwarder.execute(request);

    // Verify unstake was successful
    assertEq(LevrStaking_v1(project.staking).stakedBalanceOf(user), 0);
    assertEq(clankerToken.balanceOf(user), 1000e18); // Back to original balance
  }

  /**
   * @notice Test that isTrustedForwarder works correctly
   */
  function test_IsTrustedForwarder() public {
    // Staking contract should trust the forwarder
    assertTrue(LevrStaking_v1(project.staking).isTrustedForwarder(address(forwarder)));
    assertFalse(LevrStaking_v1(project.staking).isTrustedForwarder(address(0x123)));

    // Governor contract should trust the forwarder
    assertTrue(LevrGovernor_v1(project.governor).isTrustedForwarder(address(forwarder)));

    // Treasury contract should trust the forwarder
    assertTrue(LevrGovernor_v1(project.treasury).isTrustedForwarder(address(forwarder)));
  }

  /**
   * @notice Test complete project deployment via multicall
   * @dev Demonstrates: prepareForDeployment → deploy token → register in ONE transaction using executeMulticall
   *      This is the key benefit of LevrForwarder_v1's executeMulticall support
   */
  function test_MetaTx_Multicall_CompleteDeployment() public {
    // Create a fresh user for this test
    uint256 deployerPrivateKey = 0xDEF1;
    address deployer = vm.addr(deployerPrivateKey);

    // Deploy token that will be registered (deployer is admin)
    vm.prank(deployer);
    MockERC20 newToken = new MockERC20('Multicall Token', 'MULTI');

    // Build the multicall sequence - all executed in ONE transaction without deployer paying gas!
    ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);

    // Call 1: prepareForDeployment
    calls[0] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      callData: abi.encodeWithSelector(LevrFactory_v1.prepareForDeployment.selector)
    });

    // Call 2: register the token
    calls[1] = ILevrForwarder_v1.SingleCall({
      target: address(factory),
      allowFailure: false,
      callData: abi.encodeWithSelector(LevrFactory_v1.register.selector, address(newToken))
    });

    // Execute multicall as the deployer (via relayer paying gas)
    vm.prank(deployer);
    ILevrForwarder_v1.Result[] memory results = forwarder.executeMulticall(calls);

    // Verify all calls succeeded
    assertTrue(results[0].success, 'prepareForDeployment should succeed');
    assertTrue(results[1].success, 'register should succeed');

    // Verify complete project was deployed
    ILevrFactory_v1.Project memory newProject = factory.getProjectContracts(address(newToken));
    assertTrue(newProject.treasury != address(0), 'Treasury should be deployed');
    assertTrue(newProject.governor != address(0), 'Governor should be deployed');
    assertTrue(newProject.staking != address(0), 'Staking should be deployed');
    assertTrue(newProject.stakedToken != address(0), 'StakedToken should be deployed');

    // Verify prepared contracts were used
    ILevrFactory_v1.PreparedContracts memory prepared = _getPreparedContracts(deployer);
    assertEq(newProject.treasury, prepared.treasury, 'Should use prepared treasury');
    assertEq(newProject.staking, prepared.staking, 'Should use prepared staking');

    console.log('=== MULTICALL DEPLOYMENT SUCCESS ===');
    console.log('Deployer (called functions):', deployer);
    console.log('Actions:', 'prepare + register in ONE transaction');
    console.log('Treasury:', newProject.treasury);
    console.log('Governor:', newProject.governor);
    console.log('Staking:', newProject.staking);
    console.log('StakedToken:', newProject.stakedToken);
  }

  // Helper to access prepared contracts (internal mapping)
  function _getPreparedContracts(address deployer) internal view returns (ILevrFactory_v1.PreparedContracts memory) {
    // Use vm.load to read from the mapping
    bytes32 slot = keccak256(abi.encode(deployer, uint256(6))); // _preparedContracts is at slot 6
    address treasury = address(uint160(uint256(vm.load(address(factory), slot))));
    address staking = address(uint160(uint256(vm.load(address(factory), bytes32(uint256(slot) + 1)))));
    return ILevrFactory_v1.PreparedContracts({treasury: treasury, staking: staking});
  }

  // Helper function to get the EIP712 digest for signing
  function _getDigest(ERC2771Forwarder.ForwardRequestData memory request) internal view returns (bytes32) {
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          'ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)'
        ),
        request.from,
        request.to,
        request.value,
        request.gas,
        forwarder.nonces(request.from),
        request.deadline,
        keccak256(request.data)
      )
    );

    // Get domain separator components
    (
      bytes1 fields,
      string memory name,
      string memory version,
      uint256 chainId,
      address verifyingContract,
      bytes32 salt,
      uint256[] memory extensions
    ) = forwarder.eip712Domain();

    bytes32 domainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256(bytes(name)),
        keccak256(bytes(version)),
        chainId,
        verifyingContract
      )
    );

    return keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
  }
}
