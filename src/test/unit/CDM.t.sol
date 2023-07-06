// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {CDM} from "../../CDM.sol";

contract CDMTest is Test {

    CDM cdm;

    uint256 constant globalDebtCeiling = 10_000 ether;
    uint256 constant vaultDebtCeiling = 1_000 ether;

    address vaultA = makeAddr("vaultA"); // debtCeiling > 0
    address vaultB = makeAddr("vaultB"); // debtCeiling = 0
    address vaultC = makeAddr("vaultC"); // debtCeiling = 0

    address me = address(this);

    function balance(address account) internal view returns (int256 balance_) {
        (balance_,) = cdm.accounts(account);
    }

    function setUp() public {
        cdm = new CDM(me, me, me);
        cdm.setParameter("globalDebtCeiling", 10_000 ether);
        cdm.setParameter(vaultA, "debtCeiling", vaultDebtCeiling);
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// ======== Configuration tests ======== ///
    
    function test_setParameter() public {
        cdm.setParameter("globalDebtCeiling", 1_000 ether);
        assertEq(cdm.globalDebtCeiling(), 1_000 ether);
    }

    function test_fail_setParameter() public {
        vm.expectRevert(CDM.CDM__setParameter_unrecognizedParameter.selector);
        cdm.setParameter("xyz", 1_000 ether);
    }

    function test_fail_setParameter_debtCeiling() public {
        vm.expectRevert(CDM.CDM__setParameter_debtCeilingExceedsMax.selector);
        cdm.setParameter("globalDebtCeiling", type(uint256).max);
    }

    function test_setParameter2() public {
        cdm.setParameter(vaultB, "debtCeiling", 10 ether);
        (, uint256 debtCeiling) = cdm.accounts(vaultB);
        assertEq(debtCeiling, 10 ether);
    }

    function test_fail_setParameter2() public {
        vm.expectRevert(CDM.CDM__setParameter_unrecognizedParameter.selector);
        cdm.setParameter(vaultB, "xyz", 10 ether);
    }

    function test_fail_setParameter2_debtCeiling() public {
        vm.expectRevert(CDM.CDM__setParameter_debtCeilingExceedsMax.selector);
        cdm.setParameter(vaultB, "debtCeiling", type(uint256).max);
    }

    /// ======== Credit tests ======== ///

    function test_modifyBalance_increaseDebt() public {
        vm.prank(vaultA);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
        assertEq(cdm.globalDebt(), 100 ether);
        assertEq(balance(vaultA), -100 ether);
        assertEq(balance(vaultB), 100 ether);

        vm.prank(vaultA);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
        assertEq(cdm.globalDebt(), 200 ether);
        assertEq(balance(vaultA), -200 ether);
        assertEq(balance(vaultB), 200 ether);
    }

    function testFail_modifyBalance_noPermission() public {
        vm.prank(vaultB);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
        assertEq(cdm.globalDebt(), 100 ether);
        assertEq(balance(vaultA), -100 ether);
        assertEq(balance(vaultB), 100 ether);
    }

    function test_modifyBalance_permission() public {
        vm.prank(vaultA);
        cdm.modifyPermission(vaultB, true);

        vm.prank(vaultB);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
        assertEq(cdm.globalDebt(), 100 ether);
        assertEq(balance(vaultA), -100 ether);
        assertEq(balance(vaultB), 100 ether);
    }

    function test_modifyBalance_decreaseDebt() public {
        vm.prank(vaultA);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);

        vm.prank(vaultB);
        cdm.modifyBalance(vaultB, vaultA, 50 ether);
        assertEq(cdm.globalDebt(), 50 ether);
        assertEq(balance(vaultA), -50 ether);
        assertEq(balance(vaultB), 50 ether);

        vm.prank(vaultB);
        cdm.modifyBalance(vaultB, vaultA, 50 ether);
        assertEq(cdm.globalDebt(), 0 ether);
        assertEq(balance(vaultA), 0 ether);
        assertEq(balance(vaultB), 0 ether);
    }

    function test_modifyBalance_decreaseDebt_aboveZero() public {
        vm.prank(vaultA);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
        
        vm.prank(vaultB);
        cdm.modifyBalance(vaultB, vaultA, 50 ether);
        assertEq(cdm.globalDebt(), 50 ether);
        assertEq(balance(vaultA), -50 ether);
        assertEq(balance(vaultB), 50 ether);

        cdm.setParameter(vaultC, "debtCeiling", vaultDebtCeiling); 
        vm.prank(vaultC);
        cdm.modifyBalance(vaultC, vaultA, 100 ether);
        assertEq(cdm.globalDebt(), 100 ether);
        assertEq(balance(vaultA), 50 ether);
        assertEq(balance(vaultC), -100 ether);
    }

    function test_modifyBalance_transferCredit() public {
        vm.prank(vaultA);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);

        vm.prank(vaultB);
        cdm.modifyBalance(vaultB, vaultC, 50 ether);
        assertEq(cdm.globalDebt(), 100 ether);
        assertEq(balance(vaultA), -100 ether);
        assertEq(balance(vaultB), 50 ether);
        assertEq(balance(vaultC), 50 ether);
    }

    function test_modifyBalance_fail_vaultDebtCeilingExceeded() public {
        uint256 vaultDebtCeiling_ = 50 ether;
        cdm.setParameter(vaultA, "debtCeiling", vaultDebtCeiling_);

        vm.prank(vaultA);
        vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
    }

    function test_modifyBalance_fail_globalDebtCeilingExceeded() public {
        uint256 globalDebtCeiling_ = 50 ether;
        cdm.setParameter("globalDebtCeiling", globalDebtCeiling_);

        vm.prank(vaultA);
        vm.expectRevert(CDM.CDM__modifyBalance_globalDebtCeilingExceeded.selector);
        cdm.modifyBalance(vaultA, vaultB, 100 ether);
    }
}


