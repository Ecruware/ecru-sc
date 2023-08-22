// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICDM} from "./ICDM.sol";
import {IOracle} from "./IOracle.sol";
import {IBuffer} from "./IBuffer.sol";

// Deployment related structs
struct CDPVaultConstants {
    ICDM cdm;
    IOracle oracle;
    IBuffer buffer;
    IERC20 token;
    uint256 tokenScale;
    uint256 protocolFee;
    uint64 targetUtilizationRatio;
    uint64 maxUtilizationRatio;
    uint64 minInterestRate;
    uint64 maxInterestRate;
    uint64 targetInterestRate;
    uint128 rebateRate;
    uint128 maxRebate;
}

struct CDPVaultConfig {
    uint128 debtFloor;
    uint256 limitOrderFloor;
    uint64 liquidationRatio;
    uint64 globalLiquidationRatio;
    uint256 baseRate;
    address roleAdmin;
    address vaultAdmin;
    address tickManager;
    address pauseAdmin;
}

struct CDPVault_TypeAConfig {
    uint64 liquidationPenalty;
    uint64 liquidationDiscount;
    uint64 targetHealthFactor;
}

interface ICDPVault_TypeA_Factory {
    function create(
        CDPVaultConstants memory cdpVaultConstants,
        CDPVault_TypeAConfig memory cdpVaultTypeAConfig,
        CDPVaultConfig memory cdpVaultConfig,
        uint256 debtCeiling
    ) external returns (address);

    function getConstants() external returns (
        ICDM cdm,
        IOracle oracle,
        IBuffer buffer,
        IERC20 token,
        uint256 tokenScale,
        uint256 protocolFee,
        uint256 utilizationParams,
        uint256 rebateParams
    );
}
