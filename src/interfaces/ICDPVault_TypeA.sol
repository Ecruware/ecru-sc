// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {ICDPVaultBase} from "./ICDPVault.sol";

/// @title ICDPVault_TypeA
/// @notice Interface for the CDPVault_TypeA
interface ICDPVault_TypeA is ICDPVaultBase {

    function setParameter(bytes32 parameter, uint256 data) external;

    function liquidationConfig() external view returns (uint64, uint64, uint64);

    function liquidatePositions(address[] calldata owners, uint256[] memory repayAmounts) external;
}
