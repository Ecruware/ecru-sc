// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {WAD, add, wmul, wdiv, wpow} from "./utils/Math.sol";

abstract contract InterestRateModel {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Max. allowed per second base interest rate (200%, assuming 366 days per year) [wad]
    int64 constant internal RATE_CEILING = 1000000021919499726;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Interest Rate State
    struct GlobalIRS {
        // Base rate from which the rateAccumulator is derived [wad]
        // - positive it`s used as a static annualized per-second interest rate (expected to be between 0 and 1)
        // - negative it will activate the utilization-based per-second interest rate model
        int64 baseRate;
        // Last time the interest rate state was updated (up to year 2554) [seconds]
        uint64 lastUpdated;
        // Interest rate accumulator - used for calculating accrued interest [wad]
        uint64 rateAccumulator;
        // Average rebate factor over all positions [wad]
        uint256 averageRebate;
        // Global accrued rebate [wad]
        uint256 globalAccruedRebate;
    }
    /// @notice Global interest rate state
    GlobalIRS private _globalIRS;

    struct PositionIRS {
        // Snapshot of GlobalIRS.rateAccumulator from the previous PositionIRS update [wad]
        uint64 snapshotRateAccumulator;
        // Rebate factor - used for calc. the average rebate and the accrued rebate (between 0 and 1 WAD) [wad]
        uint64 rebateFactor;
        // Accrued rebate of the position [wad]
        uint128 accruedRebate;
    }
    /// @notice Interest rate state of each position
    mapping(address position => PositionIRS) private _positionIRS;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SetBaseRate(int64 baseRate);
    event SetGlobalIRS();
    event SetPositionIRS(address position);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InterestRateModel__setBaseRate_invalidBaseRate();

    /*//////////////////////////////////////////////////////////////
                           GETTER AND SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Populates the initial values of the PositionIRS if it hasn't been initialized yet
    function _checkPositionIRS(PositionIRS memory positionIRS) private pure returns (PositionIRS memory) {
        if (positionIRS.snapshotRateAccumulator == 0) {
            positionIRS.rebateFactor = 0;
            positionIRS.snapshotRateAccumulator = uint64(WAD);
            positionIRS.accruedRebate = 0;
        }
        return positionIRS;
    }

    /// @notice Returns the global interest rate state
    /// @return _ Global interest rate state
    function getGlobalIRS() public view returns (GlobalIRS memory) {
        return _globalIRS;
    }

    /// @notice Returns the interest rate state of a position
    /// @param position Address of position (owner)
    /// @return _ Interest rate state of the position
    function getPositionIRS(address position) public view returns (PositionIRS memory) {
        return _checkPositionIRS(_positionIRS[position]);
    }

    /// @notice Sets the global interest rate state
    /// @param globalIRS New global interest rate state
    function _setGlobalIRS(GlobalIRS memory globalIRS) internal {
        _globalIRS = globalIRS;
        emit SetGlobalIRS();
    }

    /// @notice Sets the interest rate state of a position
    /// @param position Address of position (owner)
    /// @param positionIRS New interest rate state of the position
    function _setPositionIRS(address position, PositionIRS memory positionIRS) internal {
        _positionIRS[position] = positionIRS;
        emit SetPositionIRS(position);
    }

    /// @notice Sets the base interest rate
    /// @param baseRate New base interest rate [wad]
    function _setBaseRate(int64 baseRate) internal {
        if (baseRate > 0 && baseRate < int64(uint64(WAD)) || baseRate > RATE_CEILING)
            revert InterestRateModel__setBaseRate_invalidBaseRate();
        _globalIRS.baseRate = baseRate;
        emit SetBaseRate(baseRate);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEREST ACCOUNTING MATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the global rate accumulator
    /// @param globalIRS Current global interest rate state
    /// @param baseRate Current base rate [wad]
    /// @return rateAccumulator New global rate accumulator [wad]
    function _calculateRateAccumulator(
        GlobalIRS memory globalIRS, uint64 baseRate
    ) internal view returns (uint64 rateAccumulator) {
        unchecked {
            rateAccumulator = uint64(wmul(
                globalIRS.rateAccumulator,
                wpow(uint256(baseRate), (block.timestamp - globalIRS.lastUpdated), WAD)
            ));
        }
    }

    /// @notice Calculate the rebate amount to claim based on the debt amount to repay
    /// and deduct it from the accrued rebate
    function _calculateRebateClaim(
        uint256 subDebt, uint256 debt, uint128 accruedRebate
    ) internal pure returns (uint128 claimedRebate, uint128 accruedRebate_) {
        accruedRebate_ = accruedRebate;
        if (subDebt != 0 && debt != 0) {
            // claimed rebate is proportional to the repaid normalized debt
            claimedRebate = uint128(subDebt * accruedRebate / debt);
            accruedRebate_ -= claimedRebate;
        }
    }

    /// @notice Calculates a position's accrued rebate
    /// @param positionIRS Interest rate state of the position (before any updates)
    /// @param rateAccumulator Current rate accumulator [wad]
    /// @param normalDebt Normalized debt of the position [wad]
    /// @return accruedRebate Updated accrued rebate of the position [wad]
    function _calculateAccruedRebate(
        PositionIRS memory positionIRS, uint64 rateAccumulator, uint256 normalDebt
    ) internal pure returns(uint128 accruedRebate) {
        accruedRebate = positionIRS.accruedRebate + uint128(wmul(
            wmul(normalDebt, rateAccumulator - positionIRS.snapshotRateAccumulator),
            positionIRS.rebateFactor
        ));
    }

    event Log(string, uint256);
    /// @notice Calculates the new global interest state
    /// @param globalIRSBefore Previous global interest rate state
    /// @param rateAccumulatorAfter Updated rate accumulator [wad]
    /// @param totalNormalDebtBefore Previous total normalized debt [wad]
    /// @param normalDebtBefore Previous normalized debt of the position [wad]
    /// @param rebateFactorBefore Previous rebate factor of the position [wad]
    /// @param rebateFactorAfter Updated rebate factor of the position [wad]
    /// @param deltaNormalDebt Change in the normalized debt of the position [wad]
    /// @param claimedRebate Redeemed rebate by the user [wad]
    /// @return globalIRSAfter New global interest rate state
    /// @return accruedInterest Global accrued interest [wad]
    function _calculateGlobalIRS(
        GlobalIRS memory globalIRSBefore,
        uint64 rateAccumulatorAfter,
        uint256 totalNormalDebtBefore,
        uint256 normalDebtBefore,
        int256 deltaNormalDebt,
        uint64 rebateFactorBefore,
        uint64 rebateFactorAfter,
        uint128 claimedRebate
    ) internal returns (GlobalIRS memory globalIRSAfter, uint256 accruedInterest) {
        uint256 totalNormalDebtAfter = add(totalNormalDebtBefore, deltaNormalDebt);
        uint256 averageRebate = globalIRSBefore.averageRebate;

        if (deltaNormalDebt != 0 || rebateFactorBefore != rebateFactorAfter) {
            averageRebate = 
            (
                averageRebate
                - wmul(rebateFactorBefore, normalDebtBefore)
                + wmul(rebateFactorAfter, add(normalDebtBefore, deltaNormalDebt))
            );
        }

        {
        uint256 deltaGlobalAccruedRebate = (totalNormalDebtBefore == 0) ? 0 : wmul(
            wmul(
                wdiv(globalIRSBefore.averageRebate,totalNormalDebtBefore),
                rateAccumulatorAfter - globalIRSBefore.rateAccumulator
            ), 
            totalNormalDebtAfter
        );
        emit Log("globalIRSBefore.averageRebate", globalIRSBefore.averageRebate);
        emit Log("totalNormalDebtBefore", totalNormalDebtBefore);
        emit Log("rateAccumulatorAfter", rateAccumulatorAfter);
        emit Log("globalIRSBefore.rateAccumulator", globalIRSBefore.rateAccumulator);
        emit Log("totalNormalDebtAfter", totalNormalDebtAfter);
        emit Log("-----------------------------",0);
        emit Log("new averageRebate", averageRebate);
        emit Log("before averageRebate", globalIRSBefore.averageRebate);
        emit Log("totalNormalDebtAfter", totalNormalDebtAfter);
        emit Log("globalIRSBefore.globalAccruedRebate", globalIRSBefore.globalAccruedRebate);
        emit Log("deltaGlobalAccruedRebate", deltaGlobalAccruedRebate);
        emit Log("claimedRebate", claimedRebate);
        uint256 globalAccruedRebate = globalIRSBefore.globalAccruedRebate + deltaGlobalAccruedRebate - claimedRebate;
        globalIRSAfter = GlobalIRS({
            baseRate: globalIRSBefore.baseRate,
            globalAccruedRebate: globalAccruedRebate,
            lastUpdated: uint64(block.timestamp),
            rateAccumulator: rateAccumulatorAfter,
            averageRebate: averageRebate
        });
        }

        accruedInterest = (totalNormalDebtBefore == 0) ? 0 : wmul(
            wmul(
                WAD - wdiv(globalIRSBefore.averageRebate,totalNormalDebtBefore),
                globalIRSAfter.rateAccumulator - globalIRSBefore.rateAccumulator
            ),
            totalNormalDebtBefore
        );
    }
}
