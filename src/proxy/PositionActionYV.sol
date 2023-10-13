// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYVault} from "../vendor/IYVault.sol";

import {ICDPVault} from "../interfaces/ICDPVault.sol";

import {PositionAction, LeverParams} from "./PositionAction.sol";

/// @title PositionActionYV
/// @notice Yearn Vault version 0.4.6 implementation of PositionAction base contract
contract PositionActionYV is PositionAction {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address flashlender_, address swapActions_, address PoolAction_) PositionAction(flashlender_, swapActions_, PoolAction_) {}

    /*//////////////////////////////////////////////////////////////
                         VIRTUAL IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit collateral into the vault
    /// @param vault Address of the vault
    /// @param src Token passed in by the caller
    /// @param amount Amount of collateral to deposit [CDPVault.tokenScale()]
    /// @return Amount of collateral deposited [wad]
    function _onDeposit(address vault, address src, uint256 amount) internal override returns (uint256) {
        address collateral = address(ICDPVault(vault).token());

        // if the src is not the collateralToken, we need to deposit the underlying into the yVault
        if (src != collateral) {
            address underlying = IYVault(collateral).token();
            IERC20(underlying).forceApprove(collateral, amount);
            amount = IYVault(collateral).deposit(amount);
        }

        IERC20(collateral).forceApprove(vault, amount);
        return ICDPVault(vault).deposit(address(this), amount);
    }

    /// @notice Withdraw collateral from the vault
    /// @param vault Address of the vault
    /// @param dst Token the caller expects to receive
    /// @param amount Amount of collateral to withdraw [wad]
    /// @return Amount of collateral withdrawn [CDPVault.tokenScale()]
    function _onWithdraw(address vault, address dst, uint256 amount) internal override returns (uint256) {
        uint256 collateralWithdrawn = ICDPVault(vault).withdraw(address(this), amount);

        // if collateral is not the dst token, we need to withdraw the underlying from the yVault
        address collateral = address(ICDPVault(vault).token());
        if (dst != collateral) {
            collateralWithdrawn = IYVault(collateral).withdraw(collateralWithdrawn);
        }

        return collateralWithdrawn;
    }


    /// @notice Hook to decrease lever by depositing collateral into the Yearn Vault and the Yearn Vault
    /// @param leverParams LeverParams struct
    /// @param upFrontToken the token passed up front
    /// @param upFrontAmount the amount of tokens passed up front (or received from an auxSwap [CDPVault.tokenScale()]
    /// @param swapAmountOut the amount of tokens received from the stablecoin flash loan swap [CDPVault.tokenScale()]
    /// @return Amount of collateral added to CDPVault position [wad]
    function _onIncreaseLever(
        LeverParams memory leverParams,
        address upFrontToken,
        uint256 upFrontAmount,
        uint256 swapAmountOut
    ) internal override returns (uint256) {
        uint256 upFrontCollateral; // amount of yvVault tokens to deposit
        uint256 addCollateralAmount = swapAmountOut; // amount to convert to yvVault tokens and then deposit in CDPVault

        if (leverParams.collateralToken == upFrontToken && leverParams.auxSwap.assetIn == address(0)) {
            // if there was no aux swap then treat this amount as the yvault token
            upFrontCollateral = upFrontAmount;
        } else {
            // otherwise treat as the yvault token underlying
            addCollateralAmount += upFrontAmount;
        }
        
        // deposit into the yearn vault
        address underlyingToken = IYVault(leverParams.collateralToken).token();
        IERC20(underlyingToken).forceApprove(leverParams.collateralToken, addCollateralAmount);
        addCollateralAmount = IYVault(leverParams.collateralToken).deposit(addCollateralAmount) + upFrontCollateral;

        // deposit into the CDP vault
        IERC20(leverParams.collateralToken).forceApprove(leverParams.vault, addCollateralAmount);
        return ICDPVault(leverParams.vault).deposit(address(this), addCollateralAmount);
    }

    /// @notice Hook to decrease lever by withdrawing collateral from the CDPVault and the Yearn Vault
    /// @param leverParams LeverParams struct
    /// @param subCollateral Amount of collateral to withdraw in CDPVault decimals [wad]
    /// @return Amount of underlying token withdrawn from yearn vault [CDPVault.tokenScale()]
    function _onDecreaseLever(
        LeverParams memory leverParams,
        uint256 subCollateral
    ) internal override returns (uint256) {
        // withdraw collateral from vault
        uint256 withdrawnCollateral = ICDPVault(leverParams.vault).withdraw(address(this), subCollateral);

        // withdraw collateral from yearn vault and return underlying assets
        return IYVault(leverParams.collateralToken).withdraw(withdrawnCollateral);
    }
}
