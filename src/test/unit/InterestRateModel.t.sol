// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {WAD, wmul, wpow, wdiv, add} from "../../utils/Math.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";

contract InterestRateModelWrapper is InterestRateModel, Test {

    constructor(int64 baseRate) {
        _setGlobalIRS(GlobalIRS(baseRate, uint64(block.timestamp), uint64(WAD), 0, 0));
    }

    function setGlobalIRS(GlobalIRS memory globalIRS) public {
        return _setGlobalIRS(globalIRS);
    }

    function setBaseRate(int64 baseRate) public {
        return _setBaseRate(baseRate);
    }

    function calculateRateAccumulator(GlobalIRS memory globalIRS_, uint64 baseRate) public view returns (uint64) {
        return _calculateRateAccumulator(globalIRS_, baseRate);   
    }

    function calculateRebateClaim(
        uint256 subDebt, 
        uint256 debt, 
        uint128 accruedRebate
    ) public pure returns (
        uint128 claimedRebate, uint128 accruedRebate_
    ) {
        (claimedRebate, accruedRebate_) = _calculateRebateClaim(subDebt, debt, accruedRebate);
    }

    function calculateAccruedRebate(PositionIRS memory positionIRS, uint64 rateAccumulator, uint256 normalDebt) public pure returns (uint128 accruedRebate) {
        return _calculateAccruedRebate(positionIRS, rateAccumulator, normalDebt);
    }

    function calculateGlobalIRS(
        GlobalIRS memory globalIRSBefore,
        uint64 rateAccumulatorAfter,
        uint256 totalNormalDebtBefore,
        uint256 normalDebtBefore,
        int256 deltaNormalDebt,
        uint64 rebateFactorBefore,
        uint64 rebateFactorAfter,
        uint128 claimedRebate
    ) public returns(
        GlobalIRS memory globalIRSAfter, uint256 accruedInterest
    ){
        (globalIRSAfter, accruedInterest) = _calculateGlobalIRS(
            globalIRSBefore,
            rateAccumulatorAfter,
            totalNormalDebtBefore,
            normalDebtBefore,
            deltaNormalDebt,
            rebateFactorBefore,
            rebateFactorAfter,
            claimedRebate   
        );
    }
}

contract InterestRateModelTest is Test {
    InterestRateModelWrapper internal model;

    address internal user1 = address(1);
    address internal user2 = address(2);
    address internal user3 = address(3);

    int64 internal rateCeiling = 1000000021919499726;

    struct CalculateGlobalParams{
        // inputs
        InterestRateModel.GlobalIRS globalIRSBefore;
        uint64 rateAccumulatorBefore;
        uint64 rateAccumulatorAfter;
        uint64 rebateFactorBefore;
        uint64 rebateFactorAfter;
        uint256 globalAccruedRebate;
        uint256 totalNormalDebtBefore;
        uint256 normalDebtBefore;
        int256 deltaNormalDebt;
        uint128 claimedRebate;

        // outputs to validate
        InterestRateModel.GlobalIRS globalIRSAfter;
        uint256 accruedInterest;
    }

    function setUp() public {
        // 1% baseRate
        model = new InterestRateModelWrapper(1000000000314660837);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _calculateAverageRebate(
        uint256 averageRebateBefore,
        int256 deltaNormalDebt,
        uint64 rebateFactorBefore,
        uint64 rebateFactorAfter,
        uint256 normalDebtBefore
    ) private pure returns (uint256 averageRebate){
        averageRebate = averageRebateBefore;
        if (deltaNormalDebt != 0 || rebateFactorBefore != rebateFactorAfter) {
            averageRebate =
            (
                averageRebateBefore
                - wmul(rebateFactorBefore, normalDebtBefore)
                + wmul(rebateFactorAfter, add(normalDebtBefore, deltaNormalDebt))
            );
        }
    }

    function _calculateGlobalAccruedRebate(
        InterestRateModel.GlobalIRS memory globalIRSBefore,
        uint64 rateAccumulatorAfter,
        uint128 claimedRebate
    ) private pure returns (uint256 globalAccruedRebate) {
        uint256 deltaGlobalAccruedRebate = wmul(globalIRSBefore.averageRebate, rateAccumulatorAfter) - 
            wmul(globalIRSBefore.averageRebate, globalIRSBefore.rateAccumulator
        );
        globalAccruedRebate = globalIRSBefore.globalAccruedRebate + deltaGlobalAccruedRebate - claimedRebate;
    }

    function _calculateGlobalIRS(
        InterestRateModel.GlobalIRS memory globalIRSBefore,
        uint64 rateAccumulatorAfter,
        uint256 totalNormalDebtBefore,
        uint256 normalDebtBefore,
        int256 deltaNormalDebt,
        uint64 rebateFactorBefore,
        uint64 rebateFactorAfter,
        uint128 claimedRebate
    ) public view returns (InterestRateModel.GlobalIRS memory globalIRSAfter, uint256 accruedInterest) {
        uint256 averageRebate = _calculateAverageRebate(
            globalIRSBefore.averageRebate,
            deltaNormalDebt,
            rebateFactorBefore,
            rebateFactorAfter,
            normalDebtBefore
        );

        {
        uint256 globalAccruedRebate = _calculateGlobalAccruedRebate(
            globalIRSBefore,
            rateAccumulatorAfter,
            claimedRebate
        );

        globalIRSAfter = InterestRateModel.GlobalIRS({
            baseRate: globalIRSBefore.baseRate,
            globalAccruedRebate: globalAccruedRebate,
            lastUpdated: uint64(block.timestamp),
            rateAccumulator: rateAccumulatorAfter,
            averageRebate: averageRebate
        });
        }

        {
        uint256 deltaGlobalAccruedRebate = wmul(
            globalIRSBefore.averageRebate, rateAccumulatorAfter) - wmul(
                globalIRSBefore.averageRebate, globalIRSBefore.rateAccumulator
        );
        accruedInterest = wmul(
            totalNormalDebtBefore, rateAccumulatorAfter) - wmul(
                totalNormalDebtBefore, globalIRSBefore.rateAccumulator
            ) - deltaGlobalAccruedRebate;
        }
    }

    function _validateGlobalIRS(CalculateGlobalParams memory params) private {
        uint256 averageRebate = _calculateAverageRebate(
            params.globalIRSBefore.averageRebate,
            params.deltaNormalDebt,
            params.rebateFactorBefore,
            params.rebateFactorAfter,
            params.normalDebtBefore
        );

        uint256 globalAccruedRebate =_calculateGlobalAccruedRebate(
            params.globalIRSBefore,
            params.rateAccumulatorAfter,
            params.claimedRebate
        );

        InterestRateModel.GlobalIRS memory expectedGlobalIRSAfter = InterestRateModel.GlobalIRS({
            baseRate: params.globalIRSBefore.baseRate,
            globalAccruedRebate: globalAccruedRebate,
            lastUpdated: uint64(block.timestamp),
            rateAccumulator: params.rateAccumulatorAfter,
            averageRebate: averageRebate
        });

        uint256 deltaGlobalAccruedRebate = wmul(
            params.globalIRSBefore.averageRebate, expectedGlobalIRSAfter.rateAccumulator) - wmul(
                params.globalIRSBefore.averageRebate, params.globalIRSBefore.rateAccumulator
        );
        uint256 expectedAccruedInterest = wmul(
            params.totalNormalDebtBefore, expectedGlobalIRSAfter.rateAccumulator) - wmul(
                params.totalNormalDebtBefore, params.globalIRSBefore.rateAccumulator
            ) - deltaGlobalAccruedRebate;
        
        assertEq(expectedAccruedInterest, params.accruedInterest);
        assertEq(expectedGlobalIRSAfter.baseRate, params.globalIRSAfter.baseRate);
        assertEq(expectedGlobalIRSAfter.globalAccruedRebate, params.globalIRSAfter.globalAccruedRebate);
        assertEq(expectedGlobalIRSAfter.lastUpdated, params.globalIRSAfter.lastUpdated);
        assertEq(expectedGlobalIRSAfter.rateAccumulator, params.globalIRSAfter.rateAccumulator);
        assertEq(expectedGlobalIRSAfter.averageRebate, params.globalIRSAfter.averageRebate);
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_setBaseRate(int64 baseRate) public {
        if(baseRate > 0) {
            baseRate = int64(bound(int256(baseRate), int256(WAD), rateCeiling));
        }
        model.setBaseRate(baseRate);
        InterestRateModel.GlobalIRS memory globalIRS = model.getGlobalIRS();
        assertEq(globalIRS.baseRate, baseRate);
    }

    function test_setBaseRate_revertOnInvalidValues() public {
        int64 invalidRate = int64(int256(WAD) - 1);
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);

        invalidRate = int64(1);
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);

        invalidRate = int64(1000000021919499726 + 1);
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);

        invalidRate = type(int64).max;
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);
    }

    function test_calculateRateAccumulator(uint64 rateAccumulator, uint64 baseRate, uint64 timeStamp, uint64 updateSeed) public {
        InterestRateModel.GlobalIRS memory globalIRS = model.getGlobalIRS();
        // bound the warp to max 2 years
        timeStamp = uint64(bound(timeStamp, 0, 86400 * 366 * 2));
        globalIRS.lastUpdated = uint64(bound(updateSeed, 0, timeStamp));
        globalIRS.rateAccumulator = uint64(
            bound(
                rateAccumulator, 
                WAD, 
                wdiv(type(uint64).max, wpow(uint64(rateCeiling),86400 * 366 * 2, WAD))
            )
        );

        baseRate = uint64(bound(baseRate, WAD, uint64(rateCeiling)));

        vm.warp(timeStamp);
        uint64 expectedValue = uint64(wmul(
            globalIRS.rateAccumulator,
            wpow(uint256(baseRate), (block.timestamp - globalIRS.lastUpdated), WAD)
        ));

        assertEq(expectedValue, model.calculateRateAccumulator(globalIRS, baseRate));
    }

    function test_calculateRebateClaim(uint256 subDebt, uint256 debt, uint128 accruedRebate) public {
        vm.assume(subDebt != 0 && debt != 0);
        debt = bound(debt, 1, type(uint128).max);
        subDebt = bound(subDebt, 1, debt);
        uint128 expectedClaimedRebate = uint128(subDebt * accruedRebate / debt);
        uint128 expectedAccruedRebate = accruedRebate - expectedClaimedRebate;

        (uint128 claimedRebate, uint128 accruedRebate_) = model.calculateRebateClaim(subDebt, debt, accruedRebate);
        assertEq(claimedRebate, expectedClaimedRebate);
        assertEq(expectedAccruedRebate, accruedRebate_);
    }

    function test_calculateAccruedRebate(
        uint128 accruedRebate, 
        uint64 rebateFactor, 
        uint64 rateAccumulator, 
        uint64 snapshotRateAccumulator, 
        uint256 normalDebt
    ) public {
        rateAccumulator = uint64(
            bound(
                rateAccumulator, 
                WAD, 
                wdiv(type(uint64).max, wpow(uint64(rateCeiling),86400 * 366 * 2, WAD))
            )
        );

        snapshotRateAccumulator = uint64(bound(snapshotRateAccumulator, rateAccumulator - WAD, rateAccumulator));
        normalDebt = bound(normalDebt, 0, type(uint128).max);
        rebateFactor = uint64(bound(rebateFactor, 0, WAD));

        uint64 rateDelta = rateAccumulator - snapshotRateAccumulator;
        accruedRebate = uint128(bound(accruedRebate, 0, type(uint128).max - wmul(rateDelta, normalDebt)));
        
        uint256 normalizedRebateFactor = wmul(rebateFactor, normalDebt);
        uint128 expectedAccruedRebate = accruedRebate + uint128(wmul(
            normalizedRebateFactor, rateAccumulator) - wmul(
                normalizedRebateFactor, snapshotRateAccumulator)
        );

        uint128 accruedRebate_ = model.calculateAccruedRebate(
            InterestRateModel.PositionIRS({
                snapshotRateAccumulator: snapshotRateAccumulator,
                rebateFactor: rebateFactor,
                accruedRebate: accruedRebate
            }),
            rateAccumulator,
            normalDebt
        );
        assertEq(expectedAccruedRebate,accruedRebate_);
    }

    function test_calculateAverageRebate(
        uint256 averageRebateBefore,
        uint64 rebateFactorBefore,
        uint64 rebateFactorAfter,
        uint256 totalNormalDebtBefore,
        uint256 normalDebtBefore,
        int256 deltaNormalDebt
    ) view public {
        totalNormalDebtBefore = bound(totalNormalDebtBefore, 0, type(uint128).max);
        normalDebtBefore = bound(normalDebtBefore, 0, totalNormalDebtBefore);
        rebateFactorBefore = uint64(bound(rebateFactorBefore, 0, WAD));
        rebateFactorAfter = uint64(bound(rebateFactorAfter, 0, WAD));
        averageRebateBefore = bound(averageRebateBefore, 0, totalNormalDebtBefore);

        // if totalNormalDebtBefore is 0, averageRebate should be 0
        if(totalNormalDebtBefore == 0) averageRebateBefore = 0;
        if(averageRebateBefore == 0 || normalDebtBefore == 0){
            rebateFactorBefore = 0;
        } else if (totalNormalDebtBefore == normalDebtBefore){
            rebateFactorBefore = uint64(wdiv(averageRebateBefore, totalNormalDebtBefore));
        } else {
            rebateFactorBefore = uint64(bound (rebateFactorBefore, 0, wmul(wdiv(averageRebateBefore, normalDebtBefore), uint256(0.9 ether))));
        }
        
        deltaNormalDebt = bound(deltaNormalDebt, -int256(normalDebtBefore), type(int128).max - int256(normalDebtBefore));
        _calculateAverageRebate(
            averageRebateBefore,
            deltaNormalDebt,
            rebateFactorBefore,
            rebateFactorAfter,
            normalDebtBefore
        );
    }

    function test_calculateGlobalIRS(
        uint256 averageRebate,
        uint64 rateAccumulatorBefore,
        uint64 rateAccumulatorAfter,
        uint64 rebateFactorBefore,
        uint64 rebateFactorAfter,
        uint256 globalAccruedRebate,
        uint256 totalNormalDebtBefore,
        uint256 normalDebtBefore,
        int256 deltaNormalDebt,
        uint128 claimedRebate
    ) public {
        rateAccumulatorAfter = uint64(
            bound(
                rateAccumulatorAfter, 
                WAD, 
                wdiv(type(uint64).max, wpow(uint64(rateCeiling),86400 * 366 * 2, WAD))
            )
        );
        globalAccruedRebate = bound(globalAccruedRebate, 0, type(uint128).max);
        totalNormalDebtBefore = bound(totalNormalDebtBefore, 0, type(uint128).max);
        normalDebtBefore = bound(normalDebtBefore, 0, totalNormalDebtBefore);

        rateAccumulatorBefore = uint64(bound(rateAccumulatorBefore, 0, rateAccumulatorAfter));
        rebateFactorBefore = uint64(bound(rebateFactorBefore, 0, WAD));
        rebateFactorAfter = uint64(bound(rebateFactorAfter, 0, WAD));
        averageRebate = bound(averageRebate, 0, totalNormalDebtBefore);

        // if totalNormalDebtBefore is 0, averageRebate should be 0
        if(totalNormalDebtBefore == 0) averageRebate = 0;
        if(averageRebate == 0 || normalDebtBefore == 0){
            rebateFactorBefore = 0;
        } else if (totalNormalDebtBefore == normalDebtBefore){
            rebateFactorBefore = uint64(wdiv(averageRebate, totalNormalDebtBefore));
        } else {
            rebateFactorBefore = uint64(bound (rebateFactorBefore, 0, wmul(wdiv(averageRebate, normalDebtBefore), uint256(0.9 ether))));
        }

        deltaNormalDebt = bound(deltaNormalDebt, -int256(normalDebtBefore), type(int128).max - int256(normalDebtBefore));
        claimedRebate = uint128(bound(claimedRebate, 0, globalAccruedRebate));

        // Pack all the parameters into a struct to avoid stack too deep errors
        CalculateGlobalParams memory params = CalculateGlobalParams({
            globalIRSBefore:InterestRateModel.GlobalIRS({
                baseRate: int64(uint64(WAD)),
                globalAccruedRebate: globalAccruedRebate,
                lastUpdated: uint64(block.timestamp),
                rateAccumulator: rateAccumulatorBefore,
                averageRebate: averageRebate
            }),
            rateAccumulatorBefore : rateAccumulatorBefore,
            rateAccumulatorAfter : rateAccumulatorAfter,
            rebateFactorBefore: rebateFactorBefore,
            rebateFactorAfter: rebateFactorAfter,
            globalAccruedRebate: globalAccruedRebate,
            totalNormalDebtBefore: totalNormalDebtBefore,
            normalDebtBefore: normalDebtBefore,
            deltaNormalDebt: deltaNormalDebt,
            claimedRebate: claimedRebate,

            // properties to validate
            accruedInterest : 0,
            globalIRSAfter:InterestRateModel.GlobalIRS({
                baseRate: 0,
                globalAccruedRebate: 0,
                lastUpdated: 0,
                rateAccumulator: 0,
                averageRebate: 0
            })
        });

        // populate the properties that need validation
        (params.globalIRSAfter, params.accruedInterest) = model.calculateGlobalIRS(
            InterestRateModel.GlobalIRS({
                baseRate: int64(uint64(WAD)),
                globalAccruedRebate: globalAccruedRebate,
                lastUpdated: uint64(block.timestamp),
                rateAccumulator: rateAccumulatorBefore,
                averageRebate: averageRebate
            }),
            rateAccumulatorAfter,
            totalNormalDebtBefore,
            normalDebtBefore,
            deltaNormalDebt,
            rebateFactorBefore,
            rebateFactorAfter,
            claimedRebate
        );

        _validateGlobalIRS(params);
    }

    function test_calculateRateAccumulator() public {
        vm.warp(366 days);
        // Interest Rate = 0%
        assertEq(model.calculateRateAccumulator(InterestRateModel.GlobalIRS(int64(uint64(WAD)), 0, uint64(WAD), 0, 0), uint64(WAD)), uint64(WAD));

        // Interest Rate = 1%
        assertEq(
            model.calculateRateAccumulator(InterestRateModel.GlobalIRS(int64(uint64(WAD)), 0, uint64(WAD), 0, 0), 1000000000314660837), 
            uint64(wmul(WAD, wpow(1000000000314660837, 366 * 86400, WAD)))
        );
        
        // Interest Rate = 100%
        vm.warp(366 days * 18);
        assertEq(
            model.calculateRateAccumulator(InterestRateModel.GlobalIRS(int64(uint64(WAD)), 0, uint64(WAD), 0, 0), 1000000021919499726), 
            uint64(wmul(WAD, wpow(1000000021919499726, 366 * 18 * 86400, WAD)))
        );
    }

    function test_negative_baseRate() public {
        InterestRateModel.GlobalIRS memory globalIRS = new InterestRateModelWrapper(-1).getGlobalIRS();
        assertEq(globalIRS.baseRate, -1);
    }
}