
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPermission} from "../interfaces/IPermission.sol";
import {ICDPVault_TypeB} from "../interfaces/ICDPVault_TypeB.sol";

import {toInt256, wmul} from "../utils/Math.sol";

import {PositionAction, CollateralParams, PermitParams, CreditParams} from "./PositionAction.sol";
import {SwapParams} from "./SwapAction.sol";

/// @title PositionAction_TypeB
/// @notice Contract that adds delegate and undelegate functionality to PositionAction
/// @dev This contract is designed to be called via a proxy contract and can be dangerous to call directly
///      This contract does not support fee-on-transfer tokens
abstract contract PositionAction_TypeB is PositionAction {
    
    /// @notice Delegates credit to `vault`
    /// @dev Wrapper function around CDPVault.delegateCredit()
    /// @param creditAmount Amount of credit to delegate [wad]
    /// @return sharesAmount Amount of shares issued [wad]
    function delegate(address vault, uint256 creditAmount) public returns (uint256 sharesAmount) {
        cdm.modifyPermission(vault, true);
        sharesAmount = ICDPVault_TypeB(vault).delegateCredit(creditAmount);
        cdm.modifyPermission(vault, false);
    }

    /// @notice Undelegate credit from a vault
    /// @dev Wrapper function around CDPVault.undelegateCredit()
    /// @dev This function does not have the onlyDelegatecall modifier to save gas but should only be called via Proxy
    /// @param shareAmount Amount of shares to redeem [wad]
    /// @param prevQueuedEpochs Array of stale epochs for which shares were queued
    /// @return estimatedClaim Estimated amount of withdrawable credit, if no bad debt is accrued [wad]
    /// @return epoch Epoch at which the undelegation was initiated
    /// @return claimableAtEpoch Epoch at which the undelegated credit can be claimed by the delegator
    /// @return fixableUntilEpoch Epoch at which the credit claim of the epoch has to be fixed by
    function undelegate(address vault, uint256 shareAmount, uint256[] calldata prevQueuedEpochs) external returns (
        uint256 estimatedClaim, uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
    ) {
        return ICDPVault_TypeB(vault).undelegateCredit(shareAmount, prevQueuedEpochs);
    }

    /// @notice Claim undelegated credit from a vault
    /// @dev Wrapper function around CDPVault.claimUndelegatedCredit()
    /// @dev This function does not have the onlyDelegatecall modifier to save gas but should only be called via Proxy
    /// @param vault The CDP Vault
    /// @param claimForEpoch The epoch to claim undelegatedCredit for
    /// @return creditAmount Amount of credit claimed [wad]
    function claimUndelegatedCredit(address vault, uint256 claimForEpoch) external returns (uint256 creditAmount) {
        creditAmount = ICDPVault_TypeB(vault).claimUndelegatedCredit(claimForEpoch);
    }

    /// @notice Adds collateral and delegates credit to a vault
    /// @param position The CDP Vault position
    /// @param depositVault The CDP Vault to deposit collateral into
    /// @param delegateVault The CDP Vault to delegate credit to
    /// @param credit The amount of credit to delegate
    /// @param collateralParams The collateral parameters
    /// @param permitParams The permit parameters
    function depositAndDelegate(
        address position,
        address depositVault,
        address delegateVault,
        uint256 credit,
        CollateralParams calldata collateralParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        uint256 collateral = _deposit(depositVault, collateralParams, permitParams);
        uint256 addNormalDebt = _debtToNormalDebt(depositVault, position, credit);
        ICDPVault_TypeB(depositVault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            toInt256(collateral),
            toInt256(addNormalDebt)
        );
        delegate(delegateVault, credit);
    }

    /// @notice Swap for stablecoin or transfer stablecoin directly, then delegate to a vault
    /// @param creditor The address to transfer stablecoin or swap tokens from
    /// @param vault The CDP Vault to delegate credit to
    /// @param credit The amount of credit to delegate [wad]
    /// @param swapParams The swap parameters for swapping an arbitrary asset to stablecoin
    /// @param permitParams The permit parameters
    function delegateViaStablecoin(
        address creditor,
        address vault,
        uint256 credit,
        SwapParams calldata swapParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        // perform swap from arbitrary token to Stablecoin
        if (swapParams.assetIn != address(0)) {
            if (swapParams.recipient != address(this)) revert PositionAction__delegateViaStablecoin_InvalidAuxSwap();
            credit = _transferAndSwap(creditor, swapParams, permitParams);
        } else if (creditor != address(this)) {
            // otherwise just transfer Stablecoin directly from creditor
            _transferFrom(
                address(stablecoin),
                creditor,
                address(this),
                credit,
                permitParams
            );
        }

        // transfer stablecoin to credit
        stablecoin.approve(address(minter), credit);
        minter.enter(address(this), credit);

        // then delegate the credit
        delegate(vault, credit);
    }

    /// @notice Undelegate credit from a vault and withdraw collateral from a vault
    /// @param position The CDP Vault position
    /// @param withdrawVault The CDP Vault to withdraw collateral from
    /// @param delegateVault The CDP Vault to undelegate credit from
    /// @param claimForEpoch The epoch to claim undelegatedCredit for
    /// @param subNormalDebt The amount of normal debt to repay [wad]
    /// @param collateralParams The collateral parameters for collateral withdrawal
    function withdrawAndClaim(
        address position,
        address withdrawVault,
        address delegateVault,
        uint256 claimForEpoch,
        uint256 subNormalDebt,
        CollateralParams calldata collateralParams
    ) external onlyDelegatecall {
        ICDPVault_TypeB(delegateVault).claimUndelegatedCredit(claimForEpoch);
        cdm.modifyPermission(position, withdrawVault, true);
        ICDPVault_TypeB(withdrawVault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            -toInt256(collateralParams.amount),
            -toInt256(subNormalDebt)
        );
        cdm.modifyPermission(position, withdrawVault, false);
        _withdraw(withdrawVault, collateralParams);
    }

    /// @notice Undelegate and then repay a position
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param claimForEpoch The epoch to claim undelegatedCredit for
    /// @param subNormalDebt The amount of normal debt to repay [wad]
    /// @param creditParams The credit parameters for debt repayment
    /// @param permitParams The permit parameters
    function repayAndClaim(
        address position,
        address vault,
        uint256 claimForEpoch,
        uint256 subNormalDebt,
        CreditParams calldata creditParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        _repay(position, vault, creditParams, permitParams);
        ICDPVault_TypeB(vault).claimUndelegatedCredit(claimForEpoch);
        IPermission(address(cdm)).modifyPermission(position, vault, true);
        ICDPVault_TypeB(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            0,
            -toInt256(creditParams.amount + subNormalDebt)
        );
        IPermission(address(cdm)).modifyPermission(position, vault, false);
    }
}