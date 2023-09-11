// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICDM} from "./ICDM.sol";
import {IOracle} from "./IOracle.sol";
import {IBuffer} from "./IBuffer.sol";
import {ICDPVault_FactoryBase, CDPVaultConstants, CDPVaultConfig} from "./ICDPVault_FactoryBase.sol";

struct CDPVault_TypeBConfig {
    uint64 liquidationPenalty;
    uint64 liquidationDiscount;
    uint64 targetHealthFactor;
    address vaultUnwinder;
}

interface ICDPVault_TypeB_Factory is ICDPVault_FactoryBase {
    function create(
        CDPVaultConstants memory cdpVaultConstants,
        CDPVault_TypeBConfig memory cdpVaultTypeBConfig,
        CDPVaultConfig memory cdpVaultConfig,
        uint256 debtCeiling
    ) external returns (address);

    function creditWithholder() external returns (address);
}
