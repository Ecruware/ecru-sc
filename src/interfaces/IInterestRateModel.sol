// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

interface IInterestRateModel {

    function getGlobalIRS() external view returns (int64, uint64, uint64, uint64, uint256);

    function getPositionIRS(address position) external view returns (uint64, uint64, uint128);
}
