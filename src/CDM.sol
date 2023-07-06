// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";

import {ICDM} from "./interfaces/ICDM.sol";

import {Permission} from "./utils/Permission.sol";
import {toInt256, min, abs} from "./utils/Math.sol";

// Authenticated Roles
bytes32 constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
bytes32 constant ACCOUNT_CONFIG_ROLE = keccak256("ACCOUNT_CONFIG_ROLE");

function getCredit(int256 balance) pure returns (uint256) {
    return (balance < 0) ? 0 : uint256(balance);
}

function getDebt(int256 balance) pure returns (uint256) {
    return (balance > 0) ? 0 : uint256(-balance);
}

function getCreditLine(int256 balance, uint256 debtCeiling) pure returns (uint256) {
    int256 minBalance = -int256(debtCeiling);
    return (balance < minBalance) ? 0 : uint256(-(minBalance - balance));
}

/// @title CDM
/// @notice Global accounting for credit and debt in the system
contract CDM is Permission, AccessControl, ICDM {

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Global Accounting
    /// @notice Total amount of debt generated <> credit issued by the cdm [wad]
    uint256 public globalDebt;
    /// @notice Total amount of debt that can be generated / credit that can be issued by the cdm [wad]
    uint256 public globalDebtCeiling;

    // Accounting
    struct Account {
        int256 balance; // [wad]
        uint256 debtCeiling; // [wad]
    }
    /// @notice Map of accounts with their own balance (+ credit, - debt) and debt ceiling
    mapping(address => Account) public accounts;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SetParameter(bytes32 indexed parameter, uint256 data);
    event SetParameter(address indexed account, bytes32 indexed parameter, uint256 data);
    event ModifyBalance(
        address indexed from,
        address indexed to,
        int256 balanceFrom,
        int256 balanceTo,
        uint256 globalDebt
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDM__setParameter_unrecognizedParameter();
    error CDM__setParameter_debtCeilingExceedsMax();
    error CDM__modifyBalance_noPermission();
    error CDM__modifyBalance_debtCeilingExceeded();
    error CDM__modifyBalance_globalDebtCeilingExceeded();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address roleAdmin, address cdmAdmin, address accountAdmin) {
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, roleAdmin);
        // CDM Config Admin
        _grantRole(CONFIG_ROLE, cdmAdmin);
        // Account Config Admin
        _grantRole(ACCOUNT_CONFIG_ROLE, accountAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParameter(bytes32 parameter, uint256 data) external onlyRole(CONFIG_ROLE) {
        if (parameter == "globalDebtCeiling") {
            if (data > uint256(type(int256).max)) revert CDM__setParameter_debtCeilingExceedsMax();
            globalDebtCeiling = data;
        }
        else revert CDM__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParameter(address debtor, bytes32 parameter, uint256 data) external onlyRole(ACCOUNT_CONFIG_ROLE) {
        if (parameter == "debtCeiling") {
            if (data > uint256(type(int256).max)) revert CDM__setParameter_debtCeilingExceedsMax();
            accounts[debtor].debtCeiling = data;
        }
        else revert CDM__setParameter_unrecognizedParameter();
        emit SetParameter(debtor, parameter, data);
    }

    /*//////////////////////////////////////////////////////////////
                       CREDIT AND DEBT ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current amount of debt (<> credit) an account can generate (<> draw)
    /// @param debtor Address of the account to get the credit line for
    /// @return _ Credit line of the account [wad]
    function creditLine(address debtor) external view returns (uint256) {
        Account memory account = accounts[debtor];
        return getCreditLine(account.balance, account.debtCeiling);
    }

    /// @notice Transfers credit from one account to another. If the `from` account's positive balance (credit) isn't
    /// sufficient to cover the transfer, its balance can go negative (debt) up to the debt ceiling. 
    /// @dev Sender has to have the permit of `from` to call this method
    /// @param from Address of the account to transfer credit from
    /// @param to Address of the account to transfer credit to
    /// @param amount Amount of credit to transfer [wad]
    function modifyBalance(address from, address to, uint256 amount) public {
        if (!hasPermission(from, msg.sender)) revert CDM__modifyBalance_noPermission();
        Account memory debtorFrom = accounts[from];
        Account memory debtorTo = accounts[to];
        int256 debtorFromBalanceBefore = debtorFrom.balance;
        int256 debtorToBalanceBefore = debtorTo.balance;
        
        debtorFrom.balance -= toInt256(amount);
        debtorTo.balance += toInt256(amount);
    
        if (debtorFrom.balance + toInt256(debtorFrom.debtCeiling) < 0) revert CDM__modifyBalance_debtCeilingExceeded();
        
        if (
            debtorFrom.balance < 0 || debtorFromBalanceBefore < 0 || debtorTo.balance < 0 || debtorToBalanceBefore < 0
        ) {
            uint256 globalDebtBefore = globalDebt;
            uint256 globalDebt_ = globalDebtBefore;
            if (debtorFrom.balance < 0 || debtorFromBalanceBefore < 0)
                globalDebt_ = globalDebt_ + abs(min(0, debtorFrom.balance)) - abs(min(0, debtorFromBalanceBefore));
            if (debtorTo.balance < 0 || debtorToBalanceBefore < 0)
                globalDebt_ = globalDebt_ + abs(min(0, debtorTo.balance)) - abs(min(0, debtorToBalanceBefore));
            if (globalDebt_ > globalDebtBefore && globalDebt_ > globalDebtCeiling)
                revert CDM__modifyBalance_globalDebtCeilingExceeded();
            globalDebt = globalDebt_;
        }
        
        accounts[from] = debtorFrom;
        accounts[to] = debtorTo;
        
        emit ModifyBalance(from, to, debtorFrom.balance, debtorTo.balance, globalDebt);
    }
}
