// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {BorrowHandler} from "./handlers/BorrowHandler.sol";

import {wmul} from "../../utils/Math.sol";
import {TICK_MANAGER_ROLE} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {CDPVault_TypeAWrapper} from "./CDPVault_TypeAWrapper.sol";

/// @title BorrowInvariantTest
contract BorrowInvariantTest is InvariantTestBase {
    CDPVault_TypeAWrapper internal cdpVaultR;
    BorrowHandler internal borrowHandler;

    /// ======== Setup ======== ///

    function setUp() public virtual override {
        super.setUp();

        cdpVaultR = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            targetHealthFactor: 1.05 ether, 
            baseRate: 1 ether,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });

        borrowHandler = new BorrowHandler(cdpVaultR, this, new GhostVariableStorage());
        deal(
            address(token),
            address(borrowHandler),
            borrowHandler.collateralReserve() + borrowHandler.creditReserve()
        );

        // prepare price ticks
        cdpVaultR.grantRole(TICK_MANAGER_ROLE, address(borrowHandler));
        borrowHandler.createPriceTicks();

        _setupCreditVault();

        excludeSender(address(cdpVaultR));
        excludeSender(address(borrowHandler));

        vm.label({account: address(cdpVaultR), newLabel: "CDPVault_TypeA"});
        vm.label({
            account: address(borrowHandler),
            newLabel: "BorrowHandler"
        });

        (bytes4[] memory selectors, ) = borrowHandler.getTargetSelectors();
        targetSelector(
            FuzzSelector({
                addr: address(borrowHandler),
                selectors: selectors
            })
        );

        targetContract(address(borrowHandler));
    }

    // deploy a reserve vault and create credit for the borrow handler
    function _setupCreditVault() private {
        CDPVault_TypeA creditVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: borrowHandler.creditReserve(), 
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
        if(initialGlobalDebtCeiling != uint256(type(int256).max)){
            setGlobalDebtCeiling(
                initialGlobalDebtCeiling + borrowHandler.creditReserve()
            );
        }
        
        vm.startPrank(address(borrowHandler));
        token.approve(address(creditVault), borrowHandler.creditReserve());
        creditVault.deposit(
            address(borrowHandler),
            borrowHandler.creditReserve()
        );
        int256 debt = int256(wmul(liquidationPrice(creditVault), borrowHandler.creditReserve()));
        creditVault.modifyCollateralAndDebt(
            address(borrowHandler),
            address(borrowHandler),
            address(borrowHandler),
            int256(borrowHandler.creditReserve()),
            debt
        );
        vm.stopPrank();
    }

    /// ======== CDPVault Invariant Tests ======== ///

    function invariant_CDPVault_R_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_A(cdpVaultR, borrowHandler);
    }

    function invariant_CDPVault_R_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_B(cdpVaultR, borrowHandler);
    }

    function invariant_CDPVault_R_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_C(cdpVaultR, borrowHandler);
    }

    /// ======== Interest Rate Model Invariant Tests ======== ///

    function invariant_IRM_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_A(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_B(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_C(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_D() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_D(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_E() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_E(cdpVaultR);
    }

    function invariant_IRM_F() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_F(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_G() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_G(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_H() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_H(borrowHandler);
    }
    
    function invariant_IRM_I() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_I(cdpVaultR, borrowHandler);
    }

    function invariant_IRM_J() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_J(cdpVaultR, borrowHandler);
    }
}
