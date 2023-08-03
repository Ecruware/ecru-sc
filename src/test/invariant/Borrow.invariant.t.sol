// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {BorrowHandler} from "./handlers/BorrowHandler.sol";

import {wmul} from "../../utils/Math.sol";
import {TICK_MANAGER_ROLE, VAULT_CONFIG_ROLE} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {CDPVault_TypeAWrapper} from "./CDPVault_TypeAWrapper.sol";

/// @title BorrowInvariantTest
contract BorrowInvariantTest is InvariantTestBase {
    CDPVault_TypeAWrapper internal cdpVault;
    BorrowHandler internal borrowHandler;

    /// ======== Setup ======== ///

    function setUp() public virtual override {
        super.setUp();

        cdpVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            targetHealthFactor: 1.05 ether, 
            baseRate: 1000000021919499726,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });

        borrowHandler = new BorrowHandler(cdpVault, this, new GhostVariableStorage());
        deal(
            address(token),
            address(borrowHandler),
            borrowHandler.collateralReserve() + borrowHandler.creditReserve()
        );

        cdpVault.grantRole(VAULT_CONFIG_ROLE, address(borrowHandler));
        // prepare price ticks
        cdpVault.grantRole(TICK_MANAGER_ROLE, address(borrowHandler));
        borrowHandler.createPriceTicks();

        _setupCreditVault();

        excludeSender(address(cdpVault));
        excludeSender(address(borrowHandler));

        vm.label({account: address(cdpVault), newLabel: "CDPVault_TypeA"});
        vm.label({
            account: address(borrowHandler),
            newLabel: "BorrowHandler"
        });

        (bytes4[] memory selectors, ) = borrowHandler.getTargetSelectors();
        targetSelector(
            FuzzSelector({
                addr: address(borrowHandler),
                selectors: selectors
            })
        );

        targetContract(address(borrowHandler));
    }

    // deploy a reserve vault and create credit for the borrow handler
    function _setupCreditVault() private {
        CDPVault_TypeA creditVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: borrowHandler.creditReserve(), 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            targetHealthFactor: 1.05 ether, 
            baseRate: 1 ether,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });

        // increase the global debt ceiling
        if(initialGlobalDebtCeiling != uint256(type(int256).max)){
            setGlobalDebtCeiling(
                initialGlobalDebtCeiling + borrowHandler.creditReserve()
            );
        }
        
        vm.startPrank(address(borrowHandler));
        token.approve(address(creditVault), borrowHandler.creditReserve());
        creditVault.deposit(
            address(borrowHandler),
            borrowHandler.creditReserve()
        );
        int256 debt = int256(wmul(liquidationPrice(creditVault), borrowHandler.creditReserve()));
        creditVault.modifyCollateralAndDebt(
            address(borrowHandler),
            address(borrowHandler),
            address(borrowHandler),
            int256(borrowHandler.creditReserve()),
            debt
        );
        vm.stopPrank();
    }

    function test_invariant_underflow() public {
        vm.prank(0x0000000000000000000000000000000000002AE0);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639935, 64073496331013554460115129233211550638857731325853253351461217848571);
        vm.prank(0xBE9138155ec11BC0c42911EEB97dE5900d751c32);
        borrowHandler.createLimitOrder(1249509010451361118228348667766698983416497822614494131096305815599, 340282366920938463463374607431768211454);
        vm.prank(0xCb287d45325F8276eB4377b29c1daDA5Acb022F9);
        borrowHandler.changeBaseRate(2547067);
        vm.prank(0x0000000000000000000000000000000000001B20);
        borrowHandler.repay(2, 123123);
    }

    function test_invariant_assert_C() public {
        vm.prank(0x2033393238383100000000000000000000000000);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639934, 1);
        vm.prank(0x00000000000000000000000000000000000031E6);
        borrowHandler.createLimitOrder(64419735570928963745674861590843057417032700, 2718666581042647783001011672510914897 );
        vm.prank(0xF4f588d331eBfa28653d42AE832DC59E38C9798f);
        borrowHandler.borrow(20284758795063, 1);
        // vm.prank(0xC66E1FEcd26a1B095A505d4e7fbB95C0b0847a75);
        // borrowHandler.changeBaseRate(5282);
        vm.prank(0x000000000000000000000000000000000000226d);
        borrowHandler.partialRepay(56250000000000000000, 22486, 8531);

        this.invariant_IRM_C();

        (uint256 collateral, uint256 normalDebt) = cdpVault.positions(0x2033393238383100000000000000000000000000);
        emit log_named_uint("collateral", collateral);
        emit log_named_uint("normalDebt", normalDebt);
        (collateral, normalDebt) = cdpVault.positions(0xF4f588d331eBfa28653d42AE832DC59E38C9798f);
        emit log_named_uint("collateral", collateral);
        emit log_named_uint("normalDebt", normalDebt);
    }

    function test_invariant_assert_I() public {
        vm.prank(0x0000000000000000000000000000000000000d37);
        borrowHandler.cancelLimitOrder(744265621924648733437416138983875408283445376495);
        vm.prank(0x00000000000000007061727469616c5265706178);
        borrowHandler.changeLimitOrder(3, 1);
        vm.prank(0x000000000000000000000001ECa955e9b65dffFf);
        borrowHandler.borrow(3, 2);
        vm.prank(0x000000000000000000000000000000000000051e);
        borrowHandler.borrow(923, 1250000000000000000);
        vm.prank(0x3c25DB85721D91b4f85B6eD0D7d77C8Ef74e5eD2);
        borrowHandler.repay(199157378116752083179140896199694938594619641959747469214626433438437081610, 115792089237316195423570985008687907853269984665640564039457584007913129639933);

        this.invariant_IRM_I();
    }

    function test_invariant_revert() public {
        vm.prank(0x000000000000000000000000000000000000070c);
        borrowHandler.borrow(27506448, 608942538058671644789060545928430220646693377654311092072444502595500);
        vm.prank(0x00000000000000000000000000000000000046ec);
        borrowHandler.createLimitOrder(18944, 340282366920937743535374607430908993651);
        vm.prank(0x0000000000000000000000000000000000001C04);
        borrowHandler.borrow(3, 12724938757250675139334);
        vm.prank(0x00000000000000000000000000000000F3b7DEac);
        borrowHandler.borrow(2, 586335151241979564644);
        vm.prank(0x0000000000000001027E7154D08133342B1081e6);
         borrowHandler.repay(30, 963290553460724356668903);
    }

    function test_invariant_revert_1() public {
        vm.prank(0x000000000000000000000000000000000000070c);
        borrowHandler.borrow(27506448, 608942538058671644789060545928430220646693377654311092072444502595500);
        vm.prank(0x00000000000000000000000000000000000046ec);
        borrowHandler.createLimitOrder(18944, 340282366920937743535374607430908993651);
        vm.prank(0x0000000000000000000000000000000000001C04);
        borrowHandler.borrow(3, 12724938757250675139334);
        vm.prank(0x00000000000000000000000000000000F3b7DEac);
        borrowHandler.borrow(2, 586335151241979564644);
        vm.prank(0x0000000000000001027E7154D08133342B1081e6);
         borrowHandler.repay(30, 963290553460724356668903);
    }

    function test_invariant_revert_2() public {
        vm.prank(0x6D81dCe444Df0BE1c75629D94e2831fc9899D3Ca);
        borrowHandler.changeLimitOrder(28697186438477802641483553131210052059666488242665361912410716867704170998712, 544534867);
        vm.prank(0x0000000000000000000000000000000000004af3);
        borrowHandler.repay(0, 115792089237316195423570985008687907853269984665640564039457584007913129639933);
        vm.prank(0x8C2537Ba73f69F63c2b1FAeBad20874cEf409d03);
        borrowHandler.repay(9578134507054954747248281568559125729, 6470779470747959);
        vm.prank(0x00000000000000000000000000000000000020B2);
        borrowHandler.partialRepay(67352006131115864598361114183466, 63915921194977178760023211167693948646958543357203215252763270729, 3);
        vm.prank(0x976349f370C813c41C34d56df4DD40d3830DD04f);
        borrowHandler.repay(187, 31354931781638678607228669297131712859100820671745083778533502622993977909346);
        vm.prank(0x0000000000000000000000000000000000002f70);
        borrowHandler.borrow(27254, 31111);
        vm.prank(0xD2262822F0959Ce0f55413c220E586DA8ccD4e5d);
        borrowHandler.borrow(3170, 89250000000000000000);
        this.invariant_IRM_I();
    }

    function test_invariant_revert_3() public {
        vm.prank(0x0000000000000001029A581dccc31b40FD6709Ee);
        borrowHandler.changeLimitOrder(531576890709026451718238521887222735222690164, 3);
        vm.prank(0x000000000000000102bE9f1f6E43f9E40C2a6730);
        borrowHandler.changeLimitOrder(75030422984377032830445, 94126579932948417401867429392509025457);
        vm.prank(0x000000000000000000513175eF146d32C8F9b8F4);
        borrowHandler.cancelLimitOrder(10385323400379342160116748572938096144665953);
        vm.prank(0x77C26EFBB2ffAe02310b2977E043f66b9Ec26C69);
        borrowHandler.changeSpotPrice(63988814396370088317813327915910);
        vm.prank(0x0000000000000000000000000000000000000050);
        borrowHandler.changeBaseRate(3);
        vm.prank(0x00000000000000000000000000000000003aEa14);
        borrowHandler.partialRepay(0, 973346770615528830866758201181152062, 3);
        vm.prank(0xffFFFfFfffFfffffffC56258420F044AfebE9c9B);
        borrowHandler.repay(83452269, 8137);
        vm.prank(0x000000000000000000000000000000000000402f);
        borrowHandler.borrow(0, 278031382107087316348529721810025462258824938593954830923402);
        vm.prank(0x3C8549b4d8fA91804485f91C26478D8eb0311f91);
        borrowHandler.changeSpotPrice(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        vm.prank(0xfCfafac2E8AEd1A852733EB481A3699a873ca240);
        borrowHandler.borrow(197291380467481836781795063515373816, 4932187685963047699191147660901762019474144138018098276);
        vm.prank(0x7bb101F5d2E9945A3A3d8Fc0E894ff0dd343067D);
        borrowHandler.changeBaseRate(368141268564160737887226650848786);
        vm.prank(0x0000000000000001431b9472f1946d5C81795313);
        borrowHandler.createLimitOrder(0, 3);
        vm.prank(0x0000000000000000000000409A28b2D16CfC16Ea);
        borrowHandler.changeBaseRate(54441919524191482012691819);
        vm.prank(0x0000000000000000002dbE9E9f9C82eFB87f43C4);
        borrowHandler.cancelLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639932);
        vm.prank(0x74A1d5bb6962D0777063aA97C5C26c78e6DcC710);
        borrowHandler.changeLimitOrder(6892321949495567384370, 66721992562773088328766381340249764147);
        vm.prank(0x974E77E27109B5a19b8c713A93911179402B1D15);
        borrowHandler.changeBaseRate(3882806662642163814570);
        vm.prank(0x427B20Ade60520Ec456463e7d23edFe85b35dAF4);
        borrowHandler.changeLimitOrder(1, 385318087792124235283144973952661108);
        vm.prank(0x19ba972E70Be32ab3a74D01eeA262d7CA78b029C);
        borrowHandler.repay(3, 53490746772179957003752073842900705954086875050542002761134277946247903102);
        vm.prank(0x00000000000000000000d1693565ED007427e854);
        borrowHandler.changeBaseRate(2781726972);
        vm.prank(0x0000000000000000000000000000000000005e05);
        borrowHandler.changeSpotPrice(905);
        vm.prank(0x00000000000000000000094f5e67e6f8CD363783);
        borrowHandler.changeBaseRate(1);
        vm.prank(0x2033383031363334343134313336383833323035);
        borrowHandler.partialRepay(115792089237316195423570985008687907853269984665640564039457584007913129639932, 44222851197433176896588194276447282787683806713149387650, 1535431900838700139151987364858);
        vm.prank(0x00000000000000000000DD5fcd7De4D804c17A1f);
        borrowHandler.changeSpotPrice(16673139049597400750381372497457396116915442889);
        vm.prank(0x00000000000000000000000000000000000002E3);
        borrowHandler.repay(2, 11631);
    }

    function test_invariant_revert_4() public {
        vm.prank(0x00000000000000000000000000000000000001C7);
        borrowHandler.changeSpotPrice(43365621203559295243493898706981689680);
        vm.prank(0x0000000000000000000000000000000000003bCA);
        borrowHandler.borrow(8245, 11990921123952878304591004930033800756408824502963948244755024278392705762004);
        vm.prank(0x9DD8C42ba3b116a0aF71F7560766CDF92D1daF2D);
        borrowHandler.createLimitOrder(33478689436296042843201008468, 340282366920938463463374607431768211455);
        vm.prank(0x0000000000000000000000000000000000000c4D);
        borrowHandler.createLimitOrder(86460763692444258254939001710390737612823480275017809703455413103526233897647, 16702783332987992693057211699446640160);
        vm.prank(0x000000000000000000000000CcB286d9E5030001);
        borrowHandler.createLimitOrder(3985997277, 19250);
        vm.prank(0x0000000000000000000000000000000000000315);
        borrowHandler.borrow(623, 2);
        vm.prank(0x00000000000000000000000000000000000045b8);
        borrowHandler.partialRepay(115792089237316195423570985008687907853269984665640564039457584007913129639935, 6996232778145126708888380352364600199865415829, 115792089237316195423570985008687907853269984665640564039457584007913129639932);
        vm.prank(0x00000000000000000000000000000000dBe6B31c);
        borrowHandler.changeBaseRate(7565787200123230416849165511112);
        vm.prank(0x0000000000000000000000000000000000004151);
        borrowHandler.partialRepay(1535431900838700139151987364858, 15126, 3381);
        vm.prank(0x000000000000000000000000000000001402a646);
        borrowHandler.changeLimitOrder(7637, 11632);
    }

    function test_invariant_revert_5() public {
        vm.prank(0x0000000000000000000000000000000000004724);
        borrowHandler.borrow(319191403752500527559048149112706091643485846435922035038, 1);
        vm.prank(0x76652066726F6d20746865207a65726f20616463);
        borrowHandler.createLimitOrder(8826, 14740);
        vm.prank(0x00000000000000000000000000000000CB6238c8);
        borrowHandler.borrow(0, 2);
        vm.prank(0x1f15fE8ff742B4734718eF81af585F4C7e78268a);
        borrowHandler.partialRepay(1358, 13150, 33213918945522163348297488160619434111254143694905912425159868126486596838752);
    }

    function test_invariant_revert_6() public {
        vm.prank(0xfc2CaE54daA751D7cD852c7b9D8790109ab0E5dB);
        borrowHandler.repay(66260527519712695671732545705276272040336012003755762973631064823804507447173, 464069033300869210759374312040618650);
        vm.prank(0x000000000000000000000003782dacE9D9000000);
        borrowHandler.changeLimitOrder(14773, 7764);
        vm.prank(0x0000000000000000000000000000000000002150);
        borrowHandler.borrow(6967129629120615090, 2);
        vm.prank(0x67EDf317804c08c82702Ef0120F6Bd649436815B);
        borrowHandler.createLimitOrder(1, 3);
        vm.prank(0x000000000000000000000000000000000000103d);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639935, 115792089237316195423570985008687907853269984665640564039457584007913129639935);
        vm.prank(0x00000000000000000000000000000000000008b4);
        borrowHandler.changeLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639934, 340282366920938463463374607431768211455);
        vm.prank(0x00000000000000000000D3C21bdCb87a514CEC1A);
        borrowHandler.repay(115792089237316195423570985008687907853269984665640564039457584007913129639935, 115792089237316195423570985008687907853269984665640564039457584007913129639933);
        vm.prank(0x2433333214299056411036f73aCc0B17Ed35460c);
        borrowHandler.partialRepay(16554, 1672205815, 21117);
        vm.prank(0x2039343032393634353739373538333934313037);
        borrowHandler.changeBaseRate(2725373221);
        vm.prank(0x00000000000000000000000000000000000024b0);
        borrowHandler.cancelLimitOrder(24830);
    }

    function test_invariant_revert_7() public {
        vm.prank(0x0000000000000000000000000000000000005F03);
        borrowHandler.changeLimitOrder(22699, 5785);
        vm.prank(0x00000000000000000000385eD72DCe34F55F6a5D);
        borrowHandler.cancelLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639934);
        vm.prank(0x0000000000000000000000000000000000001Ac9);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639932, 2);
        vm.prank(0x0000000000000000000000000000000000006242);
        borrowHandler.createLimitOrder(2, 4022449185429654923710623856945078);
        vm.prank(0x0000000000000000002dbe9e9f9C82eFB87f43c3);
        borrowHandler.changeBaseRate(2524284);
        vm.prank(0x000000000000000000000000000000000000152C);
        borrowHandler.borrow(3, 115792089237316195423570985008687907853269984665640564039457584007913129639932);
        vm.prank(0x4D68232D1aD010CB08C11ff341990266DcA5153e);
        borrowHandler.partialRepay(758, 17870790277551373838571514, 273421291);
    }

    /// ======== CDPVault Invariant Tests ======== ///

    function invariant_CDPVault_R_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_A(cdpVault, borrowHandler);
    }

    function invariant_CDPVault_R_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_B(cdpVault, borrowHandler);
    }

    function invariant_CDPVault_R_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_C(cdpVault, borrowHandler);
    }

    /// ======== Interest Rate Model Invariant Tests ======== ///

    function invariant_IRM_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_A(cdpVault, borrowHandler);
    }

    function invariant_IRM_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_B(cdpVault, borrowHandler);
    }

    function invariant_IRM_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_C(cdpVault, borrowHandler);
    }

    function invariant_IRM_D() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_D(cdpVault, borrowHandler);
    }

    function invariant_IRM_E() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_E(cdpVault);
    }

    function invariant_IRM_F() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_F(cdpVault, borrowHandler);
    }

    function invariant_IRM_G() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_G(cdpVault, borrowHandler);
    }

    function invariant_IRM_H() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_H(borrowHandler);
    }
    
    function invariant_IRM_I() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_I(cdpVault, borrowHandler);
    }

    function invariant_IRM_J() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_J(cdpVault, borrowHandler);
    }
}
