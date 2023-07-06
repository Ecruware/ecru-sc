// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./BaseHandler.sol";
import {InvariantTestBase} from "../InvariantTestBase.sol";

import {max, min, add} from "../../../utils/Math.sol";
import {Stablecoin, MINTER_AND_BURNER_ROLE} from "../../../Stablecoin.sol";

contract StablecoinHandler is BaseHandler {
    Stablecoin public stablecoin;

    uint256 public totalSupply = uint256(type(int256).max);
    uint256 public mintAccumulator = 0;
    uint256 public burnAccumulator = 0;

    constructor(
        address stablecoin_, 
        InvariantTestBase testContract_, 
        GhostVariableStorage ghostStorage_) 
    BaseHandler("StablecoinHandler", testContract_, ghostStorage_) {
        stablecoin = Stablecoin(stablecoin_);
    }

    function getTargetSelectors() public pure virtual override returns(bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](7);
        names = new string[](7);
        
        selectors[0] = this.mint.selector;
        names[0] = "mint";

        selectors[1] = this.burn.selector;
        names[1] = "burn";

        selectors[2] = this.transferFrom.selector;
        names[2] = "transferFrom";

        selectors[3] = this.transfer.selector;
        names[3] = "transfer";

        selectors[4] = this.approve.selector;
        names[4] = "approve";

        selectors[5] = this.increaseAllowance.selector;
        names[5] = "increaseAllowance";

        selectors[6] = this.decreaseAllowance.selector;
        names[6] = "decreaseAllowance";
    }

    // Mint tokens to a user, amount is capped by the total supply
    function mint(uint256 amount) public {
        trackCallStart(msg.sig);

        addActor(USERS_CATEGORY, msg.sender);

        // avoid overflow
        amount = bound(amount, 0, totalSupply - mintAccumulator);

        mintAccumulator = add(mintAccumulator, int256(amount));

        stablecoin.mint(msg.sender, amount);

        trackCallEnd(msg.sig);
    }

    // Burn tokens from a user, amount is capped by the user's balance and
    // and the allowance of the caller
    function burn(address from, uint256 amount) public {
        trackCallStart(msg.sig);

        if (from == address(0)) return;
        addActor(USERS_CATEGORY, from);

        uint256 balance = stablecoin.balanceOf(from);
        uint256 allowance = stablecoin.allowance(from, msg.sender);
        amount = bound(amount, 0, min(balance, allowance));

        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, msg.sender);
        vm.prank(msg.sender);
        stablecoin.burn(from, amount);

        burnAccumulator = add(burnAccumulator, int256(amount));

        trackCallEnd(msg.sig);
    }

    // Transfer tokens from one user to another, amount is capped
    // by the user's balance and the allowance of the caller
    function transferFrom(address from, address to, uint256 amount) public {
        trackCallStart(msg.sig);

        if (from == address(0) || to == address(0)) return;

        addActors(USERS_CATEGORY, [from, to]);

        uint256 balance = stablecoin.balanceOf(from);
        uint256 allowance = stablecoin.allowance(from, msg.sender);
        amount = bound(amount, 0, min(balance, allowance));

        vm.prank(msg.sender);
        stablecoin.transferFrom(from, to, amount);

        trackCallEnd(msg.sig);
    }

    // Transfer tokens to another user, amount is capped by the caller's balance
    function transfer(address to, uint256 amount) public {
        trackCallStart(msg.sig);

        if (to == address(0)) return;
        addActors(USERS_CATEGORY, [msg.sender, to]);
        amount = bound(amount, 0, stablecoin.balanceOf(msg.sender));

        vm.prank(msg.sender);
        stablecoin.transfer(to, amount);

        trackCallEnd(msg.sig);
    }

    /// Approve a spender to transfer tokens on behalf of the caller, `spender` cannot
    // be the zero address
    function approve(address spender, uint256 amount) public {
        trackCallStart(msg.sig);

        if (spender == address(0)) return;
        addActors(USERS_CATEGORY, [msg.sender, spender]);

        vm.prank(msg.sender);

        stablecoin.approve(spender, amount);

        trackCallEnd(msg.sig);
    }

    // Increases the allowance granted to `spender` by the caller, `spender` cannot
    // be the zero address
    function increaseAllowance(address spender, uint256 amount) public {
        trackCallStart(msg.sig);

        if (spender == address(0)) return;
        addActors(USERS_CATEGORY, [msg.sender, spender]);

        vm.prank(msg.sender);

        stablecoin.increaseAllowance(spender, amount);

        trackCallEnd(msg.sig);
    }

    // Decrease the allowance granted to `spender` by the caller, `spender` cannot
    // be the zero address
    function decreaseAllowance(address spender, uint256 amount) public {
        trackCallStart(msg.sig);

        if (spender == address(0)) return;
        addActors(USERS_CATEGORY, [msg.sender, spender]);

        amount = bound(amount, 0, stablecoin.allowance(msg.sender, spender));

        vm.prank(msg.sender);
        stablecoin.decreaseAllowance(spender, amount);

        trackCallEnd(msg.sig);
    }

    // Helper function that computes the total balance of all users
    // The total balance of all users
    // This function should be excluded from the invariant target selectors
    function totalUserBalance() public view returns (uint256) {
        uint256 total = 0;
        uint256 count_ = count(USERS_CATEGORY);
        for (uint256 i = 0; i < count_; ++i) {
            total = add(total, int256(stablecoin.balanceOf(ghostStorage.actors(USERS_CATEGORY,i))));
        }
        return total;
    }
}
