// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILevrFactory_v1} from "./interfaces/ILevrFactory_v1.sol";
import {ILevrTreasury_v1} from "./interfaces/ILevrTreasury_v1.sol";

import {LevrTreasury_v1} from "./LevrTreasury_v1.sol";
import {LevrGovernor_v1} from "./LevrGovernor_v1.sol";
import {LevrERC20} from "./LevrERC20.sol";

contract LevrFactory_v1 is ILevrFactory_v1, Ownable {
    uint16 public override protocolFeeBps;
    uint32 public override submissionDeadlineSeconds;
    uint16 public override maxSubmissionPerType; // reserved for future rate limits
    uint256 public override minWTokenToSubmit;
    address public override protocolTreasury;

    uint256[] private _transferTiers;
    uint256[] private _stakingBoostTiers;

    struct Project {
        address treasury;
        address governor;
        address wrapper;
    }

    mapping(address => Project) private _projects; // clankerToken => Project

    constructor(FactoryConfig memory cfg, address owner_) Ownable(owner_) {
        _applyConfig(cfg);
    }

    /// @inheritdoc ILevrFactory_v1
    function register(
        address clankerToken,
        RegisterParams calldata params
    ) external override returns (address governor, address wrapper) {
        Project storage p = _projects[clankerToken];
        require(p.wrapper == address(0), "ALREADY_REGISTERED");

        address treasury = params.treasury;
        if (treasury == address(0)) {
            treasury = address(
                new LevrTreasury_v1(clankerToken, address(this))
            );
        }

        uint8 uDec = IERC20Metadata(clankerToken).decimals();
        string memory name_ = string(
            abi.encodePacked(
                "Levr Wrapped ",
                IERC20Metadata(clankerToken).name()
            )
        );
        string memory symbol_ = string(
            abi.encodePacked("w", IERC20Metadata(clankerToken).symbol())
        );
        wrapper = address(
            new LevrERC20(name_, symbol_, uDec, clankerToken, treasury)
        );
        governor = address(
            new LevrGovernor_v1(address(this), treasury, wrapper)
        );

        LevrTreasury_v1(treasury).initialize(governor, wrapper);

        p.treasury = treasury;
        p.governor = governor;
        p.wrapper = wrapper;

        emit Registered(clankerToken, treasury, governor, wrapper);
    }

    /// @inheritdoc ILevrFactory_v1
    function updateConfig(
        FactoryConfig calldata cfg
    ) external override onlyOwner {
        _applyConfig(cfg);
        emit ConfigUpdated();
    }

    /// @inheritdoc ILevrFactory_v1
    function getProjectContracts(
        address clankerToken
    )
        external
        view
        override
        returns (address treasury, address governor, address wrapper)
    {
        Project storage p = _projects[clankerToken];
        return (p.treasury, p.governor, p.wrapper);
    }

    /// @inheritdoc ILevrFactory_v1
    function getTransferTierCount() external view override returns (uint256) {
        return _transferTiers.length;
    }

    /// @inheritdoc ILevrFactory_v1
    function getTransferTier(
        uint256 index
    ) external view override returns (uint256) {
        return _transferTiers[index];
    }

    /// @inheritdoc ILevrFactory_v1
    function getStakingBoostTierCount()
        external
        view
        override
        returns (uint256)
    {
        return _stakingBoostTiers.length;
    }

    /// @inheritdoc ILevrFactory_v1
    function getStakingBoostTier(
        uint256 index
    ) external view override returns (uint256) {
        return _stakingBoostTiers[index];
    }

    function _applyConfig(FactoryConfig memory cfg) internal {
        protocolFeeBps = cfg.protocolFeeBps;
        submissionDeadlineSeconds = cfg.submissionDeadlineSeconds;
        maxSubmissionPerType = cfg.maxSubmissionPerType;
        minWTokenToSubmit = cfg.minWTokenToSubmit;
        protocolTreasury = cfg.protocolTreasury;

        delete _transferTiers;
        delete _stakingBoostTiers;
        uint256 i;
        for (i = 0; i < cfg.transferTiers.length; i++) {
            _transferTiers.push(cfg.transferTiers[i].value);
        }
        for (i = 0; i < cfg.stakingBoostTiers.length; i++) {
            _stakingBoostTiers.push(cfg.stakingBoostTiers[i].value);
        }
    }
}
