// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {Stablecoin, MINTER_AND_BURNER_ROLE} from "../../Stablecoin.sol";

contract TokenUser {
    Stablecoin public token;

    constructor(Stablecoin token_) {
        token = token_;
    }

    function doTransferFrom(address from, address to, uint256 amount) public returns (bool) {
        return token.transferFrom(from, to, amount);
    }

    function doTransfer(address to, uint256 amount) public returns (bool) {
        return token.transfer(to, amount);
    }

    function doApprove(address recipient, uint256 amount) public returns (bool) {
        return token.approve(recipient, amount);
    }

    function doAllowance(address owner, address spender) public view returns (uint256) {
        return token.allowance(owner, spender);
    }

    function doBalanceOf(address user) public view returns (uint256) {
        return token.balanceOf(user);
    }

    function doApprove(address spender) public returns (bool) {
        return token.approve(spender, type(uint256).max);
    }

    function doMint(uint256 amount) public {
        token.mint(address(this), amount);
    }

    function doBurn(uint256 amount) public {
        token.burn(address(this), amount);
    }

    function doMint(address to, uint256 amount) public {
        token.mint(to, amount);
    }

    function doBurn(address guy, uint256 amount) public {
        token.burn(guy, amount);
    }
}

contract StablecoinTest is Test {
    uint256 constant internal initialBalanceThis = 1000;
    uint256 constant internal initialBalanceSender = 100;

    Stablecoin internal token;
    address internal user1;
    address internal user2;
    address internal self;

    uint256 internal amount = 2;
    uint256 internal fee = 1;
    uint256 internal nonce = 0;
    uint256 internal deadline = 0;
    address internal sender = 0xcfDFCdf4e30Cf2C9CAa2C239677C8d42Ad7D67DE;
    address internal receiver = 0x0D1d31abea2384b0D5add552E3a9b9F66d57e141;
    bytes32 internal r = 0xa73a22dbcba5d8be02f04dc24de923f9e98a591c68cd165f1cc449816196626a;
    bytes32 internal s = 0x711beea0ba8d0861a359d9338892f3f60fd0711f20e249344536cd991918b9c1;
    uint8 internal v = 28;
    bytes32 internal _r = 0xe68def108b1fecd4d8af1823a61a962f8143625e1ac4f6729c9a995c3ed620d1;
    bytes32 internal _s = 0x0b939a8709ff079e03705711a6cbadbb7ee20bc1f8510cb1b574c58c9fe4abb5;
    uint8 internal _v = 28;

    function setUp() public {
        vm.warp(604411200);
        token = createToken();
        token.mint(address(this), initialBalanceThis);
        token.mint(sender, initialBalanceSender);
        user1 = address(new TokenUser(token));
        user2 = address(new TokenUser(token));
        self = address(this);
    }

    function createToken() internal returns (Stablecoin) {
        return new Stablecoin();
    }

    function testSetupPrecondition() public {
        assertEq(token.balanceOf(self), initialBalanceThis);
    }

    function testTransferCost() public {
        token.transfer(address(1), 10);
    }

    function testAllowanceStartsAtZero() public {
        assertEq(token.allowance(user1, user2), 0);
    }

    function testValidTransfers() public {
        uint256 sentAmount = 250;
        token.transfer(user2, sentAmount);
        assertEq(token.balanceOf(user2), sentAmount);
        assertEq(token.balanceOf(self), initialBalanceThis - sentAmount);
    }

    function testFailWrongAccountTransfers() public {
        uint256 sentAmount = 250;
        token.transferFrom(user2, self, sentAmount);
    }

    function testFailInsufficientFundsTransfers() public {
        uint256 sentAmount = 250;
        token.transfer(user1, initialBalanceThis - sentAmount);
        token.transfer(user2, sentAmount + 1);
    }

    function testApproveSetsAllowance() public {
        token.approve(user2, 25);
        assertEq(token.allowance(self, user2), 25);
    }

    function testChargesAmountApproved() public {
        uint256 amountApproved = 20;
        token.approve(user2, amountApproved);
        assertTrue(TokenUser(user2).doTransferFrom(self, user2, amountApproved));
        assertEq(token.balanceOf(self), initialBalanceThis - amountApproved);
    }

    function testFailTransferWithoutApproval() public {
        token.transfer(user1, 50);
        token.transferFrom(user1, self, 1);
    }

    function testFailChargeMoreThanApproved() public {
        token.transfer(user1, 50);
        TokenUser(user1).doApprove(self, 20);
        token.transferFrom(user1, self, 21);
    }

    function testTransferFromSelf() public {
        token.transferFrom(self, user1, 50);
        assertEq(token.balanceOf(user1), 50);
    }

    function testFailTransferFromSelfNonArbitrarySize() public {
        // you shouldn't be able to evade balance checks by transferring
        // to yourself
        token.transferFrom(self, self, token.balanceOf(self) + 1);
    }

    function testMintself() public {
        uint256 mintAmount = 10;
        token.mint(address(this), mintAmount);
        assertEq(token.balanceOf(self), initialBalanceThis + mintAmount);
    }

    function testMintGuy() public {
        uint256 mintAmount = 10;
        token.mint(user1, mintAmount);
        assertEq(token.balanceOf(user1), mintAmount);
    }

    function testFailMintGuyNoAuth() public {
        TokenUser(user1).doMint(user2, 10);
    }

    function testMintGuyAuth() public {
        token.grantRole(MINTER_AND_BURNER_ROLE, user1);
        TokenUser(user1).doMint(user2, 10);
    }

    function testBurn() public {
        uint256 burnAmount = 10;
        token.burn(address(this), burnAmount);
        assertEq(token.totalSupply(), initialBalanceThis + initialBalanceSender - burnAmount);
    }

    function testBurnself() public {
        uint256 burnAmount = 10;
        token.burn(address(this), burnAmount);
        assertEq(token.balanceOf(self), initialBalanceThis - burnAmount);
    }

    function testBurnGuyWithTrust() public {
        uint256 burnAmount = 10;
        token.transfer(user1, burnAmount);
        assertEq(token.balanceOf(user1), burnAmount);
        TokenUser(user1).doApprove(self);
        token.burn(user1, burnAmount);
        assertEq(token.balanceOf(user1), 0);
    }

    function testFailBurnGuyNoAuth() public {
        token.transfer(user1, 10);
        TokenUser(user1).doBurn(10);
    }

    function testBurnAuth() public {
        token.transfer(user1, 10);
        token.grantRole(MINTER_AND_BURNER_ROLE, user1);
        TokenUser(user1).doBurn(10);
    }

    function testFailUntrustedTransferFrom() public {
        assertEq(token.allowance(self, user2), 0);
        TokenUser(user1).doTransferFrom(self, user2, 200);
    }

    function testTrusting() public {
        assertEq(token.allowance(self, user2), 0);
        token.approve(user2, type(uint256).max);
        assertEq(token.allowance(self, user2), type(uint256).max);
        token.approve(user2, 0);
        assertEq(token.allowance(self, user2), 0);
    }

    function testTrustedTransferFrom() public {
        token.approve(user1, type(uint256).max);
        TokenUser(user1).doTransferFrom(self, user2, 200);
        assertEq(token.balanceOf(user2), 200);
    }

    function testApproveWillModifyAllowance() public {
        assertEq(token.allowance(self, user1), 0);
        assertEq(token.balanceOf(user1), 0);
        token.approve(user1, 1000);
        assertEq(token.allowance(self, user1), 1000);
        TokenUser(user1).doTransferFrom(self, user1, 500);
        assertEq(token.balanceOf(user1), 500);
        assertEq(token.allowance(self, user1), 500);
    }

    function testApproveWillNotModifyAllowance() public {
        assertEq(token.allowance(self, user1), 0);
        assertEq(token.balanceOf(user1), 0);
        token.approve(user1, type(uint256).max);
        assertEq(token.allowance(self, user1), type(uint256).max);
        TokenUser(user1).doTransferFrom(self, user1, 1000);
        assertEq(token.balanceOf(user1), 1000);
        assertEq(token.allowance(self, user1), type(uint256).max);
    }

    function testStablecoinAddress() public {
        // The Stablecoin address generated by hevm
        // used for signature generation testing
        assertEq(address(token), address(0x0bA14c5a7c7EB53793076a4722Cb0939a235Ac31));
    }

    function testDomain_Separator() public {
        assertEq(token.DOMAIN_SEPARATOR(), 0xfc6ba587e2b8d70dd2b6da50ebbf9ecf47e96f981402319f2c87e498904569ea);
    }

    function testPermit() public {
        assertEq(token.nonces(sender), 0);
        assertEq(token.allowance(sender, receiver), 0);
        token.permit(sender, receiver, type(uint256).max, type(uint256).max, v, r, s);
        assertEq(token.allowance(sender, receiver), type(uint256).max);
        assertEq(token.nonces(sender), 1);
    }

    function testFailPermitAddress0() public {
        v = 0;
        token.permit(address(0), receiver, type(uint256).max, type(uint256).max, v, r, s);
    }

    function testPermitWithExpiry() public {
        assertEq(block.timestamp, 604411200);
        token.permit(sender, receiver, type(uint256).max, 604411200 + 1 hours, _v, _r, _s);
        assertEq(token.allowance(sender, receiver), type(uint256).max);
        assertEq(token.nonces(sender), 1);
    }

    function testFailPermitWithExpiry() public {
        vm.warp(block.timestamp + 2 hours);
        assertEq(block.timestamp, 604411200 + 2 hours);
        token.permit(sender, receiver, type(uint256).max, 1, _v, _r, _s);
    }

    function testFailReplay() public {
        token.permit(sender, receiver, type(uint256).max, type(uint256).max, v, r, s);
        token.permit(sender, receiver, type(uint256).max, type(uint256).max, v, r, s);
    }
}
