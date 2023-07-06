// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./BaseHandler.sol";

import {CDM, getCreditLine} from "../../../CDM.sol";

contract CDMHandler is BaseHandler {
    CDM public cdm;

    constructor(address cdm_, InvariantTestBase testContract_, GhostVariableStorage ghostStorage_) BaseHandler("CDMHandler", testContract_, ghostStorage_) {
        cdm = CDM(cdm_);
    }

    function getTargetSelectors() public pure virtual override returns(bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](5);
        names = new string[](5);
        
        selectors[0] = this.setParameter.selector;
        names[0] = "setParameter";

        selectors[1] = this.modifyBalance.selector;
        names[1] = "modifyBalanceCredit";
    }

    function setParameter(uint256 debtCeiling) public {
        trackCallStart(msg.sig);

        debtCeiling = bound(debtCeiling, 0, uint256(type(int256).max));

        address vault = msg.sender;
        // avoid re-initialization
        if (ghostStorage.registered(VAULTS_CATEGORY, vault)) return;

        addActor(VAULTS_CATEGORY, vault);
        cdm.setParameter(vault, "debtCeiling", debtCeiling);

        trackCallEnd(msg.sig);
    }

    function modifyBalance(address from, address to, uint256 amount) public {
        trackCallStart(msg.sig);

        if (to == address(0)) return;
        (int256 balance, uint256 debtCeiling) = cdm.accounts(from);
        amount = bound(amount, 0, getCreditLine(balance, debtCeiling));
        amount = bound(amount, 0, cdm.globalDebtCeiling() - cdm.globalDebt());
        addActors(USERS_CATEGORY, [from, to, msg.sender]);
        addActors(VAULTS_CATEGORY, [from, to, msg.sender]);

        vm.prank(from);
        cdm.modifyPermission(msg.sender, true);

        vm.prank(msg.sender);
        cdm.modifyBalance(from, to, amount);

        trackCallEnd(msg.sig);
    }
}
