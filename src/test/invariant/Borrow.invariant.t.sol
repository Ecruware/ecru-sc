// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {BorrowHandler} from "./handlers/BorrowHandler.sol";

import {wmul} from "../../utils/Math.sol";
import {TICK_MANAGER_ROLE, VAULT_CONFIG_ROLE} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {CDPVault_TypeAWrapper} from "./CDPVault_TypeAWrapper.sol";

/// @title BorrowInvariantTest
contract BorrowInvariantTest is InvariantTestBase {
    CDPVault_TypeAWrapper internal cdpVault;
    BorrowHandler internal borrowHandler;

    /// ======== Setup ======== ///

    function setUp() public virtual override {
        super.setUp();

        cdpVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            targetHealthFactor: 1.05 ether, 
            baseRate: 1000000021919499726,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });

        borrowHandler = new BorrowHandler(cdpVault, this, new GhostVariableStorage());
        deal(
            address(token),
            address(borrowHandler),
            borrowHandler.collateralReserve() + borrowHandler.creditReserve()
        );

        cdpVault.grantRole(VAULT_CONFIG_ROLE, address(borrowHandler));
        // prepare price ticks
        cdpVault.grantRole(TICK_MANAGER_ROLE, address(borrowHandler));
        borrowHandler.createPriceTicks();

        _setupCreditVault();

        excludeSender(address(cdpVault));
        excludeSender(address(borrowHandler));

        vm.label({account: address(cdpVault), newLabel: "CDPVault_TypeA"});
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

    function test_invariant_underflow() public {
        vm.prank(0x0000000000000000000000000000000000002AE0);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639935, 64073496331013554460115129233211550638857731325853253351461217848571);
        vm.prank(0xBE9138155ec11BC0c42911EEB97dE5900d751c32);
        borrowHandler.createLimitOrder(1249509010451361118228348667766698983416497822614494131096305815599, 340282366920938463463374607431768211454);
        vm.prank(0xCb287d45325F8276eB4377b29c1daDA5Acb022F9);
        borrowHandler.changeBaseRate(2547067);
        vm.prank(0x0000000000000000000000000000000000001B20);
        borrowHandler.repay(2, 123123);
    }

    function test_invariant_assert_C() public {
        vm.prank(0x2033393238383100000000000000000000000000);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639934, 1);
        vm.prank(0x00000000000000000000000000000000000031E6);
        borrowHandler.createLimitOrder(64419735570928963745674861590843057417032700, 2718666581042647783001011672510914897 );
        vm.prank(0xF4f588d331eBfa28653d42AE832DC59E38C9798f);
        borrowHandler.borrow(20284758795063, 1);
        // vm.prank(0xC66E1FEcd26a1B095A505d4e7fbB95C0b0847a75);
        // borrowHandler.changeBaseRate(5282);
        vm.prank(0x000000000000000000000000000000000000226d);
        borrowHandler.partialRepay(56250000000000000000, 22486, 8531);

        this.invariant_IRM_C();

        (uint256 collateral, uint256 normalDebt) = cdpVault.positions(0x2033393238383100000000000000000000000000);
        emit log_named_uint("collateral", collateral);
        emit log_named_uint("normalDebt", normalDebt);
        (collateral, normalDebt) = cdpVault.positions(0xF4f588d331eBfa28653d42AE832DC59E38C9798f);
        emit log_named_uint("collateral", collateral);
        emit log_named_uint("normalDebt", normalDebt);
    }

    function test_invariant_assert_I() public {
        vm.prank(0x0000000000000000000000000000000000000d37);
        borrowHandler.cancelLimitOrder(744265621924648733437416138983875408283445376495);
        vm.prank(0x00000000000000007061727469616c5265706178);
        borrowHandler.changeLimitOrder(3, 1);
        vm.prank(0x000000000000000000000001ECa955e9b65dffFf);
        borrowHandler.borrow(3, 2);
        vm.prank(0x000000000000000000000000000000000000051e);
        borrowHandler.borrow(923, 1250000000000000000);
        vm.prank(0x3c25DB85721D91b4f85B6eD0D7d77C8Ef74e5eD2);
        borrowHandler.repay(199157378116752083179140896199694938594619641959747469214626433438437081610, 115792089237316195423570985008687907853269984665640564039457584007913129639933);

        this.invariant_IRM_I();
    }

    function test_invariant_revert() public {
        vm.prank(0x000000000000000000000000000000000000070c);
        borrowHandler.borrow(27506448, 608942538058671644789060545928430220646693377654311092072444502595500);
        vm.prank(0x00000000000000000000000000000000000046ec);
        borrowHandler.createLimitOrder(18944, 340282366920937743535374607430908993651);
        vm.prank(0x0000000000000000000000000000000000001C04);
        borrowHandler.borrow(3, 12724938757250675139334);
        vm.prank(0x00000000000000000000000000000000F3b7DEac);
        borrowHandler.borrow(2, 586335151241979564644);
        vm.prank(0x0000000000000001027E7154D08133342B1081e6);
         borrowHandler.repay(30, 963290553460724356668903);
    }

    /// ======== CDPVault Invariant Tests ======== ///

    function invariant_CDPVault_R_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_A(cdpVault, borrowHandler);
    }

    function invariant_CDPVault_R_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_B(cdpVault, borrowHandler);
    }

    function invariant_CDPVault_R_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_C(cdpVault, borrowHandler);
    }

    /// ======== Interest Rate Model Invariant Tests ======== ///

    function invariant_IRM_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_A(cdpVault, borrowHandler);
    }

    function invariant_IRM_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_B(cdpVault, borrowHandler);
    }

    function invariant_IRM_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_C(cdpVault, borrowHandler);
    }

    function invariant_IRM_D() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_D(cdpVault, borrowHandler);
    }

    function invariant_IRM_E() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_E(cdpVault);
    }

    function invariant_IRM_F() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_F(cdpVault, borrowHandler);
    }

    function invariant_IRM_G() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_G(cdpVault, borrowHandler);
    }

    function invariant_IRM_H() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_H(borrowHandler);
    }
    
    function invariant_IRM_I() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_I(cdpVault, borrowHandler);
    }

    function invariant_IRM_J() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_J(cdpVault, borrowHandler);
    }
}
