// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ICDPVault_TypeA} from "./interfaces/ICDPVault_TypeA.sol";

import {WAD, max, min, wmul, wdiv} from "./utils/Math.sol";

import {CDPVault, VAULT_CONFIG_ROLE, calculateDebt} from "./CDPVault.sol";

/// @title CDPVault_TypeA
/// @notice A CDP-style vault for depositing collateral and drawing credit against it.
/// TypeA vaults are liquidated permissionlessly by selling as much collateral of an unsafe position until it meets
/// a targeted collateralization ratio again. Any shortfall from liquidation not being able to be recovered
/// by selling the available collateral is covered by the global Buffer.
contract CDPVault_TypeA is CDPVault, ICDPVault_TypeA {

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct LiquidationConfig {
        // is subtracted from the `repayAmount` to avoid profitable self liquidations [wad]
        // defined as: 1 - penalty (e.g. `liquidationPenalty` = 0.95 is a 5% penalty)
        uint64 liquidationPenalty;
        // is subtracted from the `spotPrice` of the collateral to provide incentive to liquidate unsafe positions [wad]
        // defined as: 1 - discount (e.g. `liquidationDiscount` = 0.95 is a 5% discount)
        uint64 liquidationDiscount;
        // the targeted health factor an unsafe position has to meet after being partially liquidation [wad]
        // defined as: > 1.0 (e.g. `targetHealthFactor` = 1.05, `liquidationRatio` = 125% provides a cushion of 6.25%) 
        uint64 targetHealthFactor;
    }
    /// @notice Liquidation configuration
    LiquidationConfig public liquidationConfig;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SetParameter(bytes32 indexed parameter, uint256 data);
    event LiquidatePosition(
        address indexed position,
        uint256 collateralReleased,
        uint256 normalDebtRepaid,
        address indexed liquidator
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVault__setParameter_unrecognizedParameter();
    error CDPVault__liquidatePosition_notUnsafe();
    error CDPVault__liquidatePositions_argLengthMismatch();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address factory) CDPVault(factory) {}

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParameter(bytes32 parameter, uint256 data) external whenNotPaused onlyRole(VAULT_CONFIG_ROLE) {
        if (parameter == "debtFloor") vaultConfig.debtFloor = uint128(data);
        else if (parameter == "liquidationRatio") vaultConfig.liquidationRatio = uint64(data);
        else if (parameter == "globalLiquidationRatio") vaultConfig.globalLiquidationRatio = uint64(data);
        else if (parameter == "limitOrderFloor") limitOrderFloor = data;
        // type(uint256).max is used to represent -1, which will indicate that the utilization based interest model
        // is used instead of the static rate interest rate model
        else if (parameter == "baseRate") _setBaseRate((data == type(uint256).max) ? -1 : int64(uint64(data)));
        else if (parameter == "liquidationPenalty") liquidationConfig.liquidationPenalty = uint64(data);
        else if (parameter == "liquidationDiscount") liquidationConfig.liquidationDiscount = uint64(data);
        else if (parameter == "targetHealthFactor") liquidationConfig.targetHealthFactor = uint64(data);
        else revert CDPVault__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidates multiple unsafe positions by selling as much collateral as required to cover the debt in
    /// order to make the positions safe again. The collateral can be bought at a discount (`liquidationDiscount`) to
    /// the current spot price. The liquidator has to provide the amount he wants repay or sell (`repayAmounts`) for
    /// each position. From that repay amount a penalty (`liquidationPenalty`) is subtracted to mitigate against
    /// profitable self liquidations. If the available collateral of a position is not sufficient to cover the debt
    /// the vault is able to apply for a bail out from the global Buffer.
    /// @dev The liquidator has to approve the vault to transfer the sum of `repayAmounts`.
    /// @param owners Owners of the positions to liquidate
    /// @param repayAmounts Amounts the liquidator wants to repay for each position [wad]
    function liquidatePositions(address[] calldata owners, uint256[] memory repayAmounts) external whenNotPaused {
        if (owners.length != repayAmounts.length) revert CDPVault__liquidatePositions_argLengthMismatch();

        GlobalIRS memory globalIRS = getGlobalIRS();
        VaultConfig memory vaultConfig_ = vaultConfig;
        LiquidationConfig memory liquidationConfig_ = liquidationConfig;
        uint256 spotPrice_ = spotPrice();

        ExchangeCache memory cache;
        cache.globalIRS = globalIRS;
        cache.totalNormalDebt = totalNormalDebt;
        cache.debtFloor = vaultConfig.debtFloor;
        cache.settlementRate = wmul(spotPrice_, liquidationConfig.liquidationDiscount);
        cache.settlementPenalty = liquidationConfig.liquidationPenalty;

        uint64 rateAccumulator = _calculateRateAccumulator(globalIRS, cache.totalNormalDebt);

        for (uint256 i; i < owners.length; ) {
            address owner = owners[i];
            if (!(owner == address(0) || repayAmounts[i] == 0)) {
                Position memory position = positions[owner];
                PositionIRS memory positionIRS = _getUpdatedPositionIRS(owner, position.normalDebt, rateAccumulator);

                // calculate position debt and collateral value
                uint256 debt = calculateDebt(position.normalDebt, rateAccumulator, positionIRS.accruedRebate);

                // verify that the position is indeed unsafe
                if (spotPrice_ == 0 || _isCollateralized(
                    debt, position.collateral, spotPrice_, vaultConfig_.liquidationRatio
                )) revert CDPVault__liquidatePosition_notUnsafe();

                // calculate the max. amount of debt we can recover with the position's collateral in order to move
                // the health factor back to the target health factor
                uint256 maxDebtToRecover;
                {
                uint256 nominator;
                {
                uint256 collateralValue = wdiv(wmul(position.collateral, spotPrice_), vaultConfig_.liquidationRatio);
                nominator = wmul(liquidationConfig_.targetHealthFactor, debt) - collateralValue;
                }
                uint256 discountRatio = wmul(vaultConfig_.liquidationRatio, liquidationConfig_.liquidationDiscount);
                uint256 denominator = wmul(liquidationConfig_.targetHealthFactor, cache.settlementPenalty)
                    - wdiv(WAD, discountRatio);
                maxDebtToRecover = wdiv(nominator, denominator);
                }

                // limit the repay amount by max. amount of debt to recover
                cache.maxCreditToExchange = min(repayAmounts[i], wdiv(maxDebtToRecover, cache.settlementPenalty));

                // liquidate the position
                cache = _settleDebtAndReleaseCollateral(cache, position, positionIRS, owner);
            }

            unchecked { ++i; }
        }

        // check if the vault entered emergency mode, store the new cached global interest rate state and collect fees
        _checkForEmergencyModeAndStoreGlobalIRSAndCollectFees(
            cache.globalIRS,
            cache.accruedInterest + wmul(cache.creditExchanged, WAD - cache.settlementPenalty),
            cache.totalNormalDebt,
            spotPrice_,
            vaultConfig_.globalLiquidationRatio
        );
   
        // store the new cached total normalized debt
        totalNormalDebt = cache.totalNormalDebt;

        // transfer the repay amount from the liquidator to the vault
        cdm.modifyBalance(msg.sender, address(this), cache.creditExchanged);

        // transfer the cash amount from the vault to the liquidator
        cash[msg.sender] += cache.collateralExchanged;

        // try absorbing any accrued bad debt by applying for a bail out and mark down the residual bad debt
        if (cache.accruedBadDebt != 0) {
            // apply for a bail out from the Buffer
            buffer.bailOut(cache.accruedBadDebt); 
        }
    }
}
