// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {LiquidateHandler} from "./handlers/LiquidateHandler.sol";

import {wmul} from "../../utils/Math.sol";
import {TICK_MANAGER_ROLE} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {CDPVault_TypeAWrapper} from "./CDPVault_TypeAWrapper.sol";

/// @title LiquidateInvariantTest
contract LiquidateInvariantTest is InvariantTestBase {
    CDPVault_TypeAWrapper internal vault;
    LiquidateHandler internal liquidateHandler;

    uint64 public liquidationRatio = 1.25 ether;
    uint64 public targetHealthFactor = 1.10 ether;

    /// ======== Setup ======== ///

    function setUp() public virtual override {
        super.setUp();

        vault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: liquidationRatio, 
            liquidationPenalty: 0.99 ether,
            liquidationDiscount: 0.98 ether, 
            targetHealthFactor: targetHealthFactor, 
            baseRate: BASE_RATE_1_005,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });

        CDPVault_TypeA.GlobalIRS memory globalIRS = vault.getGlobalIRS();
        assertEq(globalIRS.baseRate, int64(BASE_RATE_1_005));

        liquidateHandler = new LiquidateHandler(vault, this, new GhostVariableStorage(), liquidationRatio, targetHealthFactor);

        _setupVaults();


        // prepare price ticks
        vault.grantRole(TICK_MANAGER_ROLE, address(liquidateHandler));

        excludeSender(address(vault));
        excludeSender(address(liquidateHandler));

        vm.label({account: address(vault), newLabel: "CDPVault_TypeA"});
        vm.label({
            account: address(liquidateHandler),
            newLabel: "LiquidateHandler"
        });

        (bytes4[] memory selectors, ) = liquidateHandler.getTargetSelectors();
        targetSelector(
            FuzzSelector({
                addr: address(liquidateHandler),
                selectors: selectors
            })
        );

        targetContract(address(liquidateHandler));
    }

    // deploy a reserve vault and create credit for the borrow handler
    function _setupVaults() private {
        deal(
            address(token),
            address(liquidateHandler),
            liquidateHandler.collateralReserve() + liquidateHandler.creditReserve()
        );

        // prepare collateral
        vm.startPrank(address(liquidateHandler));
        token.approve(address(vault), liquidateHandler.collateralReserve());
        vault.deposit(address(liquidateHandler), liquidateHandler.collateralReserve());
        cdm.modifyPermission(address(vault),true);        
        vm.stopPrank();

        CDPVault_TypeA creditVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: liquidateHandler.creditReserve(), 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            targetHealthFactor: 1.05 ether, 
            baseRate: 1 ether,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });

        // increase the global debt ceiling
        setGlobalDebtCeiling(
            initialGlobalDebtCeiling + liquidateHandler.creditReserve()
        );

        vm.startPrank(address(liquidateHandler));
        token.approve(address(creditVault), liquidateHandler.creditReserve());
        creditVault.deposit(
            address(liquidateHandler),
            liquidateHandler.creditReserve()
        );

        int256 debt = int256(wmul(liquidationPrice(creditVault), liquidateHandler.creditReserve()));
        creditVault.modifyCollateralAndDebt(
            address(liquidateHandler),
            address(liquidateHandler),
            address(liquidateHandler),
            int256(liquidateHandler.creditReserve()),
            debt
        );
        vm.stopPrank();
    }

    function invariant_Liquidation_A() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_A(liquidateHandler); }

    function invariant_Liquidation_B() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_B(vault, liquidateHandler); }

    function invariant_Liquidation_C() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_C(liquidateHandler); }

    function invariant_Liquidation_D() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_D(vault, liquidateHandler); }

    function invariant_Liquidation_E() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_E(liquidateHandler); }

    function invariant_Liquidation_F() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_F(vault, liquidateHandler); }
    
    function invariant_Liquidation_G() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_G(vault, liquidateHandler); }
 }
