// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IPause} from "./IPause.sol";
import {ICDPVault_TypeA} from "./ICDPVault_TypeA.sol";
import {ICDPVault} from "./ICDPVault.sol";
import {IInterestRateModel} from "./IInterestRateModel.sol";

/// @title ICDPVault_TypeB
/// @notice Interface for the CDPVault_TypeB
interface ICDPVault_TypeBBase is ICDPVault_TypeA {

    function creditWithholder() external view returns (address);

    function totalShares() external view returns (uint256);

    function shares(address) external view returns (uint256);

    function totalCreditClaimable() external view returns (uint256);

    function epochs(uint256 epoch) external view returns (uint256, uint256, uint256, uint128, uint128);

    function sharesQueuedByEpoch(uint256 epoch, address delegator) external view returns (uint256);

    function delegateCredit(uint256 creditAmount) external returns (uint256 sharesAmount);

    function undelegateCredit(
        uint256 shareAmount,
        uint256[] memory prevQueuedEpochs
    ) external returns (uint256 creditAmount, uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch);

    function claimUndelegatedCredit(uint256 claimForEpoch) external returns (uint256 creditAmount);
}

/// @title ICDPVault_TypeB
/// @notice Interface for the CDPVault_TypeB
interface ICDPVault_TypeB is ICDPVault_TypeBBase, IInterestRateModel {
    function paused() external view returns (bool);
}