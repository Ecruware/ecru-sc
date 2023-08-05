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

    function test_invariant_revert_8() public {
        vm.prank(0x6F75fd46c5b4b037C05594dc1C1AbAa2DF0FFcbe);
        borrowHandler.borrow(68202705662544324835190326952002567365007684131029110460994937219595816027732, 63330445060456717920497703580931587517559634856304997819556597710626549826610);
        vm.prank(0x000000000000000000000016D6e047D825941744);
        borrowHandler.createLimitOrder(14710, 2401778031);
        vm.prank(0xEE4915cbe1ED6c4B7fC6172069575e355C16BE0b);
        borrowHandler.changeBaseRate(174);
        vm.prank(0x0000000000000000000000000000000000929007);
        borrowHandler.changeBaseRate(21950456749743030733905985533);
        vm.prank(0x00000000000000000000000000000000000017d3);
        borrowHandler.borrow(80749999999999999999, 371305002032664447244883565101943655697349896178978063823);
        vm.prank(0x8BaD1DdaB67E41025C2D5078A1Be2A3a238B4E63);
        borrowHandler.changeBaseRate(2);
        vm.prank(0x0000000000000001027f0629791A4d12CF229b9C);
        borrowHandler.createLimitOrder(12421455096684471216550801559933774, 70730927868471756523551630212459376);
        vm.prank(0x0000000000000000000005aE6b73B362CeCCE68f);
        borrowHandler.repay(16966, 11750000000000000001);
        vm.prank(0xc74E14fFDd49FD15228520e37E9FfA180564f582);
        borrowHandler.repay(1, 2307331331572328228076226366416605918062049098);
    }


    function test_invariant_revert_9() public {
        vm.prank(0x000000000000000000000000000000000019b893);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639933, 115792089237316195423570985008687907853269984665640564039457584007913129639934);
        vm.prank(0x00000000000000000000000000000000000058Af);
        borrowHandler.changeSpotPrice(115792089237316195423570985008687907853269984665640564039457584007913129639934);
        vm.prank(0xd51DfDbe3B315eb857BEb12cb3EE43672bF1023e);
        borrowHandler.changeLimitOrder(13424151, 340282366920938463463374607431768211455);
        vm.prank(0x0000000000000000000000000000000000001073);
        borrowHandler.changeSpotPrice(3757);
        vm.prank(0x00000000000000000034C49A323A3695EEED2161);
        borrowHandler.changeLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639933, 340282366920938463463374607431768211455);
        vm.prank(0x0000000000000000000000000000000000001025);
        borrowHandler.createLimitOrder(566858635608224066395130, 9045157810816455145884);
        vm.prank(0xB848c7dF7feB24d837D6E7dacaba1493f63604Be);
        borrowHandler.borrow(2423, 364539252392129422936199);
        vm.prank(0x000000000000000000000002f0Deb79238F10000);
        borrowHandler.createLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639934, 18190708026384252980539653637574);
        vm.prank(0xe17A0F211512204A7d8b9ad664EDA9E52E4Ef317);
        borrowHandler.cancelLimitOrder(3484);
        vm.prank(0xFa75B5afa849dB3C2b18eCB3F88fa33eE5b08D58);
        borrowHandler.createLimitOrder(22910049993017499687369692042306326345, 340282366920938463463374607431768211455);
        vm.prank(0xb24Da87Bedb42898556DdF57fd82c60E8E72861d);
        borrowHandler.changeLimitOrder(67840444757765390206268549392465306753, 251);
        vm.prank(0x079684b000273e904EF9D6bE445cB63c55EE29D3);
        borrowHandler.borrow(3, 115792089237316195423570985008687907853269984665640564039457584007913129639933);
        vm.prank(0x00000000000000000000000000000000000016A2);
        borrowHandler.repay(1277, 15066);
        vm.prank(0xC8B8F6d01f6264af8Ec391953D73a3Eaa865959D);
        borrowHandler.repay(2873872914810915653028057681973235539754166973450, 115792089237316195423570985008687907853269984665640564039457584007913129639932);
    }

    function test_invariant_revert_10() public {
        vm.prank(0x0000000000000001028023b72c929afbB5Fe09f0);
        borrowHandler.changeSpotPrice(115792089237316195423570985008687907853269984665640564039457584007913129639935);
        vm.prank(0x2cf5AcEea3752b08978AaeA4E6CB9C3EF217B3AA);
        borrowHandler.partialRepay(1, 9231521778554873907664101355052574922867218, 1182256014601204731865);
        vm.prank(0x050A213Ea89f80AA364dC2d91Cb23D57c101b40E);
        borrowHandler.borrow(15644454626343801787671190339331599188384361324093788974008181, 33054648);
        vm.prank(0x400325CB5700102Ca6804438B0Fa674e0e6E2212);
        borrowHandler.partialRepay(2, 2621646317512821, 115792089237316195423570985008687907853269984665640564039457584007913129639932);
        vm.prank(0x9EB46D570000000000EaAEF80dE0B6b8C1e505cE);
        borrowHandler.changeLimitOrder(102016848382941096915909665119668953844189324965582661267693117907381370484969, 10384667062445320901291399286803500455);
        vm.prank(0x0000000000000000000000000000000000003998);
        borrowHandler.changeLimitOrder(2, 3);
        vm.prank(0x3D2455F8009faC2a9757e8fd22B0Aa7f2CaCC2E1);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639932, 115792089237316195423570985008687907853269984665640564039457584007913129639933);
        vm.prank(0x6A66764DEBa4dB1F8655389Dc2A865Cd506ffA67);
        borrowHandler.createLimitOrder(115792089237316195423570985008687907853269984665640463786806827687139970833874, 2721382726081105810);
        vm.prank(0x2032313130393934000000000000000000000000);
        borrowHandler.changeLimitOrder(310273171635341966, 340282366920938463463374607431768211453);
        vm.prank(0x000000000000000000001439e3B78e44bFa0f5F7);
        borrowHandler.changeSpotPrice(371619425727859221355858607904106265391925458702134033);
        vm.prank(0xFFfffFfffffFFfFfFFB82E25f0A46fc8685B195A);
        borrowHandler.changeSpotPrice(115792089237316195423570985008687907853269984665640564039457584007913129639934);
        vm.prank(0x000000000000000000000000000000000000419d);
        borrowHandler.createLimitOrder(508565719809915603949247216534925400273210789782450669005, 76503065044355641898843437949890428047);
        vm.prank(0x0a6179D5C62173E80200410ee26b4cd77dAcCe5D);
        borrowHandler.changeSpotPrice(204440781764850079566663118607886554);
        vm.prank(0x0000000000000000000000000000000000434bEb);
        borrowHandler.createLimitOrder(380650591980395134, 32026917400203673829604166628710621512);
        vm.prank(0x0000000000000000000000002D2E8dcC13D48EeD);
        borrowHandler.borrow(1414045148814590033239140, 80000000381049624672250445320);
        vm.prank(0x35F93c76fE98376f820Cb1871aca438D57754cb6);
        borrowHandler.cancelLimitOrder(3972385);
        vm.prank(0x000000000000000000000000082754ff9E002633);
        borrowHandler.createLimitOrder(3521995501227355218667229739119355757895685800597, 332141845806060707255312168224573513);
        vm.prank(0x0000000000000000005AbeA5830D2A7576A86a14);
        borrowHandler.borrow(115792089237316195423570985008687907853269984665640564039457584007913129639932, 3);
        vm.prank(0x9eC41C2cF1da951d6D1591509dF1C71E465A0c35);
        borrowHandler.partialRepay(1078307926395820962867, 57054671928292255369729200882000936758352, 148343759099149425642915472398032803442785405);
        vm.prank(0x0000000000000000000000000dE0B6B7f06F3C80);
        borrowHandler.changeLimitOrder(37084, 1165358905);
        vm.prank(0x0000000000000000000000000000000001211f75);
        borrowHandler.changeLimitOrder(97236605823079135729197775278827593587393156154289921330089080662725750441873, 99997000099999999976137990777);
        vm.prank(0x000000000056a6cc2fca3E700F3d02A819210fcF);
        borrowHandler.repay(74118287578224411624902, 99997680151348209906017347381);
        vm.prank(0x00000000000000000000065FEBcC3ce88EA4De4c);
        borrowHandler.changeSpotPrice(444732771473507882046143);
        vm.prank(0x00000000000000000000d3BCB0076EC03DF05b55);
        borrowHandler.createLimitOrder(80026237823376246376569142177, 13333);
        vm.prank(0x0000000000000000000000000000000000003AAE);
        borrowHandler.partialRepay(3967211927926921058339110203497380705381721620312288503697, 1878717137788490551, 98939412922965184982);
        vm.prank(0x000000000000053F28935BF84C29bbADD695c74A);
        borrowHandler.changeLimitOrder(3, 2);
        vm.prank(0x0000000000000000000000000000000001cC999c);
        borrowHandler.repay(26958198453932017645524667900911461636817802838944835710453428833195980203353, 94179591683102677932783523564838724687740737930616367767025521444555092441513);
    }

    function test_invariant_assert_1() public {
        vm.prank(0x0000000000000000000000000000000000004F5E);
        borrowHandler.createLimitOrder(3, 340282366920938463463374607431768211455);
        vm.prank(0x0000000000000000000000000000000000003Fd0);
        borrowHandler.borrow(4190948996782048156981828520522308, 0);
        vm.prank(0x0000000000000000000000000000000000001EA1);
        borrowHandler.partialRepay(72799079739508822149429135, 17984, 5763990780665395698115);
        vm.prank(0x0000000000000000000000000000000000001B56);
        borrowHandler.cancelLimitOrder(2033891629353028472971);
        vm.prank(0x000000000000000000099506E82994E5c1E8a307);
        borrowHandler.cancelLimitOrder(259937153121);
        vm.prank(0x0000000000000000000000000000000000001e96);
        borrowHandler.changeBaseRate(115792089237316195423570985008687907853269984665640564039457584007913129639932);
        vm.prank(0x0000000000000000000000000000000000006398);
        borrowHandler.changeLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639932, 2);
        vm.prank(0x00000000000000000000000000000000000038Be);
        borrowHandler.changeSpotPrice(115792089237316195423570985008687907853269984665640564039457584007913129639933);
        vm.prank(0x1DBbfC0d9d11a8bb1a6623175374C9074C5F6a2a);
        borrowHandler.partialRepay(1096, 80000000144000000000000002263, 2952);
        vm.prank(0x00000000000000000000000000000000000004Fe);
        borrowHandler.borrow(61965962952590252202146970573223415249703236, 3);
        vm.prank(0x0000000000000000000000000fA11428920B353F);
        borrowHandler.createLimitOrder(24, 340282366920938463463374607431768211453);
        vm.prank(0x0000000000000001027f0B65512d6d038de02DFA);
        borrowHandler.partialRepay(8193503681301919454486368181291411136237473, 3, 115792089237316195423570985008687907853269984665640564039457584007913129639933);
        vm.prank(0x0000000000000000000018DFd8118dd4358F6345);
        borrowHandler.createLimitOrder(7290, 91225317503329404824586);
        vm.prank(0x0000000000000001431D3BeC51A6D85ba3c67217);
        borrowHandler.changeLimitOrder(3750000000000000000, 1122834414851758469);
        vm.prank(0x6d5A09d580C699f2E1825FD82De0072c19CBB1c3);
        borrowHandler.createLimitOrder(7467439383852011517406059154017456445328143461, 2586586277);
        vm.prank(0x0000000000000000000000000000000000000b7b);
        borrowHandler.createLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639934, 340282366920938463463374607431768211455);
        vm.prank(0x000000000000000000000000000000000000001D);
        borrowHandler.changeBaseRate(5184238);

        this.invariant_CDPVault_R_C();
    }

    function test_invariant_assert_2() public {
        vm.prank(0xE56b56A5b44f59fA3D6313505f7481d2EfF5827F);
        borrowHandler.changeBaseRate(0);
        vm.prank(0x000000000000000000000000000000000000071A);
        borrowHandler.changeLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639934, 340282366920938463463374607431768211453);
        vm.prank(0x0000000000000000000000000000000000004c57);
        borrowHandler.changeSpotPrice(2);
        vm.prank(0x2E8FaA80D313b2E4F06C1f67cb6B377Fc954D9F7);
        borrowHandler.cancelLimitOrder(115792089237316195423570985008687907853269984665640492760172293618133583204025);
        vm.prank(0x0000000000000001431d9Bc7BDef557EE7D70b56);
        borrowHandler.changeSpotPrice(1013);
        vm.prank(0x0000000000000000000000000F0bDc3E9F528080);
        borrowHandler.borrow(80250000000000000000, 32103977574987514591268);
        vm.prank(0x00000000000000000000000000000000000001e7);
        borrowHandler.cancelLimitOrder(2592359);
        vm.prank(0x2034330000000000000000000000000000000000);
        borrowHandler.createLimitOrder(4952, 3656);
        vm.prank(0x0000000000000000000000018efC84Ad0C7b0000);
        borrowHandler.createLimitOrder(30049578511147215784808879450479816098762282572361362476888573685760240727857, 7462);
        vm.prank(0x0000000000000000000000000000000000003e87);
        borrowHandler.borrow(11961, 72313055129707293933198865995446524301307177293716734526449411585108378060670);
        vm.prank(0x311Ae25dc8f3857cAc969008C3A84C2E95498f2A);
        borrowHandler.changeLimitOrder(24519, 189590075938990945945547731118945731931);
        vm.prank(0x000000000000000000278A3559b87f9A29a6f90e);
        borrowHandler.cancelLimitOrder(17092477508858612190206351198582598327893507962323965476117266379426493004);
        vm.prank(0x00000000000000000000000000000000000036f1);
        borrowHandler.createLimitOrder(1000064094670471328, 2111);
        vm.prank(0x0000000000000000000000000000000000004A7d);
        borrowHandler.changeLimitOrder(12883, 9528);
        vm.prank(0x0000000000000000000000000000000000000091);
        borrowHandler.borrow(19306, 350);
        vm.prank(0x0000000000000000000000000000000000005957);
        borrowHandler.changeLimitOrder(115792089237316195423570985008687907853269984665640564039457584007913129639933, 1);

        this.invariant_IRM_F();
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
