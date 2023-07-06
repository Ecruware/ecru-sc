// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControlUpgradeable} from "openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ICDM} from "./interfaces/ICDM.sol";
import {IBuffer} from "./interfaces/IBuffer.sol";

import {min} from "./utils/Math.sol";

// Authenticated Roles
bytes32 constant CREDIT_MANAGER_ROLE = keccak256("CREDIT_MANAGER_ROLE");
bytes32 constant BAIL_OUT_QUALIFIER_ROLE = keccak256("BAIL_OUT_QUALIFIER_ROLE");

/// @title Buffer
/// @notice Buffer for credit and debt in the system
contract Buffer is IBuffer, Initializable, AccessControlUpgradeable {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice CDM contract
    ICDM public immutable cdm;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    event BailOut(address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Buffer__withdrawCredit_zeroAddress();

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    // slither-disable-next-line unused-state
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ICDM cdm_) initializer {
        cdm = cdm_;
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the proxies storage variables
    /// @dev Can only be called once
    /// @param admin Address to whom assign the DEFAULT_ADMIN_ROLE role to
    /// @param manager Address to whom assign the CREDIT_MANAGER_ROLE role to
    function initialize(address admin, address manager) external initializer {
        // init. Access Control
        __AccessControl_init();
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Credit Manager
        _grantRole(CREDIT_MANAGER_ROLE, manager);
    }

    /// @notice Withdraws credit from the buffer to another account
    /// @dev Requires caller to have 'CREDIT_MANAGER_ROLE' role
    /// @param to Account to withdraw credit to
    /// @param amount Amount of credit to withdraw
    function withdrawCredit(address to, uint256 amount) external onlyRole(CREDIT_MANAGER_ROLE) {
        if (to == address(0)) revert Buffer__withdrawCredit_zeroAddress();
        cdm.modifyBalance(address(this), to, amount);
    }

    /// @notice Transfers as much credit as there's available to the buffer to the msg.sender if msg.sender has
    /// the BAIL_OUT_QUALIFIER_ROLE role
    /// @param amount Amount of credit to transfer
    /// @return bailedOut Actual amount of credit transferred
    function bailOut(uint256 amount) external returns (uint256 bailedOut) {
        if (!hasRole(BAIL_OUT_QUALIFIER_ROLE, msg.sender)) return 0;
        
        (uint256 globalDebt, uint256 globalDebtCeiling) = (cdm.globalDebt(), cdm.globalDebtCeiling());
        uint256 creditLine = cdm.creditLine(address(this));
        bailedOut = min(min(creditLine, amount), (globalDebt > globalDebtCeiling) ? 0 : globalDebtCeiling - globalDebt);
        cdm.modifyBalance(address(this), msg.sender, bailedOut);
        
        emit BailOut(msg.sender, bailedOut);
    }
}
