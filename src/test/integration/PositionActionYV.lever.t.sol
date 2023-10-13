// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PositionAction, LeverParams} from "../../proxy/PositionAction.sol";
import {PositionActionYV} from "../../proxy/PositionActionYV.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {WAD} from "../../utils/Math.sol";
import {IYVault} from "../../vendor/IYVault.sol";


contract PositionActionYV_Lever_Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // vaults
    CDPVault_TypeA yvDaiVault;
    CDPVault_TypeA yvUsdtVault;

    // actions
    PositionActionYV positionAction;

    // yearn vaults
    IYVault yvDAI = IYVault(0xdA816459F1AB5631232FE5e97a05BBBb94970c95);
    IYVault yvUSDT = IYVault(0x3B27F92C0e212C671EA351827EDF93DB27cc0c65);

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    function setUp() public override {
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(10_000_000 ether);

        // deploy vaults
        yvDaiVault = createCDPVault_TypeA(
            yvDAI, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            WAD, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        yvUsdtVault = createCDPVault_TypeA(
            yvUSDT, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            WAD, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        // add liquidity to yearn vaults to simulate withdrawals
        _yearnVaultDeposit(yvDAI, 1_000_000*1e18);
        _yearnVaultDeposit(yvUSDT, 1_000_000*1e6);

        // deploy actions
        swapAction = new SwapAction(balancerVault, univ3Router);
        positionAction = new PositionActionYV(address(flashlender), address(swapAction), address(poolAction));

        // configure oracle spot prices
        oracle.updateSpot(address(yvDAI), yvDAI.pricePerShare());
        oracle.updateSpot(address(yvUSDT), yvUSDT.pricePerShare()*1e12);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        vm.label(address(yvDAI), "yvDAI");
        vm.label(address(yvUSDT), "yvUSDT");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(user), "user");
        vm.label(address(yvDaiVault), "yvDaiVault");
        vm.label(address(yvUsdtVault), "yvUsdtVault");
        vm.label(address(positionAction), "positionAction");
        vm.label(address(stablePool), "balancerStablePool");

        stablePoolIdArray.push(stablePoolId);
    }

    function test_increaseLever() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 ether;

        // mint DAI to user
        deal(address(DAI), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvDaiVault),
            collateralToken: address(yvDAI),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount, // amount of stablecoin to swap in
                limit: amountOutMin, // min amount of DAI to receive
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap, // no aux swap
            auxAction: emptyJoin 
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, expectedAmountOut + upFrontUnderliers);

        // approve DAI to userProxy
        vm.prank(user);
        DAI.approve(address(userProxy), upFrontUnderliers);

        // increase lever
        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(DAI),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedCollateral);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    function test_increaseLever_USDT() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 * 1e6;

        // mint DAI to user
        deal(address(USDT), user, upFrontUnderliers);

        // build increase lever params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDT);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvUsdtVault),
            collateralToken: address(yvUSDT),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount, // amount of stablecoin to swap in
                limit: amountOutMin, // min amount of USDT to receive
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvUSDT, expectedAmountOut + upFrontUnderliers) * 1e12;

        // approve DAI to userProxy
        vm.startPrank(user);
        USDT.safeApprove(address(userProxy), upFrontUnderliers);
        vm.stopPrank();

        // increase lever
        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(USDT),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of USDT received from the swap
        assertEq(collateral, expectedCollateral);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvUsdtVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvUSDT.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvUSDT.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    function test_decreaseLever() public {
        _increaseLever(
            userProxy,
            yvDaiVault,
            20_000 ether,
            70_000 ether,
            69_000 ether
        );

        (uint256 initialCollateral, uint256 initialNormalDebt) = yvDaiVault.positions(address(userProxy));

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;
        uint256 subCollateral = _simulateYearnVaultDeposit(yvDAI, maxAmountIn); // yvDAI to withdraw from CDP vault

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvDaiVault),
            collateralToken: address(yvDAI),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(DAI),
                amount: amountOut, // exact amount of stablecoin to receive
                limit: maxAmountIn, // max amount of DAI to pay
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, subCollateral);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy
        assertEq(DAI.balanceOf(address(userProxy)), expectedWithdrawAmount - expectedAmountIn);

        // ensure there isn't any left over debt or collateral from using positionAction
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }


    function test_decreaseLever_with_interest() public {
        _increaseLever(
            userProxy,
            yvDaiVault,
            20_000 ether,
            70_000 ether,
            69_000 ether
        );

        (uint256 initialCollateral, uint256 initialNormalDebt) = yvDaiVault.positions(address(userProxy));

        // accrue interest
        vm.warp(block.timestamp + 365 days);

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;
        uint256 subCollateral = _simulateYearnVaultDeposit(yvDAI, maxAmountIn); // yvDAI to withdraw from CDP vault

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvDaiVault),
            collateralToken: address(yvDAI),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(DAI),
                amount: amountOut, // exact amount of stablecoin to receive
                limit: maxAmountIn, // max amount of DAI to pay
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, subCollateral);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - _debtToNormalDebt(address(yvDaiVault), address(userProxy), amountOut));

        // assert that the left over was transfered to the user proxy
        assertEq(DAI.balanceOf(address(userProxy)), expectedWithdrawAmount - expectedAmountIn);

        // ensure there isn't any left over debt or collateral from using positionAction
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    function test_decreaseLever_USDT() public {
        _increaseLever(
            userProxy,
            yvUsdtVault,
            20_000 * 1e6,
            70_000 ether,
            69_000 * 1e6
        );

        (uint256 initialCollateral, uint256 initialNormalDebt) = yvUsdtVault.positions(address(userProxy));

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 * 1e6;
        uint256 subCollateral = _simulateYearnVaultDeposit(yvUSDT, maxAmountIn) * 1e12; // yvUSDT to withdraw from CDP vault

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDT);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvUsdtVault),
            collateralToken: address(yvUSDT),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(USDT),
                amount: amountOut, // exact amount of stablecoin to receive
                limit: maxAmountIn, // max amount of USDT to pay
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvUSDT, subCollateral/1e12);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of collateral we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping collateral
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy
        assertEq(expectedWithdrawAmount - expectedAmountIn, USDT.balanceOf(address(userProxy)));

        // ensure there isn't any left over debt or collateral from using positionAction
        (uint256 lcollateral, uint256 lnormalDebt) = yvUsdtVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        assertEq(yvUSDT.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // test increaseLever 18 decimals to 18 decimals
    function test_increaseLever_yvDAI_vault_with_aux_swap_from_WETH() public {
        uint256 upFrontUnderliers = 20 ether;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = borrowAmount * 99 / 100;
        uint256 auxMinAmountOut = (upFrontUnderliers * _getWethRateInDai() / 1e18) * 98 / 100;

        // mint USDT to user
        deal(address(WETH), user, upFrontUnderliers);

        LeverParams memory leverParams;
        {
            // build increase lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            bytes32[] memory auxPoolIds = new bytes32[](1);
            auxPoolIds[0] = wethDaiPoolId;

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(WETH);
            auxAssets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(yvDaiVault),
                collateralToken: address(yvDAI),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: borrowAmount, // amount of stablecoin to swap in
                    limit: amountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(WETH),
                    amount: upFrontUnderliers, // amount of WETH to swap in
                    limit: auxMinAmountOut, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(auxPoolIds, auxAssets)
                }),
                auxAction: emptyJoin
            });
        }

        (uint256 expectedAuxAmountOut, uint256 expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, expectedAmountOut + expectedAuxAmountOut);

        vm.prank(user);
        WETH.approve(address(userProxy), upFrontUnderliers);

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(WETH),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedCollateral);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    // test decreaseLever 18 decimals to 18 decimals
    function test_decreaseLever_yvDAI_vault_with_aux_swap_to_WETH() public {
        _increaseLever(
            userProxy,
            yvDaiVault,
            20_000 ether,
            70_000 ether,
            69_000 ether
        );

        (uint256 initialCollateral, uint256 initialNormalDebt) = yvDaiVault.positions(address(userProxy));

        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;
        uint256 subCollateral = _simulateYearnVaultDeposit(yvDAI, maxAmountIn); // yvDAI to withdraw from CDP vault
        uint256 minResidualRate = _getDaiRateInWeth() * 99 / 100;
        uint256 expectedAmountIn;
        uint256 expectedAuxAmountOut;
        LeverParams memory leverParams;
        {
            // build decrease lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            bytes32[] memory auxPoolIds = new bytes32[](2);
            auxPoolIds[0] = daiOhmPoolId;
            auxPoolIds[1] = wethOhmPoolId;

            address[] memory auxAssets = new address[](3);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(OHM);
            auxAssets[2] = address(WETH);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(yvDaiVault),
                collateralToken: address(yvDAI),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(DAI),
                    amount: amountOut, // exact amount of stablecoin to receive
                    limit: maxAmountIn, // max amount of DAI to pay
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(DAI),
                    amount: 0, // autocalculated
                    limit: 0, // autocalculated using minResidualRate
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(auxPoolIds, auxAssets)
                }),
                auxAction: emptyJoin
            });
        }

        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, subCollateral);


        // calculate auxSwap values to get expected amounts in and out
        expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        leverParams.auxSwap.amount = expectedWithdrawAmount - expectedAmountIn;
        leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 10**ERC20(leverParams.auxSwap.assetIn).decimals();
        
        // simulate the primary and aux swap results
        (expectedAmountIn, expectedAuxAmountOut) = _simulateBalancerSwapMulti(leverParams.primarySwap, leverParams.auxSwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(user) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // // assert that the left over was transfered to the user proxy
        assertEq(expectedAuxAmountOut, WETH.balanceOf(address(user)));

        // ensure there isn't any left over debt or collateral from using positionAction
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    // test increaseLever 18 decimals to 6 decimals
    function test_increaseLever_yvDAI_vault_with_aux_swap_from_USDT() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 ether;

        // mint USDT to user
        deal(address(USDT), user, upFrontUnderliers);

        LeverParams memory leverParams;
        {
            // build increase lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDT);
            auxAssets[1] = address(DAI);

            uint256 auxMinAmountOut = upFrontUnderliers*1e12*99/100;

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(yvDaiVault),
                collateralToken: address(yvDAI),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: borrowAmount, // amount of stablecoin to swap in
                    limit: amountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDT),
                    amount: upFrontUnderliers, // amount of USDT to swap in
                    limit: auxMinAmountOut, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }),
                auxAction: emptyJoin
            });
        }

        (uint256 expectedAuxAmountOut, uint256 expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, expectedAmountOut + expectedAuxAmountOut);

        // approve DAI to userProxy
        vm.startPrank(user);
        USDT.safeApprove(address(userProxy), upFrontUnderliers);
        vm.stopPrank();

        // increase lever
        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(USDT),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedCollateral);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    // test decreaseLever 18 decimals to 6 decimals
    function test_decrease_yvDAI_vault_with_aux_swap_to_USDT() public {
        _increaseLever(
            userProxy,
            yvDaiVault,
            20_000 ether,
            70_000 ether,
            69_000 ether
        );

        (uint256 initialCollateral, uint256 initialNormalDebt) = yvDaiVault.positions(address(userProxy));

        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;
        uint256 subCollateral = _simulateYearnVaultDeposit(yvDAI, maxAmountIn); // yvDAI to withdraw from CDP vault
        uint256 minResidualRate = 1e6 * 99 / 100; // in USDT decimals
        uint256 expectedAmountIn;
        uint256 expectedAuxAmountOut;
        LeverParams memory leverParams;
        {
            // build decrease lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(USDT);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(yvDaiVault),
                collateralToken: address(yvDAI),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(DAI),
                    amount: amountOut, // exact amount of stablecoin to receive
                    limit: maxAmountIn, // max amount of DAI to pay
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(DAI),
                    amount: 0, // autocalculated
                    limit: 0, // autocalculated using minResidualRate
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }),
                auxAction: emptyJoin
            });
        }

        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, subCollateral);


        // calculate auxSwap values to get expected amounts in and out
        expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        leverParams.auxSwap.amount = expectedWithdrawAmount - expectedAmountIn;
        leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 10**ERC20(leverParams.auxSwap.assetIn).decimals();
        
        // simulate the primary and aux swap results
        (expectedAmountIn, expectedAuxAmountOut) = _simulateBalancerSwapMulti(leverParams.primarySwap, leverParams.auxSwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(user) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // // assert that the left over was transfered to the user proxy
        assertEq(expectedAuxAmountOut, USDT.balanceOf(address(user)));

        // ensure there isn't any left over debt or collateral from using positionAction
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    // test increaseLever 6 decimals to 6 decimals
    function test_increaseLever_yvUSDT_vault_with_aux_swap_from_USDC() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 * 1e6;

        // mint USDT to user
        deal(address(USDC), user, upFrontUnderliers);

        LeverParams memory leverParams;
        {
            // build increase lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDT);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDC);
            auxAssets[1] = address(USDT);

            uint256 auxMinAmountOut = upFrontUnderliers*99/100;

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(yvUsdtVault),
                collateralToken: address(yvUSDT),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: borrowAmount, // amount of stablecoin to swap in
                    limit: amountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDC),
                    amount: upFrontUnderliers, // amount of USDT to swap in
                    limit: auxMinAmountOut, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }),
                auxAction: emptyJoin
            });
        }

        (uint256 expectedAuxAmountOut, uint256 expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvUSDT, expectedAmountOut + expectedAuxAmountOut);

        // approve DAI to userProxy
        vm.startPrank(user);
        USDC.safeApprove(address(userProxy), upFrontUnderliers);
        vm.stopPrank();

        // increase lever
        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(USDC),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedCollateral*1e12);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvUSDT.balanceOf(address(positionAction)), 0);
        assertEq(USDC.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvUSDT.balanceOf(address(userProxy)), 0);
        assertEq(USDC.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    // test decreaseLever 6 decimals to 6 decimals
    function test_decreaseLever_yvUSDT_vault_with_aux_swap_to_USDC() public {
        _increaseLever(
            userProxy,
            yvUsdtVault,
            20_000 * 1e6,
            70_000 ether,
            69_000 * 1e6
        );

        (uint256 initialCollateral, uint256 initialNormalDebt) = yvUsdtVault.positions(address(userProxy));

        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 * 1e6;
        uint256 subCollateral = _simulateYearnVaultDeposit(yvUSDT, maxAmountIn) * 1e12; // yvDAI to withdraw from CDP vault
        uint256 minResidualRate = 1e6 * 99 / 100;
        uint256 expectedAmountIn;
        uint256 expectedAuxAmountOut;
        LeverParams memory leverParams;
        {
            // build decrease lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDT);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDT);
            auxAssets[1] = address(USDC);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(yvUsdtVault),
                collateralToken: address(yvUSDT),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDT),
                    amount: amountOut, // exact amount of stablecoin to receive
                    limit: maxAmountIn, // max amount of DAI to pay
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDT),
                    amount: 0, // autocalculated
                    limit: 0, // autocalculated using minResidualRate
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }),
                auxAction: emptyJoin
            });
        }

        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvUSDT, subCollateral/1e12);


        // calculate auxSwap values to get expected amounts in and out
        expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        leverParams.auxSwap.amount = expectedWithdrawAmount - expectedAmountIn;
        leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 10**ERC20(leverParams.auxSwap.assetIn).decimals();
        
        // simulate the primary and aux swap results
        (expectedAmountIn, expectedAuxAmountOut) = _simulateBalancerSwapMulti(leverParams.primarySwap, leverParams.auxSwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(user) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy
        assertEq(expectedAuxAmountOut, USDC.balanceOf(address(user)));

        // ensure there isn't any left over debt or collateral from using positionAction
        (uint256 lcollateral, uint256 lnormalDebt) = yvUsdtVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvUSDT.balanceOf(address(positionAction)), 0);
        assertEq(USDC.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(USDC.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    function test_increaseLever_yvDAI_vault_with_yvDAI_upfront() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 ether;

        // mint yvDAI to user
        upFrontUnderliers = _mintYVaultToken(yvDAI, address(DAI), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvDaiVault),
            collateralToken: address(yvDAI),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount, // amount of stablecoin to swap in
                limit: amountOutMin, // min amount of DAI to receive
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        uint256 expectedLeverCollateral = _simulateYearnVaultDeposit(yvDAI, expectedAmountOut);

        // approve DAI to userProxy
        vm.prank(user);
        yvDAI.approve(address(userProxy), upFrontUnderliers);

        // increase lever
        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(yvDAI),
                upFrontUnderliers,
                user,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedLeverCollateral + upFrontUnderliers);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvDaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvDAI.balanceOf(address(positionAction)), 0);
        assertEq(DAI.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvDAI.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    }

    function test_increaseLever_yvUSDT_vault_with_yvUSDT_upfront() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 * 1e6;

        // mint yvUSDT to user
        upFrontUnderliers = _mintYVaultToken(yvUSDT, address(USDT), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDT);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(yvUsdtVault),
            collateralToken: address(yvUSDT),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount, // amount of stablecoin to swap in
                limit: amountOutMin, // min amount of USDT to receive
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        uint256 expectedLeverCollateral = _simulateYearnVaultDeposit(yvUSDT, expectedAmountOut);

        // approve USDT to userProxy
        vm.prank(user);
        yvUSDT.approve(address(userProxy), upFrontUnderliers);

        // increase lever
        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(yvUSDT),
                upFrontUnderliers,
                user,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of USDT received from the swap
        assertEq(collateral, (expectedLeverCollateral + upFrontUnderliers) * 1e12);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert positionAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = yvUsdtVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // assert there are no left over tokens on either the userProxy or positionAction contract
        assertEq(yvUSDT.balanceOf(address(positionAction)), 0);
        assertEq(USDC.balanceOf(address(positionAction)), 0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);

        assertEq(yvUSDT.balanceOf(address(userProxy)), 0);
        assertEq(USDC.balanceOf(address(userProxy)), 0);
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);


    }

    // simple helper function to increase lever
    function _increaseLever(
        PRBProxy proxy,
        CDPVault vault,
        uint256 upFrontUnderliers,
        uint256 amountToLever,
        uint256 amountToLeverLimit
    ) public {
        LeverParams memory leverParams;
        address upFrontToken;
        {
            address vaultToken = address(vault.token());
            upFrontToken = address(IYVault(vaultToken).token());

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(upFrontToken);

            // mint directly to proxy for simplicity
            if (upFrontUnderliers > 0) deal(upFrontToken, address(proxy), upFrontUnderliers);

            leverParams = LeverParams({
                position: address(proxy),
                vault: address(vault),
                collateralToken: address(vault.token()),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: amountToLever, // amount of stablecoin to swap in
                    limit: amountToLeverLimit, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: emptySwap,
                auxAction: emptyJoin
            });
        }

        vm.startPrank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                upFrontToken,
                upFrontUnderliers,
                address(proxy),
                emptyPermitParams
            )
        );
        vm.stopPrank();
    }

    function _mintYVaultToken(IYVault yVault, address underlier, address to, uint256 assets) internal returns (uint256 shares) {
        deal(underlier, address(this), assets);
        ERC20(underlier).forceApprove(address(yVault), assets);
        shares = yVault.deposit(assets);
        ERC20(address(yVault)).safeTransfer(to, shares);
    }

    /// @dev simulate yearn vault deposit to calculate the expected shares out
    function _simulateYearnVaultDeposit(IYVault yVault, uint256 assets) internal returns (uint256 shares) {
        uint256 snapshot = vm.snapshot();
        shares = _yearnVaultDeposit(yVault, assets);
        vm.revertTo(snapshot);
    }

    /// @dev simulate yearn vault withdrawal to calculate the expected assets out
    function _simulateYearnVaultWithdraw(IYVault yVault, uint256 shares) internal returns (uint256 assets) {
        uint256 snapshot = vm.snapshot();
        assets = yVault.withdraw(shares);
        vm.revertTo(snapshot);
    }

    /// @dev deposit into yearn vault and return shares out
    function _yearnVaultDeposit(IYVault yVault, uint256 assets) internal returns (uint256 shares) {
        address token = yVault.token();

        // mint assetIn to positionAction so we can execute the swap
        deal(token, address(this), assets);

        ERC20(token).safeApprove(address(yVault), assets);
        shares = yVault.deposit(assets);
    }
}