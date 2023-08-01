// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {ICDPVault} from "../../interfaces/ICDPVault.sol";
import {IPermission} from "../../interfaces/IPermission.sol";
import {ICDPVaultUnwinder} from "../../interfaces/ICDPVaultUnwinder.sol";

import {WAD, wmul, wdiv} from "../../utils/Math.sol";
import {CDM} from "../../CDM.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {CDPVaultUnwinder, CDPVaultUnwinderFactory} from "../../CDPVaultUnwinder.sol";

contract PositionOwner {
    constructor(IPermission vault) {
        // Allow Proxy to modify Position
        vault.modifyPermission(msg.sender, true);
    }
}

contract CDPVaultUnwinderTest is TestBase {

    function setUp() public override {
        super.setUp();
    }

    function _virtualDebt(CDPVault_TypeA vault, address position) internal returns (uint256) {
        (, uint256 normalDebt) = vault.positions(position);
        (uint64 rateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(position);
        return wmul(rateAccumulator, normalDebt) - accruedRebate;
    }

    function test_deployUnwinder() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        assertTrue(address(unwinder) != address(0));
    }

    function test_deployUnwinder_revertsIfAlreadyDeployed() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        vm.expectRevert(CDPVaultUnwinderFactory.CDPVaultUnwinderFactory__deployVaultUnwinder__alreadyDeployed.selector);
        cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
    }

    function test_deployUnwinder_revertsIfInsufficientTimePassed() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        // wait time for unwinder is 2 weeks
        vm.warp(block.timestamp + 1 weeks);

        vm.expectRevert(CDPVaultUnwinderFactory.CDPVaultUnwinderFactory__deployVaultUnwinder_notUnwindable.selector);
        cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
    }

    function test_redeemCredit() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        cdm.modifyPermission(address(unwinder), true);

        unwinder.redeemCredit(positionA, address(this), address(this), 50 ether);
        assertEq(unwinder.redeemCredit(positionA, address(this), address(this), 50 ether), 75 ether);
    }

    function test_redeemCredit_revertsIfNotWithinPeriod() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        cdm.modifyPermission(address(unwinder), true);

        // skip the auction period
        vm.warp(block.timestamp + 2 weeks);
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redeemCredit_notWithinPeriod.selector);
        unwinder.redeemCredit(positionA, address(this), address(this), 50 ether);
    }

    function test_redeemCredit_revertsIfNoCollateral() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        address positionA = address(new PositionOwner(vault));
        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        cdm.modifyPermission(address(unwinder), true);

        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redeemCredit_noCollateral.selector);
        unwinder.redeemCredit(positionA, address(this), address(this), 50 ether);
    }

    function test_redeemCredit_revertsIfNoPermission() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        cdm.modifyPermission(address(unwinder), true);

        vm.prank(address(0x321));
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redeemCredit_noPermission.selector);
        unwinder.redeemCredit(positionA, address(this), address(this), 50 ether);
    }

    function test_redeemCredit_revertsOnRepaid() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);

        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        cdm.modifyPermission(address(unwinder), true);

        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redeemCredit_repaid.selector);
        unwinder.redeemCredit(positionA, address(this), address(this), 201 ether);
    }

     function test_startAuction() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        assertEq(debt(address(vault)), 100 ether);

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(positionA, address(this), address(this), 50 ether), 75 ether);
        assertEq(credit(address(this)), 150 ether);
        assertEq(debt(address(vault)), 50 ether);
        assertEq(credit(address(vault)), 0);

        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        assertEq(unwinder.totalDebt(), 150 ether);
        (bool needsRedo, uint256 price, uint256 cashToSell, uint256 debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, wmul(uint256(1 ether), uint256(1.1 ether)));
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);        
    }

    function test_startAuction_revertsIfNotInPeriod() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 1 weeks);
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__startAuction_notWithinPeriod.selector);
        unwinder.startAuction();
    }

    function test_startAuction_revertsIfAlreadyStarted() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        assertEq(debt(address(vault)), 100 ether);

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__startAuction_alreadyStarted.selector);
        unwinder.startAuction();
    }

    function test_startAuction_revertsOnNoCash() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__startAuction_noCash.selector);
        unwinder.startAuction();
    }

    function test_redoAuction() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        
        bool needsRedo;
        (needsRedo, , , ) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);

        vm.warp(block.timestamp + 3 days);

        (needsRedo, , , ) = unwinder.getAuctionStatus();
        assertEq(needsRedo, true);

        // auction needs to be restarted
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__takeCash_needsReset.selector);
        unwinder.takeCash(200 ether, 1 ether, address(this));

        unwinder.redoAuction();

        (needsRedo, , , ) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);

        (uint256 cashToBuy, uint256 creditToPay) = unwinder.takeCash(200 ether, 1.1 ether, address(this));
        assertEq(cashToBuy, wdiv(200 ether, 1.1 ether));
        assertEq(creditToPay, 200 ether);
    }

    function test_redoAuction_revertsIfAuctionNotRunning() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redoAuction_notRunning.selector);
        unwinder.redoAuction();
    }

    function test_redoAuction_revertsIfAuctionInProgress() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redoAuction_cannotReset.selector);
        unwinder.redoAuction();
    }

    function test_takeCash() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        
        (uint256 cashToBuy, uint256 creditToPay) = unwinder.takeCash(200 ether, 1.1 ether, address(this));
        assertEq(cashToBuy, wdiv(200 ether, 1.1 ether));
        assertEq(creditToPay, 200 ether);
    }

    function test_takeCash_revertsIfAuctionNotRunning() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__takeCash_notRunning.selector);
        unwinder.takeCash(200 ether, 0.9 ether, address(this));
    }

    function test_takeCash_revertsOnLowPrice() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__takeCash_tooExpensive.selector);
        unwinder.takeCash(200 ether, 0.9 ether, address(this));
    }

    function test_redeemShares() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            //2.5% interest rate per second
            token, 250 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 250 ether);
        token.approve(address(vault), 250 ether);
        vault.deposit(address(this), 250 ether);
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 50 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();

        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        unwinder.redeemCredit(position, address(this), address(this), 50 ether);

        vm.warp(block.timestamp + 4 weeks);
        assertEq(unwinder.redeemShares(100 ether), 100 ether);     
    }

    function test_redeemShares_revertsIfNoCredit() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            //2.5% interest rate per second
            token, 250 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 250 ether);
        token.approve(address(vault), 250 ether);
        vault.deposit(address(this), 250 ether);
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 50 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();

        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        unwinder.redeemCredit(position, address(this), address(this), 50 ether);

        vm.warp(block.timestamp + 4 weeks);
        unwinder.redeemShares(100 ether);

        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redeemShares_noCredit.selector);
        unwinder.redeemShares(100 ether);
    }

    function test_redeemShares_returnsZeroIfNoCredit() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            //2.5% interest rate per second
            token, 250 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 250 ether);
        token.approve(address(vault), 250 ether);
        vault.deposit(address(this), 250 ether);
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 50 ether);

        vault.pause();

        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(position, address(this), address(this), 50 ether), 100 ether);

        vm.warp(block.timestamp + 4 weeks);
        assertEq(unwinder.redeemShares(100 ether), 0);
    }

    function test_redeemShares_revertsWithRedeemedShares() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            //2.5% interest rate per second
            token, 250 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 250 ether);
        token.approve(address(vault), 250 ether);
        vault.deposit(address(this), 250 ether);
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 50 ether);

        createCredit(address(this), 10 ether);
        vault.delegateCredit(10 ether);

        vault.pause();

        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(position, address(this), address(this), 50 ether), 100 ether);

        vm.warp(block.timestamp + 4 weeks);
        vm.expectRevert(CDPVaultUnwinder.CDPVaultUnwinder__redeemShares_redeemed.selector);
        unwinder.redeemShares(100 ether);
    }

    function test_unwinding_noLossWithFullRepay() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            //2.5% interest rate per second
            token, 250 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 250 ether);
        token.approve(address(vault), 250 ether);
        vault.deposit(address(this), 250 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 100 ether, 50 ether);
        address positionB = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionB, address(this), address(this), 100 ether, 50 ether);
        address positionC = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionC, address(this), address(this), 50 ether, 35 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();

        vm.expectRevert();
        cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(positionA, address(this), address(this), 50 ether), 100 ether);
        assertEq(unwinder.redeemCredit(positionB, address(this), address(this), 50 ether), 100 ether);
        assertEq(unwinder.redeemCredit(positionC, address(this), address(this), 35 ether), 50 ether);

        assertEq(credit(address(unwinder)), 100 ether);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(vault)), 0);

        vm.expectRevert();
        unwinder.redeemShares(100 ether);

        vm.warp(block.timestamp + 4 weeks);
        assertEq(unwinder.redeemShares(100 ether), 100 ether);

        assertEq(debt(address(unwinder)), 0);
        assertEq(credit(address(unwinder)), 0);
        assertEq(unwinder.totalDebt(), 0);
    }

    function test_unwinding_noLossWithFractionalRepay() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            //2.5% interest per second
            token, 250 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 250 ether);
        token.approve(address(vault), 250 ether);
        vault.deposit(address(this), 250 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 100 ether, 50 ether);
        address positionB = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionB, address(this), address(this), 100 ether, 50 ether);
        address positionC = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionC, address(this), address(this), 50 ether, 35 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();

        vm.expectRevert();
        cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));

        assertEq(debt(address(vault)), 35 ether);

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(positionA, address(this), address(this), 50 ether), 100 ether);
        assertEq(unwinder.redeemCredit(positionB, address(this), address(this), 50 ether), 100 ether);

        assertEq(credit(address(unwinder)), 65 ether);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(vault)), 0);

        vm.expectRevert();
        unwinder.redeemShares(100 ether);

        vm.warp(block.timestamp + 4 weeks);
        assertEq(unwinder.redeemShares(100 ether), 65 ether);

        assertEq(debt(address(unwinder)), 0);
        assertEq(credit(address(unwinder)), 0);
        assertEq(unwinder.totalDebt(), 35 ether);
    }

    function test_unwinding_lossWithFractionalRepay_auction() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        assertEq(debt(address(vault)), 100 ether);

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(positionA, address(this), address(this), 50 ether), 75 ether);
        assertEq(credit(address(this)), 150 ether);
        assertEq(debt(address(vault)), 50 ether);
        assertEq(credit(address(vault)), 0);

        vm.warp(block.timestamp + 2 weeks);

        unwinder.startAuction();
        assertEq(unwinder.totalDebt(), 150 ether);
        (bool needsRedo, uint256 price, uint256 cashToSell, uint256 debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, wmul(uint256(1 ether), uint256(1.1 ether)));
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);

        vm.warp(block.timestamp + 1.5 days);
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, 0);
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);

        vm.warp(block.timestamp + 1);
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, true);
        assertEq(price, 0);
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);

        // needs redo
        vm.expectRevert();
        unwinder.takeCash(200 ether, 1 ether, address(this));

        unwinder.redoAuction();
        (,,uint256 startAt,) = unwinder.auction();
        vm.warp(startAt + 0.75 days);
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, 0.55 ether);
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);

        assertEq(token.balanceOf(address(this)), 75 ether);
        unwinder.takeCash(50 ether, 1 ether, address(this));
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, 0.55 ether);
        assertEq(cashToSell, 175 ether);
        assertEq(debt_, 122.5 ether);
        
        // adjusted for debt floor
        unwinder.takeCash(100 ether, 1 ether, address(this));
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, 0.55 ether);
        assertGt(cashToSell, 175 ether - 100 ether);
        assertEq(debt_, 100 ether);

        // no partial amount if debt is below debt floor
        vm.expectRevert();
        unwinder.takeCash(50 ether, 1 ether, address(this));

        unwinder.takeCash(cashToSell, 1 ether, address(this));
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, 0.55 ether);
        assertEq(cashToSell, 0);
        assertEq(debt_, 26.25 ether); // 122.5 debt - (175 cash * 0.55 USD)

        vm.expectRevert();
        unwinder.redeemShares(100 ether);

        vm.warp(block.timestamp + 2 weeks);
        vm.expectRevert();
        unwinder.startAuction();
        vm.expectRevert();
        unwinder.redoAuction();

        assertEq(unwinder.redeemShares(100 ether), 100 ether - 26.25 ether);
        assertEq(credit(address(this)), 100 ether);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(vault)), 0);
        assertEq(unwinder.totalDebt(), 26.25 ether);
    }

    function test_unwinding_lossWithFractionalRepay_auction_noPrice() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(
            token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, 1000000000780858271, 0, 0
        );

        token.mint(address(this), 300 ether);
        token.approve(address(vault), 300 ether);
        vault.deposit(address(this), 300 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 300 ether, 200 ether);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        vault.pause();
        vm.warp(block.timestamp + 2 weeks);
        ICDPVaultUnwinder unwinder = cdpVaultUnwinderFactory.deployVaultUnwinder(ICDPVault(address(vault)));
        assertEq(debt(address(vault)), 100 ether);

        cdm.modifyPermission(address(unwinder), true);
        assertEq(unwinder.redeemCredit(positionA, address(this), address(this), 50 ether), 75 ether);
        assertEq(credit(address(this)), 150 ether);
        assertEq(debt(address(vault)), 50 ether);
        assertEq(credit(address(vault)), 0);

        vm.warp(block.timestamp + 2 weeks);

        vm.etch(address(oracle), new bytes(0));

        unwinder.startAuction();
        assertEq(unwinder.totalDebt(), 150 ether);
        (bool needsRedo, uint256 price, uint256 cashToSell, uint256 debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, unwinder.totalDebt() * uint256(1.1 ether) / token.balanceOf(address(unwinder)));
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);

        vm.warp(block.timestamp + 1.5 days);
        (needsRedo, price, cashToSell, debt_) = unwinder.getAuctionStatus();
        assertEq(needsRedo, false);
        assertEq(price, 0);
        assertEq(cashToSell, 225 ether);
        assertEq(debt_, 150 ether);
    }
}
