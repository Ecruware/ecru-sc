// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVault} from "../interfaces/ICDPVault.sol";

import {PositionAction, LeverParams} from "./PositionAction.sol";

interface IChai {
    function join(address dst, uint wad) external;
    function exit(address src, uint wad) external;
    function pot() external returns (address);
}

/// @title PositionActionChai
/// @notice Chai implementation of PositionAction base contract
contract PositionActionChai is PositionAction {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address constant CHAI = 0x06AF07097C9Eeb7fD685c692751D5C66dB49c215;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PositionActionChai__onDeposit__invalidSrcToken();
    error PositionActionChai__onIncreaseLever__invalidUpFrontToken();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address flashlender_, address swapActions_) PositionAction(flashlender_, swapActions_) {}

    /*//////////////////////////////////////////////////////////////
                         VIRTUAL IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit collateral into the vault
    /// @param vault Address of the vault
    /// @param src Token passed in by the caller
    /// @param amount Amount of collateral to deposit [wad]
    /// @return Amount of collateral deposited [wad]
    function _onDeposit(address vault, address src, uint256 amount) internal override returns (uint256) {
        // convert any DAI to CHAI
        if (src != CHAI) {
            uint256 balanceBefore = IERC20(CHAI).balanceOf(address(this));
            IERC20(DAI).forceApprove(CHAI, amount);
            IChai(CHAI).join(address(this), amount);
            amount = IERC20(CHAI).balanceOf(address(this)) - balanceBefore;
        }

        IERC20(CHAI).forceApprove(vault, amount);
        return ICDPVault(vault).deposit(address(this), amount);
    }

    /// @notice Withdraw collateral from the vault
    /// @param vault Address of the vault
    /// @param dst Token the caller expects to receive
    /// @param amount Amount of collateral to withdraw [wad]
    /// @return Amount of collateral withdrawn [CDPVault.tokenScale()]
    function _onWithdraw(address vault, address dst, uint256 amount) internal override returns (uint256) {
        uint256 collateralWithdrawn = ICDPVault(vault).withdraw(address(this), amount);

        // if collateral is not the CHAI, we need to convert CHAI to DAI
        if (dst != CHAI) {
            uint256 balanceBefore = IERC20(DAI).balanceOf(address(this));
            IChai(CHAI).exit(address(this), collateralWithdrawn);
            collateralWithdrawn = IERC20(DAI).balanceOf(address(this)) - balanceBefore;
        }

        return collateralWithdrawn;
    }


    /// @notice Hook to increase lever by depositing CHAI into CDPVault
    /// @param leverParams LeverParams struct
    /// @param upFrontToken the token passed up front
    /// @param upFrontAmount the amount of tokens passed up front (DAI or CHAI) [wad]
    /// @param swapAmountOut the amount of tokens received from the stablecoin flash loan swap (Always DAI) [wad]
    /// @return Amount of collateral added to CDPVault position [wad]
    function _onIncreaseLever(
        LeverParams memory leverParams,
        address upFrontToken,
        uint256 upFrontAmount,
        uint256 swapAmountOut
    ) internal override returns (uint256) {
        // check if upfront token is dai or there was an auxswap, if so, treat upFrontAmount as dai
        uint256 addCollateralAmount = swapAmountOut;
        if (upFrontToken == DAI || leverParams.auxSwap.assetIn != address(0)) {
            addCollateralAmount += upFrontAmount;
        }

        // convert dai to chai
        IERC20(DAI).forceApprove(CHAI, addCollateralAmount);
        IChai(CHAI).join(address(this), addCollateralAmount);
        addCollateralAmount = IERC20(CHAI).balanceOf(address(this));

        // deposit CHAI into the CDP vault
        IERC20(CHAI).forceApprove(leverParams.vault, addCollateralAmount);
        return ICDPVault(leverParams.vault).deposit(address(this), addCollateralAmount);
    }

    /// @notice Hook to decrease lever by withdrawing collateral from the CDPVault and exiting CHAI
    /// @param leverParams LeverParams struct
    /// @param subCollateral Amount of collateral to withdraw in CDPVault decimals [wad]
    /// @return Amount of DAI returned from withdrawing CHAI from CDPVault and converting to DAI [wad]
    function _onDecreaseLever(
        LeverParams memory leverParams,
        uint256 subCollateral
    ) internal override returns (uint256) {
        // withdraw collateral from CDPVault
        uint256 withdrawnCollateral = ICDPVault(leverParams.vault).withdraw(address(this), subCollateral);

        // exit CHAI and return DAI amount
        IChai(CHAI).exit(address(this), withdrawnCollateral);
        return IERC20(DAI).balanceOf(address(this));
    }
}
