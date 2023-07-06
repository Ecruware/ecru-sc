// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {CDM} from "../../CDM.sol";
import {Minter} from "../../Minter.sol";

contract MinterTest is TestBase {

    address user = makeAddr("user");
    address vault = makeAddr("vault");
    uint256 vaultCeiling = initialGlobalDebtCeiling;

    function labelContracts() internal override {
        vm.label({account: address(cdm), newLabel: "CDM"});
        vm.label({account: address(stablecoin), newLabel: "Stablecoin"});
        vm.label({account: address(minter), newLabel: "Minter"});
    }

    function setUp() public override {
        setCurrentTimestamp(block.timestamp);
        createCore();
        labelContracts();
        cdm.setParameter(vault, "debtCeiling", vaultCeiling);
    }

    /// ======== enter tests ======== ///

    function test_enter() public {
        _mintStablecoin(address(this), 100 ether);

        // burn stablecoin for credit
        stablecoin.approve(address(minter), 100 ether);
        minter.enter(address(this), 100 ether);

        assertEq(stablecoin.balanceOf(address(this)), 0 ether);
        assertEq(credit(address(this)), 100 ether);
    }

    function test_enter_to_user() public {
        _mintStablecoin(address(this), 100 ether);

        // burn stablecoin for credit
        stablecoin.approve(address(minter), 100 ether);
        minter.enter(user, 100 ether);

        // check enter to user was successful
        assertEq(stablecoin.balanceOf(address(this)), 0 ether);
        assertEq(credit(user), 100 ether);

        // check no unexpected left over amounts
        assertEq(stablecoin.balanceOf(user), 0 ether);
        assertEq(credit(address(this)), 0 ether);
    }

    function test_fail_enter_insufficient_stablecoin() public {
        _mintStablecoin(address(this), 100 ether);

        // burn stablecoin for credit
        stablecoin.approve(address(minter), 101 ether);
        vm.expectRevert();
        minter.enter(address(this), 101 ether);
    }

    /// ======== exit tests ======== ///

    function test_exit() public {
        createCredit(address(this), 100 ether);

        // mint stablecoin from credit
        cdm.modifyPermission(address(minter), true);
        minter.exit(address(this), 100 ether);

        assertEq(stablecoin.balanceOf(address(this)), 100 ether);
        assertEq(credit(address(this)), 0 ether);
    }

    function test_exit_to_user() public {
        createCredit(address(this), 100 ether);

        // mint stablecoin from credit
        cdm.modifyPermission(address(minter), true);
        minter.exit(user, 100 ether);

        // check exit to user was successful
        assertEq(stablecoin.balanceOf(user), 100 ether);
        assertEq(credit(address(this)), 0 ether);

        // check no unexpected left over amounts
        assertEq(stablecoin.balanceOf(address(this)), 0 ether);
        assertEq(credit(user), 0 ether);
    }

    function test_fail_exit_no_permission() public {
        createCredit(address(this), 100 ether);

        // mint stablecoin from credit
        vm.expectRevert(CDM.CDM__modifyBalance_noPermission.selector);
        minter.exit(address(this), 100 ether);
    }

    function test_fail_exit_insufficient_credit() public {
        createCredit(address(this), 100 ether);

        // mint stablecoin from credit
        cdm.modifyPermission(address(minter), true);
        vm.expectRevert();
        minter.exit(address(this), 101 ether);
    }

    function test_fail_exit_paused() public {
        createCredit(address(this), 100 ether);

        // mint stablecoin from credit
        cdm.modifyPermission(address(minter), true);
        minter.pause();
        vm.expectRevert("Pausable: paused");
        minter.exit(address(this), 100 ether);
    }

    /// ======== helper functions ======== ///

    function _mintStablecoin(address to, uint256 amount) internal {
        createCredit(address(this), amount);
        cdm.modifyPermission(address(minter), true);
        minter.exit(to, amount);
        cdm.modifyPermission(address(minter), false);
    }
}