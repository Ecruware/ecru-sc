// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InvariantTestBase} from "../InvariantTestBase.sol";
import {BaseHandler, GhostVariableStorage, USERS_CATEGORY} from "./BaseHandler.sol";

import {ICDPVaultBase} from "../../../interfaces/ICDPVault.sol";

import {calculateDebt} from "../../../CDPVault.sol";
import {CDM, getDebt} from "../../../CDM.sol";
import {CDPVault_TypeAWrapper} from "../CDPVault_TypeAWrapper.sol";
import {WAD, min, wdiv, wmul, mul} from "../../../utils/Math.sol";

contract LiquidateHandler is BaseHandler {
    uint256 internal constant COLLATERAL_PER_POSITION = 1_000_000 ether;
    
    uint256 public immutable creditReserve = 100_000_000_000_000 ether;
    uint256 public immutable collateralReserve = 100_000_000_000_000 ether;
    
    uint256 public immutable maxCreateUserAmount = 10;
    uint256 public immutable minLiquidateUserAmount = 1;

    uint256 public immutable maxCollateralRatio = 2 ether;

    address[] public liquidatedPositions;
    uint256 public preLiquidationDebt;
    uint256 public postLiquidationDebt;
    uint256 public creditPaid;
    uint256 public accruedBadDebt;

    CDM public cdm;
    CDPVault_TypeAWrapper public vault;
    IERC20 public token;
    address public buffer;

    uint64 internal immutable liquidationRatio;
    uint64 internal immutable targetHealthFactor;
    uint256 internal immutable liquidationDiscount;

    function liquidationPrice(uint256 collateral, uint256 normalDebt) internal view returns (uint256 spotPrice) {
        spotPrice = wmul(wdiv(wmul(normalDebt, uint256(liquidationRatio)), collateral), uint256(0.9 ether));
    }

    function liquidatedPositionsCount() public view returns (uint256) {
        return liquidatedPositions.length;
    }

    constructor(
        CDPVault_TypeAWrapper vault_, 
        InvariantTestBase testContract_, 
        GhostVariableStorage ghostStorage_,
        uint64 positionLiquidationRatio_,
        uint64 targetHealthFactor_
    ) BaseHandler ("LiquidateHandler", testContract_, ghostStorage_) {
        vault = vault_;
        cdm = CDM(address(vault_.cdm()));
        buffer = address(vault_.buffer());
        token = vault.token();
        liquidationRatio = positionLiquidationRatio_;
        targetHealthFactor = targetHealthFactor_;
        ( ,liquidationDiscount, ) = vault.liquidationConfig(); 
    }

    function getTargetSelectors() public pure virtual override returns (bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](3);
        names = new string[](3);
        selectors[0] = this.createPositions.selector;
        names[0] = "createPositions";

        selectors[1] = this.liquidateRandom.selector;
        names[1] = "liquidateRandom";

        selectors[2] = this.liquidateMultiple.selector;
        names[2] = "liquidateMultiple";
    }

    function createPositions(uint256 seed, uint256 healthFactorSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        // reset state 
        delete liquidatedPositions;
        preLiquidationDebt = 0;
        postLiquidationDebt = 0;
        creditPaid = 0;
        accruedBadDebt = 0;

        for (uint256 i = 0; i < maxCreateUserAmount; i++) {
            address user = address(uint160(uint256(keccak256(abi.encode(msg.sender, seed, i)))));
            addActor(USERS_CATEGORY, user);

            // bound the health factor and calculate collateral and debt, randomize the health factor seed
            uint256 minCollateralRatio = liquidationRatio;
            uint256 collateralRatio = bound(uint256(keccak256(abi.encode(healthFactorSeed, user))), minCollateralRatio, maxCollateralRatio);
            uint256 collateral = COLLATERAL_PER_POSITION;
            uint256 debt = wdiv(collateral, collateralRatio);
            vault.modifyPermission(user, true);

            // create the position
            vm.prank(user);
            vault.modifyCollateralAndDebt({
                owner:user, 
                collateralizer: address(this), 
                creditor: user, 
                deltaCollateral: int256(collateral),
                deltaNormalDebt: int256(debt)
            });
        }

        trackCallEnd(msg.sig);
    }

    function liquidateRandom(uint256 randomSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        address user = getRandomActor(USERS_CATEGORY, randomSeed);
        if(user == address(0)) return;

        (uint256 collateral, uint256 normalDebt) = vault.positions(user);
        if(collateral == 0 || normalDebt == 0) return;

        liquidatedPositions = new address[](1);
        liquidatedPositions[0] = user;
        uint256[] memory repayAmounts = new uint256[](1);
        repayAmounts[0] = bound(randomSeed, minLiquidateUserAmount, normalDebt * 2);

        _liquidatePositions(liquidatedPositions, repayAmounts);

        trackCallEnd(msg.sig);
    }

    function liquidateMultiple(uint256 countSeed, uint256 randomSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        if(count(USERS_CATEGORY) == 0) return;

        uint256 count = bound(countSeed, 1, maxCreateUserAmount);
        liquidatedPositions = new address[](count);
        uint256[] memory repayAmounts = new uint256[](count);

        for (uint256 i = 0; i<count; ++i) {
            address user = getRandomActor(USERS_CATEGORY, uint256(keccak256(abi.encode(randomSeed, i))));
            for (uint256 userIdx = 0; userIdx < i; ++userIdx){
                if (user == liquidatedPositions[userIdx]) user = address(0);
            }
            liquidatedPositions[i] = user;

            (uint256 collateral, uint256 normalDebt) = vault.positions(user);
            // skip liquidation if the position is empty
            if (collateral == 0 || normalDebt == 0 || user == address(0)) {
                repayAmounts[i] = 0;
            } else {
                repayAmounts[i] = bound(randomSeed, minLiquidateUserAmount, normalDebt * 2);   
            }
        }

        _liquidatePositions(liquidatedPositions, repayAmounts);
        trackCallEnd(msg.sig);
    }

    /// ======== Value tracking helper functions ======== ///

    function getPositionHealth(
        address position
    ) public view returns (uint256 prevHealth, uint256 currentHealth) {
        (bytes32 prevHealthBytes, bytes32 currentHealthBytes) = getTrackedValue(keccak256(abi.encodePacked("positionHealth", position)));
        return (uint256(prevHealthBytes), uint256(currentHealthBytes));
    }

    function getPositionDebt(
        address position
    ) public view returns (uint256 prevDebt, uint256 currentDebt) {
        (bytes32 prevDebtBytes, bytes32 currentDebtBytes) = getTrackedValue(keccak256(abi.encodePacked("positionDebt", position)));
        return (uint256(prevDebtBytes), uint256(currentDebtBytes));
    }

    function getRepayAmount(address position) public view returns (uint256 amount) {
        return uint256(getGhostValue(keccak256(abi.encodePacked("repayAmount", position))));
    }

    function getIsSafeLiquidation(address position) public view returns (bool) {
        uint256 isSafeFlag = uint256(getGhostValue(keccak256(abi.encodePacked("isSafeLiquidation", position))));

        return isSafeFlag == 1;
    }

    function _trackPositionHealth(address position, uint256 spot) private returns (uint256 currentHealth){
        (uint256 collateral, uint256 normalDebt) = vault.positions(position);
        (uint64 rateAccumulator,, uint256 accruedRebate) = vault.virtualIRS(position);

        uint256 debt = calculateDebt(normalDebt, rateAccumulator, accruedRebate);
        if (collateral == 0 || normalDebt == 0) {
            currentHealth = type(uint256).max;
        } else {
            currentHealth = wdiv(wdiv(wmul(collateral, spot), debt), liquidationRatio);
        }
        trackValue(keccak256(abi.encodePacked("positionHealth", position)), bytes32(currentHealth));
    }

    function _trackPositionDebt(address position) private returns (uint256 debt) {
        ( , uint256 normalDebt) = vault.positions(position);

        (uint64 rateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(position);
        debt = calculateDebt(normalDebt, rateAccumulator, accruedRebate);

        trackValue(keccak256(abi.encodePacked("positionDebt", position)), bytes32(debt));
    }

    function _setRepayAmount(address position, uint256 repayAmount) private {
        setGhostValue(keccak256(abi.encodePacked("repayAmount", position)), bytes32(repayAmount));
    }

    function _setIsSafeLiquidation(address position, uint256 isSafe) private {
        setGhostValue(keccak256(abi.encodePacked("isSafeLiquidation", position)), bytes32(isSafe));
    }

    /// ======== Liquidation helper functions ======== ///

    function _liquidatePositions(
        address[] memory positions, uint256[] memory repayAmounts
    ) private {

        uint256 newSpotPrice =  _getLiquidationPrice(positions);
        testContract.setOraclePrice(newSpotPrice);

        preLiquidationDebt = 0;
        postLiquidationDebt = 0;
        // track the debt and health of the positions pre liquidation
        uint256 len = positions.length;
        for (uint256 i=0; i<len; ++i) {
            // skip if the position was not liquidated
            if(repayAmounts[i] == 0) continue;

            uint256 debt = _trackPositionDebt(positions[i]);
            preLiquidationDebt += debt;
            (uint256 collateral, ) = vault.positions(positions[i]);
            uint256 collateralValue = wmul(wmul(collateral, newSpotPrice), liquidationDiscount);
            _trackPositionHealth(positions[i], newSpotPrice);
            _setIsSafeLiquidation(positions[i], (collateralValue  >= debt) ? 1 : 0);
            _setRepayAmount(positions[i], repayAmounts[i]);
        }

        (int256 balance, ) = cdm.accounts(address(this));
        (int256 bufferBalance, ) = cdm.accounts(buffer);
        uint256 bufferInitialDebt = getDebt(bufferBalance);

        vault.liquidatePositions(positions, repayAmounts);
        
        (int256 finalBalance, ) = cdm.accounts(address(this));
        (bufferBalance, ) = cdm.accounts(buffer);
        uint256 bufferFinalDebt = getDebt(bufferBalance);

        // track the debt and health of the positions post liquidation
        for (uint256 i=0; i<len; ++i) {
            // skip if the position was not liquidated
            if(repayAmounts[i] == 0) continue;
            
            postLiquidationDebt += _trackPositionDebt(positions[i]);
            _trackPositionHealth(positions[i], newSpotPrice);
        }

        creditPaid = uint256(balance - finalBalance);
        accruedBadDebt = bufferFinalDebt - bufferInitialDebt;
        
        testContract.setOraclePrice(WAD);
    }

    function _getLiquidationPrice(
        address[] memory positions
    ) private view returns (uint256 liquidationPrice_) {
        liquidationPrice_ = type(uint256).max;
        uint256 len = positions.length;
        for (uint256 i=0; i<len; ++i) {
            (uint256 collateral, uint256 normalDebt) = vault.positions(positions[i]);
            if (collateral == 0 || normalDebt == 0) continue;
            uint256 currentLiqPrice = liquidationPrice(collateral, normalDebt);
            if(liquidationPrice_ > currentLiqPrice) {
                liquidationPrice_ = currentLiqPrice;
            }
        }

        if (liquidationPrice_ == type(uint256).max) {
            liquidationPrice_ = 0;
        }

        return wmul(liquidationPrice_, uint256(0.9 ether));
    }
}