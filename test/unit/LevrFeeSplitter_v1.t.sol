// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {LevrStaking_v1_Mock} from '../mocks/LevrStaking_v1_Mock.sol';

contract LevrFeeSplitter_v1_Test is Test {
    LevrFeeSplitter_v1 internal _splitter;
    MockClankerToken internal _clanker;
    MockProjectRegistry internal _projectRegistry;
    LevrStaking_v1_Mock internal _staking;

    ERC20_Mock internal _rewardToken;
    ERC20_Mock internal _secondRewardToken;

    address internal _admin = makeAddr('admin');
    address internal _receiverA = makeAddr('receiverA');
    address internal _receiverB = makeAddr('receiverB');

    function setUp() public {
        _clanker = new MockClankerToken(_admin);
        _projectRegistry = new MockProjectRegistry();
        _staking = new LevrStaking_v1_Mock();

        _projectRegistry.setProject(address(0), address(0), address(_staking), address(0), false);

        _splitter = new LevrFeeSplitter_v1(
            address(_clanker),
            address(_projectRegistry),
            address(0)
        );
        _rewardToken = new ERC20_Mock('Reward', 'RWD');
        _secondRewardToken = new ERC20_Mock('Alt Reward', 'ALT');
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Initialization

    /* Test: constructor */
    function test_Constructor_RevertIf_ClankerZero() public {
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        new LevrFeeSplitter_v1(address(0), address(_projectRegistry), address(0));
    }

    function test_Constructor_RevertIf_FactoryZero() public {
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        new LevrFeeSplitter_v1(address(_clanker), address(0), address(0));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test External Functions

    // ========================================================================
    // External - Admin Functions

    /* Test: configureSplits */
    function test_ConfigureSplits_RevertIf_NotTokenAdmin() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = _buildDefaultSplits();

        vm.prank(_receiverA);
        vm.expectRevert(ILevrFeeSplitter_v1.OnlyTokenAdmin.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_InvalidTotalBps() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: _receiverA, bps: 4000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(_staking), bps: 4000});

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.InvalidTotalBps.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_NoReceivers() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](0);

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.NoReceivers.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_TooManyReceivers() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](21);
        for (uint256 i = 0; i < splits.length; i++) {
            address receiver = address(uint160(i + 1));
            uint16 bps = i == splits.length - 1 ? 2000 : 400;
            splits[i] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver, bps: bps});
        }

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.TooManyReceivers.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_DuplicateReceiver() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: _receiverA, bps: 5000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: _receiverA, bps: 5000});

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.DuplicateReceiver.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_DuplicateStakingReceiver() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](3);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: _receiverA, bps: 4000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(_staking), bps: 3000});
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(_staking), bps: 3000});

        vm.prank(_admin);
        // Duplicate staking receivers currently revert via the general duplicate check.
        vm.expectRevert(ILevrFeeSplitter_v1.DuplicateReceiver.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_ZeroBps() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: _receiverA, bps: 0});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(_staking), bps: 10_000});

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroBps.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_ReceiverZeroAddress() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(0), bps: 5_000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(_staking), bps: 5_000});

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_RevertIf_ProjectNotRegistered() public {
        _projectRegistry.setProject(address(0), address(0), address(0), address(0), false);

        ILevrFeeSplitter_v1.SplitConfig[] memory splits = _buildDefaultSplits();

        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.ProjectNotRegistered.selector);
        _splitter.configureSplits(splits);
    }

    function test_ConfigureSplits_Success() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = _buildDefaultSplits();

        vm.expectEmit(true, false, false, true);
        emit ILevrFeeSplitter_v1.SplitsConfigured(address(_clanker), splits);

        vm.prank(_admin);
        _splitter.configureSplits(splits);

        ILevrFeeSplitter_v1.SplitConfig[] memory stored = _splitter.getSplits();
        assertEq(stored.length, 2);
        assertEq(stored[0].receiver, _receiverA);
        assertEq(stored[0].bps, 6000);
    }

    /* Test: recoverDust */
    function test_RecoverDust_RevertIf_NotTokenAdmin() public {
        vm.prank(_receiverA);
        vm.expectRevert(ILevrFeeSplitter_v1.OnlyTokenAdmin.selector);
        _splitter.recoverDust(address(_rewardToken), _receiverA);
    }

    function test_RecoverDust_RevertIf_ToZero() public {
        vm.prank(_admin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        _splitter.recoverDust(address(_rewardToken), address(0));
    }

    function test_RecoverDust_SendsEntireBalance() public {
        _rewardToken.mint(address(_splitter), 50 ether);

        vm.prank(_admin);
        _splitter.recoverDust(address(_rewardToken), _receiverA);

        assertEq(_rewardToken.balanceOf(_receiverA), 50 ether);
        assertEq(_rewardToken.balanceOf(address(_splitter)), 0);
    }

    // ========================================================================
    // External - Distribution

    /* Test: distribute */
    function test_Distribute_RevertIf_SplitsNotConfigured() public {
        _rewardToken.mint(address(_splitter), 1 ether);
        vm.expectRevert(ILevrFeeSplitter_v1.SplitsNotConfigured.selector);
        _splitter.distribute(address(_rewardToken));
    }

    function test_Distribute_RevertIf_TokenNotWhitelisted() public {
        vm.prank(_admin);
        _splitter.configureSplits(_buildDefaultSplits());

        _rewardToken.mint(address(_splitter), 100 ether);

        vm.expectRevert(ILevrFactory_v1.TokenNotTrusted.selector);
        _splitter.distribute(address(_rewardToken));
    }

    function test_Distribute_SendsFundsAndAccruesRewards() public {
        vm.prank(_admin);
        _splitter.configureSplits(_buildDefaultSplits());

        _staking.whitelistToken(address(_rewardToken));
        _rewardToken.mint(address(_splitter), 100 ether);

        vm.expectEmit(true, true, false, true);
        emit ILevrFeeSplitter_v1.FeeDistributed(
            address(_clanker),
            address(_rewardToken),
            _receiverA,
            60 ether
        );

        vm.expectEmit(true, true, false, true);
        emit ILevrFeeSplitter_v1.StakingDistribution(
            address(_clanker),
            address(_rewardToken),
            40 ether
        );

        vm.expectEmit(true, false, false, true);
        emit ILevrFeeSplitter_v1.AutoAccrualSuccess(address(_clanker), address(_rewardToken));

        _splitter.distribute(address(_rewardToken));

        assertEq(_rewardToken.balanceOf(_receiverA), 60 ether);
        assertEq(_rewardToken.balanceOf(address(_staking)), 40 ether);

        ILevrFeeSplitter_v1.DistributionState memory state = _splitter.getDistributionState(
            address(_rewardToken)
        );
        assertEq(state.totalDistributed, 100 ether);
        assertEq(state.lastDistribution, block.timestamp);
    }

    function test_Distribute_EmitsAutoAccrualFailedWhenStakingReverts() public {
        vm.prank(_admin);
        _splitter.configureSplits(_buildDefaultSplits());

        _staking.whitelistToken(address(_rewardToken));
        _staking.setShouldRevertOnAccrue(true);
        _rewardToken.mint(address(_splitter), 10 ether);

        vm.expectEmit(true, false, false, true);
        emit ILevrFeeSplitter_v1.AutoAccrualFailed(address(_clanker), address(_rewardToken));

        _splitter.distribute(address(_rewardToken));
    }

    /* Test: distributeBatch */
    function test_DistributeBatch_DistributesEachToken() public {
        vm.prank(_admin);
        _splitter.configureSplits(_buildDefaultSplits());

        _staking.whitelistToken(address(_rewardToken));
        _staking.whitelistToken(address(_secondRewardToken));

        _rewardToken.mint(address(_splitter), 50 ether);
        _secondRewardToken.mint(address(_splitter), 80 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(_rewardToken);
        tokens[1] = address(_secondRewardToken);

        _splitter.distributeBatch(tokens);

        assertEq(_rewardToken.balanceOf(_receiverA), 30 ether);
        assertEq(_secondRewardToken.balanceOf(_receiverA), 48 ether);
    }

    // ========================================================================
    // External - View Functions

    /* Test: getTotalBps */
    function test_GetTotalBps_ReturnsSum() public {
        vm.prank(_admin);
        _splitter.configureSplits(_buildDefaultSplits());

        assertEq(_splitter.getTotalBps(), 10_000);
    }

    function test_IsSplitsConfigured_ReturnsFalseUntilConfigured() public view {
        assertFalse(_splitter.isSplitsConfigured());
    }

    ///////////////////////////////////////////////////////////////////////////
    // Helper Functions

    function _buildDefaultSplits()
        internal
        view
        returns (ILevrFeeSplitter_v1.SplitConfig[] memory splits)
    {
        splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: _receiverA, bps: 6000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(_staking), bps: 4000});
    }
}

contract MockClankerToken is ERC20_Mock {
    address private immutable _admin;

    constructor(address admin_) ERC20_Mock('Clanker', 'CLNK') {
        _admin = admin_;
    }

    function admin() external view override returns (address) {
        return _admin;
    }
}

contract MockProjectRegistry {
    ILevrFactory_v1.Project private _project;

    function setProject(
        address treasury,
        address governor,
        address staking,
        address stakedToken,
        bool verified
    ) external {
        _project = ILevrFactory_v1.Project({
            treasury: treasury,
            governor: governor,
            staking: staking,
            stakedToken: stakedToken,
            verified: verified
        });
    }

    function getProject(address) external view returns (ILevrFactory_v1.Project memory) {
        return _project;
    }
}
