// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {ICDPVault_TypeB} from "./ICDPVault_TypeB.sol";
import {ICDPVaultUnwinder} from "./ICDPVaultUnwinder.sol";

interface ICDPVaultUnwinderFactory {

    function deployVaultUnwinder(ICDPVault_TypeB vault) external returns (ICDPVaultUnwinder unwinder);
}