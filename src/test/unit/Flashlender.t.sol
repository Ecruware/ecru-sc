// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {
    TestBase,
    ERC20PresetMinterPauser,
    Stablecoin,
    CDM,
    Buffer,
    TransparentUpgradeableProxy,
    ProxyAdmin
} from "../TestBase.sol";

import {WAD} from "../../utils/Math.sol";

import {MINTER_AND_BURNER_ROLE} from "../../Stablecoin.sol";
import {IStablecoin} from "../../interfaces/IStablecoin.sol";
import {ICDM} from "../../interfaces/ICDM.sol";
import {IMinter} from "../../interfaces/IMinter.sol";
import {IFlashlender, FlashLoanReceiverBase, IERC3156FlashBorrower, ICreditFlashBorrower} from "../../interfaces/IFlashlender.sol";
import {IPermission} from "../../interfaces/IPermission.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {Minter} from "../../Minter.sol";
import {CDPVaultUnwinderFactory} from "../../CDPVaultUnwinder.sol";
import {Flashlender} from "../../Flashlender.sol";

abstract contract TestReceiver is FlashLoanReceiverBase {

    constructor(address flash) FlashLoanReceiverBase(flash) {
        ICDM cdm = IFlashlender(flash).cdm();
        cdm.modifyPermission(flash, true);
    }

    function _mintStablecoinFee(uint256 amount) internal {
        if (amount > 0) IStablecoin(flashlender.stablecoin()).mint(address(this), amount);

    }

    function _mintCreditFee(uint256 amount) internal {
        if (amount > 0) {
            IStablecoin(flashlender.stablecoin()).mint(address(this), amount);
            IStablecoin(flashlender.stablecoin()).approve(address(flashlender.minter()), amount);
            IMinter(flashlender.minter()).enter(address(this), amount);
        }
    }
}


contract TestImmediatePaybackReceiver is TestReceiver {

    constructor(address flash) TestReceiver(flash) {
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        _mintStablecoinFee(fee_);
        // Just pay back the original amount
        approvePayback(amount_ + fee_);

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address,
        uint256,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        _mintCreditFee(fee_);
        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestReentrancyReceiver is TestReceiver {
    TestImmediatePaybackReceiver public immediatePaybackReceiver;

    constructor(address flash) TestReceiver(flash) {
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(flash);
    }

    function onFlashLoan(
        address,
        address token_,
        uint256 amount_,
        uint256 fee_,
        bytes calldata data_
    ) external override returns (bytes32) {
        flashlender.flashLoan(immediatePaybackReceiver, token_, amount_ + fee_, data_);

        approvePayback(amount_ + fee_);

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata data_
    ) external override returns (bytes32) {
        flashlender.creditFlashLoan(immediatePaybackReceiver, amount_ + fee_, data_);

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestDEXTradeReceiver is TestReceiver {
    Stablecoin public stablecoin;
    Minter public minter;
    ERC20PresetMinterPauser public token;
    CDPVault public vaultA;

    constructor(
        address flash,
        address stablecoin_,
        address minter_,
        address token_,
        address vaultA_
    ) TestReceiver(flash) {
        stablecoin = Stablecoin(stablecoin_);
        minter = Minter(minter_);
        token = ERC20PresetMinterPauser(token_);
        vaultA = CDPVault(vaultA_);
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        address me = address(this);
        uint256 totalDebt = amount_ + fee_;
        uint256 tokenAmount = totalDebt * 3;

        // Perform a "trade"
        stablecoin.transfer(address(0x1), amount_);
        token.mint(me, tokenAmount);

        // Mint some more stablecoin to repay the original loan
        token.approve(address(vaultA), type(uint256).max);
        vaultA.deposit(me, tokenAmount);
        vaultA.modifyCollateralAndDebt(
            me,
            me,
            me,
            int256(tokenAmount),
            int256(totalDebt)
        );

        IPermission(address(minter.cdm())).modifyPermission(address(this), address(minter), true);
        minter.exit(me, totalDebt);
        IPermission(address(minter.cdm())).modifyPermission(address(this), address(minter), false);

        approvePayback(amount_ + fee_);

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external override pure returns (bytes32) {
        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestBadReturn is TestReceiver {
    bytes32 public constant BAD_HASH = keccak256("my bad hash");

    constructor(address flash) TestReceiver(flash) {}

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        _mintStablecoinFee(fee_);
        approvePayback(amount_ + fee_);

        return BAD_HASH;
    }

    function onCreditFlashLoan(
        address,
        uint256,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        _mintCreditFee(fee_);
        return BAD_HASH;
    }
}

contract TestNoFeePaybackReceiver is TestReceiver {

    constructor(address flash) TestReceiver(flash) {}

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256,
        bytes calldata
    ) external override returns (bytes32) {
        // Just pay back the original amount w/o fee
        approvePayback(amount_);
        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external override pure returns (bytes32) {
        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestNoCallbacks {}

contract TestCDM is CDM {
    constructor() CDM(msg.sender, msg.sender, msg.sender) {}

    function mint(address to, uint256 amount) external {
        accounts[to].balance = int256(amount);
    }
}

contract FlashlenderTest is TestBase {
    address public me;

    CDPVault_TypeA public vault;

    TestImmediatePaybackReceiver public immediatePaybackReceiver;
    TestImmediatePaybackReceiver public immediatePaybackReceiverOne; // 1% fee
    TestImmediatePaybackReceiver public immediatePaybackReceiverFive; // 5% fee

    TestNoFeePaybackReceiver public noFeePaybackReceiver; // 1% fee

    TestReentrancyReceiver public reentrancyReceiver;
    TestDEXTradeReceiver public dexTradeReceiver;
    TestBadReturn public badReturn;
    TestNoCallbacks public noCallbacks;

    Flashlender flashlenderOne; // w/ 1% fee
    Flashlender flashlenderFive; // w/ 5% fee

    // override cdm to manually mint fees and flashlender with fees
    function createCore() internal override {
        cdm = new TestCDM();
        stablecoin = new Stablecoin();
        minter = new Minter(cdm, stablecoin, address(this), address(this));
        flashlender = new Flashlender(IMinter(minter), 0); // no fee
        flashlenderOne = new Flashlender(IMinter(minter), 1e16); // 1% fee
        flashlenderFive = new Flashlender(IMinter(minter), 5e16); // 5% fee
        cdpVaultUnwinderFactory = new CDPVaultUnwinderFactory();
        bufferProxyAdmin = new ProxyAdmin();
        buffer = Buffer(address(new TransparentUpgradeableProxy(
            address(new Buffer(cdm)),
            address(bufferProxyAdmin),
            abi.encodeWithSelector(Buffer.initialize.selector, address(this), address(this))
        )));
        setGlobalDebtCeiling(5_000_000 ether);
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(minter));
        cdm.setParameter(address(flashlender), "debtCeiling", uint256(type(int256).max));
        cdm.setParameter(address(flashlenderOne), "debtCeiling", uint256(type(int256).max));
        cdm.setParameter(address(flashlenderFive), "debtCeiling", uint256(type(int256).max));
        cdm.setParameter(address(buffer), "debtCeiling", 5_000_000 ether);
    }

    function setUp() public override {
        super.setUp();
        me = address(this);

        // mint credit for fees
        TestCDM(address(cdm)).mint(address(minter), 5_000_000 ether);

        // set up vault
        vault = createCDPVault_TypeA(
            token,
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            0, // price tick to rebate factor conversion bias
            WAD, // max rebate
            WAD, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        // deploy receivers
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(address(flashlender));
        immediatePaybackReceiverOne = new TestImmediatePaybackReceiver(address(flashlenderOne));
        immediatePaybackReceiverFive = new TestImmediatePaybackReceiver(address(flashlenderFive));

        noFeePaybackReceiver = new TestNoFeePaybackReceiver(address(flashlenderOne));

        reentrancyReceiver = new TestReentrancyReceiver(address(flashlender));
        dexTradeReceiver = new TestDEXTradeReceiver(
            address(flashlender),
            address(stablecoin),
            address(minter),
            address(token),
            address(vault)
        );
        badReturn = new TestBadReturn(address(flashlender));
        noCallbacks = new TestNoCallbacks();

        // grant permissions
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(badReturn));

        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(immediatePaybackReceiver));
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(immediatePaybackReceiverOne));
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(immediatePaybackReceiverFive));

        token.grantRole(token.MINTER_ROLE(), address(dexTradeReceiver));
    }

    function test_flashloan_payback_zero_fees() public {
        vm.expectRevert("ERC20: insufficient allowance"); // expect revert because not enough allowance to cover fees
        flashlender.flashLoan(noFeePaybackReceiver, address(stablecoin), 10 ether, "");
    }

    function test_creditflashloan_payback_zero_fees() public {
        vm.expectRevert();
        flashlender.creditFlashLoan(noFeePaybackReceiver, 10 ether, "");
    }

    function test_mint_payback_zero_fees() public {
        uint256 flashLoanAmount = 10 ether;
        uint256 expectedFee = flashlender.flashFee(address(stablecoin), flashLoanAmount);

        // assert zero fee
        assertEq(expectedFee, 0);

        flashlender.creditFlashLoan(immediatePaybackReceiver, flashLoanAmount, "");
        flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), flashLoanAmount, "");

        assertEq(credit(address(immediatePaybackReceiver)), 0);
        assertEq(debt(address(immediatePaybackReceiver)), 0);
        assertEq(credit(address(flashlender)), 0); // called paid zero fees
        assertEq(debt(address(flashlender)), 0);
    }

    function test_mint_payback_low_fee() public {
        uint256 flashLoanAmount = 10 ether;
        uint256 expectedFee = flashlenderOne.flashFee(address(stablecoin), flashLoanAmount);

        // assert fee is 1%
        assertEq(expectedFee, 10 ether * 1e16 / 1 ether);

        flashlenderOne.creditFlashLoan(immediatePaybackReceiverOne, flashLoanAmount, "");
        flashlenderOne.flashLoan(immediatePaybackReceiverOne, address(stablecoin), flashLoanAmount, "");

        assertEq(credit(address(immediatePaybackReceiverOne)), 0);
        assertEq(debt(address(immediatePaybackReceiverOne)), 0);
        assertEq(credit(address(flashlenderOne)), expectedFee*2); // expect that flashlender received the fees
        assertEq(debt(address(flashlenderOne)), 0);
    }

    function test_mint_payback_high_fee() public {
        uint256 flashLoanAmount = 10 ether;
        uint256 expectedFee = flashlenderFive.flashFee(address(stablecoin), flashLoanAmount);

        // assert fee is 5%
        assertEq(expectedFee, 10 ether * 5e16 / 1 ether);

        flashlenderFive.creditFlashLoan(immediatePaybackReceiverFive, flashLoanAmount, "");
        flashlenderFive.flashLoan(immediatePaybackReceiverFive, address(stablecoin), flashLoanAmount, "");

        assertEq(credit(address(immediatePaybackReceiverFive)), 0);
        assertEq(debt(address(immediatePaybackReceiverFive)), 0);
        assertEq(credit(address(flashlenderFive)), expectedFee*2); // expect that flashlender received the fees
        assertEq(debt(address(flashlenderFive)), 0);
    }

    // test mint() for amount_ == 0
    function test_mint_zero_amount() public {
        flashlender.creditFlashLoan(immediatePaybackReceiver, 0, "");
        flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), 0, "");
    }

    // test mint() for amount_ > max borrowable amount
    function test_mint_amount_over_max1() public {
        cdm.setParameter(address(flashlender), "debtCeiling", 10 ether);
        uint256 amount = flashlender.maxFlashLoan(address(stablecoin)) + 1 ether;
        vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
        flashlender.creditFlashLoan(immediatePaybackReceiver, amount, "");
    }

    function test_mint_amount_over_max2() public {
        cdm.setParameter(address(flashlender), "debtCeiling", 10 ether);
        uint256 amount = flashlender.maxFlashLoan(address(stablecoin)) + 1 ether;
        vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
        flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), amount, "");
    }

    // test max == 0 means flash minting is halted
    function test_mint_max_zero1() public {
        cdm.setParameter(address(flashlender), "debtCeiling", 0);
        vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
        flashlender.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function test_mint_max_zero2() public {
        cdm.setParameter(address(flashlender), "debtCeiling", 0);
        vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
        flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), 10 ether, "");
    }

    // test reentrancy disallowed
    function test_mint_reentrancy1() public {
        vm.expectRevert("ReentrancyGuard: reentrant call");
        flashlender.creditFlashLoan(reentrancyReceiver, 100 ether, "");
    }

    function test_mint_reentrancy2() public {
        vm.expectRevert("ReentrancyGuard: reentrant call");
        flashlender.flashLoan(reentrancyReceiver, address(stablecoin), 100 ether, "");
    }

    // test trading flash minted stablecoin for token and minting more stablecoin
    function test_dex_trade() public {
        // Set the owner temporarily to allow the receiver to mint
        flashlender.flashLoan(dexTradeReceiver, address(stablecoin), 100 ether, "");
    }

    function test_max_flash_loan() public {
        assertEq(flashlender.maxFlashLoan(address(stablecoin)), uint256(type(int256).max));
        assertEq(flashlender.maxFlashLoan(address(minter)), 0); // Any other address should be 0 as per the spec
    }

    function test_flash_fee() public {
        assertEq(flashlender.flashFee(address(stablecoin), 100 ether), 0);
        assertEq(flashlenderOne.flashFee(address(stablecoin), 100 ether), 1 ether);
        assertEq(flashlenderFive.flashFee(address(stablecoin), 100 ether), 5 ether);
    }

    function test_flash_fee_unsupported_token() public {
        vm.expectRevert(Flashlender.Flash__flashFee_unsupportedToken.selector);
        flashlender.flashFee(address(minter), 100 ether); // Any other address should fail
    }

    function test_bad_token() public {
        vm.expectRevert(Flashlender.Flash__flashLoan_unsupportedToken.selector);
        flashlender.flashLoan(immediatePaybackReceiver, address(minter), 100 ether, "");
    }

    function test_bad_return_hash1() public {
        vm.expectRevert(Flashlender.Flash__creditFlashLoan_callbackFailed.selector);
        flashlender.creditFlashLoan(badReturn, 100 ether, "");
    }

    function test_bad_return_hash2() public {
        vm.expectRevert(Flashlender.Flash__flashLoan_callbackFailed.selector);
        flashlender.flashLoan(badReturn, address(stablecoin), 100 ether, "");
    }

    function test_no_callbacks1() public {
        vm.expectRevert();
        flashlender.creditFlashLoan(ICreditFlashBorrower(address(noCallbacks)), 100 ether, "");
    }

    function test_no_callbacks2() public {
        vm.expectRevert();
        flashlender.flashLoan(IERC3156FlashBorrower(address(noCallbacks)), address(stablecoin), 100 ether, "");
    }
}