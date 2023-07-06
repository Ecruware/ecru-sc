// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {IStablecoin} from "./interfaces/IStablecoin.sol";

// Authenticated Roles
bytes32 constant MINTER_AND_BURNER_ROLE = keccak256("MINTER_AND_BURNER_ROLE");

/// @title Stablecoin
/// @notice `Stablecoin` is the protocol's stable asset which can be redeemed for `Credit` via `Minter`
contract Stablecoin is AccessControl, ERC20Permit, IStablecoin {

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor() ERC20("Stablecoin", "STBL") ERC20Permit("Stablecoin") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_AND_BURNER_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          MINTING AND BURNING
    //////////////////////////////////////////////////////////////*/

    /// @notice Increases the totalSupply by `amount` and transfers the new tokens to `to`
    /// @dev Sender has to be allowed to call this method
    /// @param to Address to which tokens should be credited to
    /// @param amount Amount of tokens to be minted [wad]
    function mint(address to, uint256 amount) external override onlyRole(MINTER_AND_BURNER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Decreases the totalSupply by `amount` and using the tokens from `from`
    /// @dev Sender has to be allowed to call this method. 
    ////     If `from` is not the caller, caller needs to have sufficient allowance from `from`,
    ///      `amount` is then deducted from the caller's allowance
    /// @param from Address from which tokens should be burned from
    /// @param amount Amount of tokens to be burned [wad]
    function burn(address from, uint256 amount) public override onlyRole(MINTER_AND_BURNER_ROLE) {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Overrides `_spendAllowance` behaviour exempting the case where owner == spender
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal override {
        if (owner == spender) return;
        super._spendAllowance(owner, spender, amount);
    }
}
