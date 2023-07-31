// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../invariant/handlers/BaseHandler.sol";
import {LiquidateHandler} from "../invariant/handlers/LiquidateHandler.sol";

import {TestBase} from "../TestBase.sol";

import {CDPVaultConstants, CDPVaultConfig, CDPVault_TypeAConfig} from "../../interfaces/ICDPVault_TypeA_Factory.sol";

import {WAD, wmul, wdiv} from "../../utils/Math.sol";

import {CDM, ACCOUNT_CONFIG_ROLE, getCredit, getDebt} from "../../CDM.sol";
import {BAIL_OUT_QUALIFIER_ROLE} from "../../Buffer.sol";
import {CDPVault, calculateDebt} from "../../CDPVault.sol";
import {CDPVault_TypeA_Factory} from "../../CDPVault_TypeA_Factory.sol";
import {CDPVaultUnwinderFactory} from "../../CDPVaultUnwinder.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";
import {CDPVault_TypeAWrapper, CDPVault_TypeAWrapper_Deployer} from "./CDPVault_TypeAWrapper.sol";

/// @title InvariantTestBase
/// @notice Base test contract with common logic needed by all invariant test contracts.
contract InvariantTestBase is TestBase {

    uint256 constant internal EPSILON = 500;

    uint64 constant internal BASE_RATE_1_0 = 1 ether; // 0% base rate
    uint64 constant internal BASE_RATE_1_005 = 1000000000157721789; // 0.5% base rate
    uint64 constant internal BASE_RATE_1_025 = 1000000000780858271; // 2.5% base rate

    /// ======== Storage ======== ///

    modifier printReport(BaseHandler handler) {
        _;
        handler.printCallReport();
    }

    function setUp() public override virtual{
        super.setUp();
        filterSenders();
    }

    /// ======== Stablecoin Invariant Asserts ======== ///
    /*
    Stablecoin Invariants:
        - Invariant A: sum of balances for all holders is equal to `totalSupply` of `Stablecoin`
        - Invariant B: conservation of `Stablecoin` is maintained
    */

    // Invariant A: sum of balances for all holders is equal to `totalSupply` of `Stablecoin`
    function assert_invariant_Stablecoin_A(uint256 totalUserBalance) public {
        assertEq(stablecoin.totalSupply(), totalUserBalance);
    }

    // Invariant B: conservation of `Stablecoin` is maintained
    function assert_invariant_Stablecoin_B(uint256 mintAccumulator, uint256 burnAccumulator) public {
        uint256 stablecoinInExistence = mintAccumulator - burnAccumulator;
        assertEq(stablecoin.totalSupply(), stablecoinInExistence);
    }

    /// ======== CDM Invariant Asserts ======== ///
    /*
    CDM Invariants:
        - Invariant A: `totalSupply` of `Stablecoin` is less or equal to `globalDebt`
        - Invariant B: `globalDebt` is less or equal to `globalDebtCeiling`
        - Invariant C: sum of `credit` for all accounts is less or equal to `globalDebt`
        - Invariant D: sum of `debt` for all `Vaults` is less or equal to `globalDebt`
        - Invariant E: sum of `debt` for a `Vault` is less or equal to `debtCeiling`
    */

    // Invariant A: `totalSupply` of `Stablecoin` is less or equal to `globalDebt`
    function assert_invariant_CDM_A() public {
        assertLe(stablecoin.totalSupply(), cdm.globalDebt());
    }

    // Invariant B: `globalDebt` is less or equal to `globalDebtCeiling`
    function assert_invariant_CDM_B() public {
        assertGe(cdm.globalDebtCeiling(), cdm.globalDebt());
    }

    // Invariant C: sum of `credit` for all accounts is less or equal to `globalDebt`
    function assert_invariant_CDM_C(BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        uint256 totalUserCredit = 0;
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (int256 balance,) = cdm.accounts(user);
            totalUserCredit += getCredit(balance);
        }

        assertGe(cdm.globalDebt(), totalUserCredit);
    }

    // Invariant D: sum of `debt` for all `Vaults` is less or equal to `globalDebt`
    function assert_invariant_CDM_D(BaseHandler handler) public {
        uint256 vaultCount = handler.count(VAULTS_CATEGORY);
        uint256 totalVaultDebt = 0;
        for (uint256 i = 0; i < vaultCount; ++i) {
            address vault = handler.getActor(VAULTS_CATEGORY, i);
            (int256 balance, ) = cdm.accounts(vault);
            totalVaultDebt += getDebt(balance);
        }

        assertGe(cdm.globalDebt(), totalVaultDebt);
    }

    // Invariant E: sum of `debt` for a `Vault` is less or equal to `debtCeiling`
    function assert_invariant_CDM_E(BaseHandler handler) public {
        uint256 vaultCount = handler.count(VAULTS_CATEGORY);
        uint256 totalVaultDebt = 0;
        for (uint256 i = 0; i < vaultCount; ++i) {
            address vault = handler.getActor(VAULTS_CATEGORY, i);
            (int256 balance, ) = cdm.accounts(vault);
            totalVaultDebt += getDebt(balance);
        }

        assertGe(cdm.globalDebtCeiling(), totalVaultDebt);
    }

    /// ======== CDPVault Invariant Asserts ======== ///

    /*
    CDPVault Invariants:
        - Invariant A: `balanceOf` collateral `token`'s of a `CDPVault` is greater or equal to the sum of all the `CDPVault`'s `Position`'s `collateral` amounts and the sum of all `cash` balances
        - Invariant B: sum of `normalDebt` of all `Positions` is equal to `totalNormalDebt`
        - Invariant C: sum of `normalDebt * rateAccumulator - accruedRebate` (debt) across all positions = `totalNormalDebt * rateAccumulator -  globalAccruedRebate` (totalDebt) - assuming all PositionIRS's are up to date
        - Invariant D: sum of `normalDebt * rateAccumulator - accruedRebate` (debt) across all positions <= `totalNormalDebt * rateAccumulator -  globalAccruedRebate` (totalDebt) - assuming some PositionIRS's are not up to date
        - Invariant E: `debt` for all `Positions` is greater than `debtFloor` or zero
        - Invariant F: all `Positions` are safe
    */

    // Invariant A: `balanceOf` collateral `token`'s of a `CDPVault_R` is greater or equal to the sum of all the `CDPVault_R`'s `Position`'s `collateral` amounts and the sum of all `cash` balances
    function assert_invariant_CDPVault_A(CDPVault vault, BaseHandler handler) public {
        uint256 totalCollateralBalance = 0;
        uint256 totalCashBalance = 0;

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (uint256 collateral, ) = vault.positions(user);
            totalCollateralBalance += collateral;
            totalCashBalance += vault.cash(user);
        }

        uint256 vaultBalance = token.balanceOf(address(vault));

        assertGe(vaultBalance, totalCollateralBalance + totalCashBalance);
    }

    // Invariant B: sum of `normalDebt` of all `Positions` is equal to `totalNormalDebt`
    function assert_invariant_CDPVault_B(CDPVault vault, BaseHandler handler) public {
        uint256 totalNormalDebt = 0;

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt) = vault.positions(user);
            totalNormalDebt += normalDebt;
        }

        assertEq(totalNormalDebt, vault.totalNormalDebt());
    }

    // Invariant C: sum of `normalDebt * rateAccumulator - accruedRebate` (debt) across all positions = `totalNormalDebt * rateAccumulator -  globalAccruedRebate` (totalDebt) - assuming all PositionIRS's are up to date
    function assert_invariant_CDPVault_C(CDPVault vault, BaseHandler handler) public {
        uint256 totalPositionsDebt = 0;

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt) = vault.positions(user);
            (uint64 snapshotRateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(user);
            totalPositionsDebt += calculateDebt(normalDebt, snapshotRateAccumulator, accruedRebate);
        }

        (uint64 rateAccumulator,,uint256 globalAccruedRebate) = vault.virtualIRS(address(0));
        uint256 totalDebt = calculateDebt(vault.totalNormalDebt(), rateAccumulator, globalAccruedRebate);
        assertGe(totalDebt, totalPositionsDebt);
    }

    // Invariant D: sum of `normalDebt * rateAccumulator - accruedRebate` (debt) across all positions <= `totalNormalDebt * rateAccumulator -  globalAccruedRebate` (totalDebt) - assuming some PositionIRS's are not up to date
    function assert_invariant_CDPVault_D(CDPVault vault, BaseHandler handler) public {
        uint256 totalPositionsDebt = 0;

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt) = vault.positions(user);
            InterestRateModel.PositionIRS memory positionIRS = vault.getPositionIRS(user);
            totalPositionsDebt += calculateDebt(normalDebt, positionIRS.snapshotRateAccumulator, positionIRS.accruedRebate);
        }

        InterestRateModel.GlobalIRS memory globalIRS = vault.getGlobalIRS();
        uint256 globalDebt = calculateDebt(vault.totalNormalDebt(), globalIRS.rateAccumulator, globalIRS.globalAccruedRebate);
        assertGe(globalDebt, totalPositionsDebt);
    }

    // Invariant E: `debt` for all `Positions` is greater than `debtFloor` or zero
    function assert_invariant_CDPVault_E(CDPVault vault, BaseHandler handler) public {
        (uint128 debtFloor, , ) = vault.vaultConfig();

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt) = vault.positions(user);
            if (normalDebt != 0) {
                assertGe(normalDebt, debtFloor);
            }
        }
    }

    // - Invariant F: all `Positions` are safe
    function assert_invariant_CDPVault_F(CDPVault vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (uint256 collateral, uint256 normalDebt) = vault.positions(user);
            // ensure that the position is safe (i.e. collateral * liquidationPrice >= normalDebt)
            assertGe(wmul(collateral, liquidationPrice(vault)) ,normalDebt);
        }
    }

    /// ======== Interest Rate Model Invariant Asserts ======== ///

    /*
    Interest Rate Model Invariants:
        - Invariant A: `rebateFactor` <= 1 (for all positions)
        - Invariant B: 1 <= `rateAccumulator` (for all positions)
        - Invariant C: sum of `accruedRebate` across all PositionIRS's = `globalAccruedRebate` - assuming all PositionIRS's are up to date
        - Invariant D: sum of `accruedRebate` across all PositionIRS's <= `globalAccruedRebate` - assuming some PositionIRS's are not up to date
        - Invariant E: `averageRebate` <= `totalNormalDebt`
        - Invariant F: `accruedRebate` <= `normalDebt * deltaRateAccumulator`
        - Invariant G: `globalAccruedRebate` <= `totalNormalDebt * deltaRateAccumulator`
        - Invariant H: `rateAccumulator` at block x <= `rateAccumulator` at block y, if x < y and specifically if `rateAccumulator` was updated in between the blocks x and y
        - Invariant I: sum of `rateAccumulator * normalDebt` across all positions = `rateAccumulator * totalNormalDebt` at any block x in which all positions (and their `rateAccumulator`) were updated
        - Invariant J: `snapshotRateAccumulator` is equal to `rateAccumulator` post all IRS updates
    */

    // - Invariant A: `rebateFactor` <= 1 (for all positions)
    function assert_invariant_IRM_A(CDPVault vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (InterestRateModel.PositionIRS memory userIRS) = vault.getPositionIRS(user);
            
            assertGe(userIRS.rebateFactor, 0);
            assertLe(userIRS.rebateFactor, WAD);
        }
    }

    // - Invariant B: 1 <= `rateAccumulator` (for all positions)
    function assert_invariant_IRM_B(CDPVault vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (CDPVault.PositionIRS memory userIRS) = vault.getPositionIRS(user);
            
            assertGe(userIRS.snapshotRateAccumulator, WAD);
        }
    }

    // - Invariant C: sum of `accruedRebate` across all PositionIRS's = `globalAccruedRebate` - assuming all PositionIRS's are up to date
    function assert_invariant_IRM_C(CDPVault vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        uint256 accruedRebateAccumulator = 0;

        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 accruedRebate,) = vault.virtualIRS(user);
            accruedRebateAccumulator += accruedRebate;
        }

        (, , uint256 globalAccruedRebate) = vault.virtualIRS(address(0));
        assertEq(accruedRebateAccumulator, globalAccruedRebate);
    }

    // - Invariant D: sum of `accruedRebate` across all PositionIRS's <= `globalAccruedRebate` - assuming some PositionIRS's are not up to date
    function assert_invariant_IRM_D(CDPVault vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        uint256 accruedRebateAccumulator = 0;

        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            CDPVault.PositionIRS memory positionIRS = vault.getPositionIRS(user);
            accruedRebateAccumulator += positionIRS.accruedRebate ;
        }

        (, , uint256 globalAccruedRebate) = vault.virtualIRS(address(0));
        assertGe(globalAccruedRebate, accruedRebateAccumulator);
    }

    // - Invariant E: `averageRebate` <= `totalNormalDebt`
    function assert_invariant_IRM_E(CDPVault vault) public {
        CDPVault.GlobalIRS memory globalIRS = vault.getGlobalIRS();
        assertGe(vault.totalNormalDebt(), globalIRS.averageRebate);
    }

    // - Invariant F: `accruedRebate` <= `normalDebt * deltaRateAccumulator`
    function assert_invariant_IRM_F(CDPVault vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            CDPVault.PositionIRS memory positionIRS = vault.getPositionIRS(user);
            (, uint256 normalDebt) = vault.positions(user);
            (bytes32 prevValue, bytes32 value) = handler.getTrackedValue(getValueKey(user, SNAPSHOT_RATE_ACCUMULATOR));
            uint256 deltaRateAccumulator = uint256(value) - uint256(prevValue);
            assertEq(positionIRS.snapshotRateAccumulator, uint256(value));
            assertGe(wmul(normalDebt, deltaRateAccumulator), positionIRS.accruedRebate);
        }
    }

    // - Invariant G: `globalAccruedRebate` <= `totalNormalDebt * deltaRateAccumulator`
    function assert_invariant_IRM_G(CDPVault vault, BaseHandler handler) public {
        (bytes32 prevValue, bytes32 value) = handler.getTrackedValue(RATE_ACCUMULATOR);
        uint256 deltaRateAccumulator = uint256(value) - uint256(prevValue);
        CDPVault.GlobalIRS memory globalIRS = vault.getGlobalIRS();

        assertEq(globalIRS.rateAccumulator, uint256(value));
        assertGe(wmul(vault.totalNormalDebt(), deltaRateAccumulator), globalIRS.globalAccruedRebate);
    }
    
    // - Invariant H: `rateAccumulator` at block x <= `rateAccumulator` at block y, if x < y and specifically if `rateAccumulator` was updated in between the blocks x and y
    function assert_invariant_IRM_H(BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (bytes32 prevValue, bytes32 value) = handler.getTrackedValue(getValueKey(user, SNAPSHOT_RATE_ACCUMULATOR));
            assertGe(uint256(value), uint256(prevValue));
        }
    }

    // - Invariant I: sum of `rateAccumulator * normalDebt` across all positions = `rateAccumulator * totalNormalDebt` at any block x in which all positions (and their `rateAccumulator`) were updated
    function assert_invariant_IRM_I(CDPVault_TypeAWrapper vault, BaseHandler handler) public {
        uint256 debtAccumulator;
        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt) = vault.positions(user);
            (uint64 rateAccumulator, , ) = vault.virtualIRS(user);
            debtAccumulator += calculateDebt(normalDebt, rateAccumulator, 0);
        }

        CDPVault.GlobalIRS memory globalIRS = vault.getGlobalIRS();
        assertEq(wmul(globalIRS.rateAccumulator, vault.totalNormalDebt()), debtAccumulator);
    }

    // - Invariant J: `snapshotRateAccumulator` is equal to `rateAccumulator` post all IRS updates
    function assert_invariant_IRM_J(CDPVault_TypeAWrapper vault, BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        (uint64 rateAccumulator, ,) = vault.virtualIRS(address(0));

        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            vault.modifyCollateralAndDebt(user,user,user,0,0);
            CDPVault.PositionIRS memory positionIRS = vault.getPositionIRS(user);
            assertEq(rateAccumulator, positionIRS.snapshotRateAccumulator);
        }
    }

    /// ======== Liquidation Invariant Asserts ======== ///
    /*
    Liquidation Invariants:
        - Invariant A: a liquidation should always make the position more safe
        - Invariant B: position health after liquidation is smaller or equal to target health factor
        - Invariant C: liquidator should never pay more than `repayAmount`
        - Invariant D: credit paid should never be larger than `debt` / `liquidationPenalty`
        - Invariant E: `accruedBadDebt` should never exceed the sum of `debt` of liquidated positions
        - Invariant F: `position.collateral` should be zero if `position.normalDebt` is zero for a liquidated position
        - Invariant G: delta debt should be equal to credit paid * `liquidationPenalty`
    */

    // - Invariant A: a liquidation should always make the position more safe
    function assert_invariant_Liquidation_A(LiquidateHandler handler) public {
        uint256 userCount = handler.liquidatedPositionsCount();
        for (uint256 i = 0; i < userCount; ++i) {
            address position = handler.liquidatedPositions(i);
            bool isSafeLiquidation = handler.getIsSafeLiquidation(position);
            (uint256 prevHealthRation, uint256 currentHealthRatio) = handler.getPositionHealth(position);
            
            if (isSafeLiquidation) assertGe(currentHealthRatio, prevHealthRation);
        }
    }


    // - Invariant B: position health after liquidation is smaller or equal to target health factor 
    // or fully liquidated
    function assert_invariant_Liquidation_B(CDPVault_TypeAWrapper vault, LiquidateHandler handler) public {
        uint256 userCount = handler.liquidatedPositionsCount();
        (, , uint64 targetHealthFactor) = vault.liquidationConfig();
        for (uint256 i = 0; i < userCount; ++i) {
            address position = handler.liquidatedPositions(i);
            (, uint256 currentHealthRatio) = handler.getPositionHealth(position);
            if(currentHealthRatio == type(uint256).max) continue;
            
             assertLe(currentHealthRatio, targetHealthFactor);
        }
    }

    // - Invariant C: liquidator should never pay more than `repayAmount`
    function assert_invariant_Liquidation_C(LiquidateHandler handler) public {
        uint256 userCount = handler.liquidatedPositionsCount();
        uint256 totalRepayAmount = 0;
        for (uint256 i = 0; i < userCount; ++i) {
            address position = handler.liquidatedPositions(i);
            uint256 repayAmount = handler.getRepayAmount(position);
            totalRepayAmount += repayAmount;
        }

        uint256 creditPaid = handler.creditPaid();
        assertLe(creditPaid, totalRepayAmount);
    }

    // - Invariant D: credit paid should never be larger than `debt` / `liquidationPenalty`
    function assert_invariant_Liquidation_D(CDPVault_TypeAWrapper vault, LiquidateHandler handler) public {
        (uint64 liquidationPenalty, ,) = vault.liquidationConfig();
        uint256 userCount = handler.liquidatedPositionsCount();
        if(userCount == 0) return;
        
        uint256 totalDebt = handler.preLiquidationDebt();
        uint256 creditPaid = handler.creditPaid();
        assertLe(creditPaid, wdiv(totalDebt, liquidationPenalty));
    }

    // - Invariant E: `accruedBadDebt` should never exceed the sum of `debt` of liquidated positions
    function assert_invariant_Liquidation_E(LiquidateHandler handler) public {
        uint256 userCount = handler.liquidatedPositionsCount();
        if(userCount == 0) return;
        uint256 totalDebt = handler.preLiquidationDebt();
        uint256 accruedBadDebt = handler.accruedBadDebt();
        assertGe(totalDebt, accruedBadDebt);
    }

    // - Invariant F: `position.collateral` should be zero if `position.normalDebt` is zero for a liquidated position
    function assert_invariant_Liquidation_F(CDPVault_TypeAWrapper vault, LiquidateHandler handler) public {
        uint256 userCount = handler.liquidatedPositionsCount();
        if(userCount == 0) return;
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.liquidatedPositions(i);
            (uint256 collateral, uint256 normalDebt) = vault.positions(user);
            if (collateral == 0) {
                assertEq(normalDebt, 0);
            }
        }
    }

    // - Invariant G: delta debt should be equal to credit paid * `liquidationPenalty` + badDebt
    function assert_invariant_Liquidation_G(CDPVault_TypeAWrapper vault, LiquidateHandler handler) public {
        uint256 userCount = handler.liquidatedPositionsCount();
        if(userCount == 0) return;
        
        (uint64 liquidationPenalty, ,) = vault.liquidationConfig();
        uint256 creditPaid = handler.creditPaid();
        uint256 deltaDebt = handler.preLiquidationDebt() - handler.postLiquidationDebt();
        uint256 accruedBadDebt = handler.accruedBadDebt();

        assertApproxEqAbs(deltaDebt, wmul(creditPaid,liquidationPenalty) + accruedBadDebt, EPSILON);
    }
    
    /// ======== Helper Functions ======== ///

    function filterSenders() internal virtual {
        excludeSender(address(cdm));
        excludeSender(address(stablecoin));
        excludeSender(address(flashlender));
        excludeSender(address(minter));
        excludeSender(address(buffer));
        excludeSender(address(token));
        excludeSender(address(oracle));
    }

    function createCDPVaultWrapper(
        IERC20 token_,
        uint256 debtCeiling,
        uint128 debtFloor,
        uint64 liquidationRatio,
        uint64 liquidationPenalty,
        uint64 liquidationDiscount,
        uint64 targetHealthFactor,
        uint256 baseRate,
        uint64 limitOrderFloor,
        uint256 protocolFee
    ) internal returns (CDPVault_TypeAWrapper cdpVaultA) {
        CDPVault_TypeA_Factory factory = new CDPVault_TypeA_Factory(
            new CDPVault_TypeAWrapper_Deployer(),
            address(new CDPVaultUnwinderFactory()),
            address(this),
            address(this),
            address(this)
        );
        cdm.grantRole(ACCOUNT_CONFIG_ROLE, address(factory));

        cdpVaultA = CDPVault_TypeAWrapper(
            factory.create(
                CDPVaultConstants({
                    cdm: cdm,
                    oracle: oracle,
                    buffer: buffer,
                    token: token_,
                    tokenScale: 10**IERC20Metadata(address(token_)).decimals(),
                    protocolFee: protocolFee,
                    targetUtilizationRatio: 0,
                    maxUtilizationRatio: uint64(WAD),
                    minInterestRate: uint64(WAD),
                    maxInterestRate: uint64(1000000021919499726),
                    targetInterestRate: uint64(1000000015353288160),
                    rebateRate: uint128(WAD),
                    maxRebate: uint128(WAD)
                }),
                CDPVault_TypeAConfig({
                    liquidationPenalty: liquidationPenalty,
                    liquidationDiscount: liquidationDiscount,
                    targetHealthFactor: targetHealthFactor
                }),
                CDPVaultConfig({
                    debtFloor: debtFloor,
                    limitOrderFloor: limitOrderFloor,
                    liquidationRatio: liquidationRatio,
                    globalLiquidationRatio: 0,
                    baseRate: baseRate,
                    roleAdmin: address(this),
                    vaultAdmin: address(this),
                    tickManager: address(this),
                    vaultUnwinder: address(this),
                    pauseAdmin: address(this)
                }),
                debtCeiling
            )
        );

        buffer.grantRole(BAIL_OUT_QUALIFIER_ROLE, address(cdpVaultA));
    }
}