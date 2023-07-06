// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BaseHandler.sol";
import {InvariantTestBase} from "../InvariantTestBase.sol";

import {CDPVault_TypeAWrapper} from "../CDPVault_TypeAWrapper.sol";

import {min} from "../../../utils/Math.sol";
import {CDM} from "../../../CDM.sol";

contract CDPVault_TypeAHandler is BaseHandler {
    CDPVault_TypeAWrapper public vault;
    CDM public cdm;
    IERC20 public token;

    uint256 public tokenReserve = type(uint256).max;
    uint256 constant public maximumDeposit = 1_000_000 ether;

    constructor(InvariantTestBase testContract_, CDPVault_TypeAWrapper vault_, GhostVariableStorage ghostStorage_) BaseHandler("CDPVault_TypeAHandler", testContract_, ghostStorage_) {
        vault = vault_;
        cdm = CDM(address(vault.cdm()));
        token = vault.token();
    }

    function deposit(address owner, uint256 amountSeed) onlyNonActor(CONTRACTS_CATEGORY, owner) useCurrentTimestamp public {
        trackCallStart(msg.sig);

        addActor(USERS_CATEGORY, owner);
        (uint128 debtFloor, ,) = vault.vaultConfig();
        uint256 amount = bound(amountSeed, debtFloor, min(maximumDeposit, token.balanceOf(address(this))));
        token.approve(address(vault), amount);
        vault.deposit(owner, amount);

        trackCallEnd(msg.sig);
    }

    function withdraw(uint256 fromSeed, address to, uint256 amount) useCurrentTimestamp public {
        trackCallStart(msg.sig);

        address from = getRandomActor(USERS_CATEGORY, fromSeed);
        if(from == address(0) || to == address(0)) return;
            
        amount = bound(amount, 0, vault.cash(from));
        vm.prank(from);
        vault.withdraw(to, amount);

        trackCallEnd(msg.sig);
    }


    function modifyCollateralAndDebt(
        uint256 positionSeed,
        uint256 creditorSeed,
        uint256 collateralizerSeed,
        int256 deltaCollateral,
        int256 deltaNormalDebt, 
        uint256 warpAmount
    ) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        address owner = getRandomActor(USERS_CATEGORY, positionSeed);
        address creditor = getRandomActor(USERS_CATEGORY, creditorSeed);
        address collateralizer = getRandomActor(USERS_CATEGORY, collateralizerSeed);

        if (owner == address(0) || creditor == address(0) || collateralizer == address(0)) return;

        // ensure permissions are set
        _setupPermissions(owner, collateralizer, creditor);

        uint256 creditNeeded;
        (deltaCollateral,  deltaNormalDebt, creditNeeded) = vault.getMaximumDebtForCollateral(owner, collateralizer, creditor, deltaCollateral);

        if (creditNeeded != 0){
            testContract.createCredit(creditor, creditNeeded);
        }

        vm.startPrank(owner);
        vault.modifyCollateralAndDebt(owner, collateralizer, creditor, deltaCollateral, deltaNormalDebt);
        vm.stopPrank();

        warpInterval(warpAmount);
        trackCallEnd(msg.sig);
    }

    function getTargetSelectors() public pure virtual override returns(bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](3);
        names = new string[](3);

        selectors[0] = this.deposit.selector;
        names[0] = "deposit";

        selectors[1] = this.withdraw.selector;
        names[1] = "withdraw";

        selectors[2] = this.modifyCollateralAndDebt.selector;
        names[2] = "modifyCollateralAndDebt";
    }

    function _setupPermissions(address owner, address collateralizer, address creditor) internal {
        vm.prank(collateralizer);
        vault.modifyPermission(owner, true);
        vm.startPrank(creditor);
        vault.modifyPermission(owner, true);
        cdm.modifyPermission(address(vault), true);
        vm.stopPrank();
    }
}
