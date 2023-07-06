// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ICDM} from "./interfaces/ICDM.sol";

/// @title CreditWithholder
/// @notice Credit account for the vault. Used for:
/// - temp. withholding an estimated amount of credit for epochs for which the exact credit claim hasn't been fixed yet
/// - temp. storing the fixed credit claim for epochs until the (un)delegators withdraw it
contract CreditWithholder {
    constructor(ICDM cdm, address unwinderFactory, address vault) {
        // allow the deployer and the CDPVaultUnwinderFactory to transfer credit on behalf of this contract
        cdm.modifyPermission(vault, true);
        cdm.modifyPermission(unwinderFactory, true);
    }
}
