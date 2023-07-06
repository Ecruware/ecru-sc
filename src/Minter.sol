// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";

import {ICDM} from "./interfaces/ICDM.sol";
import {IStablecoin} from "./interfaces/IStablecoin.sol";
import {IMinter} from "./interfaces/IMinter.sol";

import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";

/// @title Minter (Stablecoin Mint)
/// @notice The canonical mint for Stablecoin
/// where users can redeem their internal credit for Stablecoin
contract Minter is IMinter, AccessControl, Pause {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The CDM contract
    ICDM public immutable override cdm;
    /// @notice Stablecoin token
    IStablecoin public immutable override stablecoin;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Enter(address indexed user, uint256 amount);
    event Exit(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(ICDM cdm_, IStablecoin stablecoin_, address roleAdmin, address pauseAdmin) {
        _grantRole(DEFAULT_ADMIN_ROLE, roleAdmin);
        _grantRole(PAUSER_ROLE, pauseAdmin);

        cdm = cdm_;
        stablecoin = stablecoin_;
    }

    /*//////////////////////////////////////////////////////////////
                       CREDIT AND Stablecoin REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeems Stablecoin for internal credit
    /// @dev User has to set allowance for Minter to burn Stablecoin
    /// @param user Address of the user
    /// @param amount Amount of Stablecoin to be redeemed for internal credit [wad]
    function enter(address user, uint256 amount) external override {
        cdm.modifyBalance(address(this), user, amount);
        stablecoin.burn(msg.sender, amount);
        emit Enter(user, amount);
    }

    /// @notice Redeems internal credit for Stablecoin
    /// @dev User has to grant the delegate of transferring credit to Minter
    /// @param user Address of the user
    /// @param amount Amount of credit to be redeemed for Stablecoin [wad]
    function exit(address user, uint256 amount) external override whenNotPaused {
        cdm.modifyBalance(msg.sender, address(this), amount);
        stablecoin.mint(user, amount);
        emit Exit(user, amount);
    }
}
