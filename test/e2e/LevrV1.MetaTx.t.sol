// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import 'forge-std/Test.sol';
import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

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
  ERC2771Forwarder forwarder;
  MockERC20 clankerToken;

  ILevrFactory_v1.Project project;

  address owner = address(0x1);
  address relayer = address(0x2);

  // User that will sign meta-transactions
  uint256 userPrivateKey = 0xA11CE;
  address user;

  function setUp() public {
    user = vm.addr(userPrivateKey);

    // Deploy factory (forwarder is deployed automatically in constructor)
    ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
      protocolFeeBps: 100,
      submissionDeadlineSeconds: 7 days,
      maxSubmissionPerType: 0,
      streamWindowSeconds: 3 days,
      minWTokenToSubmit: 100e18,
      protocolTreasury: address(0x999)
    });

    vm.prank(owner);
    factory = new LevrFactory_v1(cfg, owner);

    // Get the deployed forwarder
    forwarder = ERC2771Forwarder(factory.trustedForwarder());

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
