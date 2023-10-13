// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {IYVault} from "../../vendor/IYVault.sol";
import {WAD} from "../../utils/Math.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PositionAction, CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {PositionActionYV} from "../../proxy/PositionActionYV.sol";

contract PositionActionYVTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
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
        cdm.setParameter("globalDebtCeiling", 15_000_000 * 1e18);

        // deploy vaults
        yvUsdtVault = createCDPVault_TypeA(
            yvUSDT, // token
            5_000_000 * 1e18, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target heatlh factor
            WAD, // price tick to rebate factor conversion bias
            WAD, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        yvDaiVault = createCDPVault_TypeA(
            yvDAI, // token
            5_000_000 * 1e18, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target heatlh factor
            WAD, // price tick to rebate factor conversion bias
            WAD, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        // configure oracle spot prices
        oracle.updateSpot(address(yvDAI), yvDAI.pricePerShare());
        oracle.updateSpot(address(yvUSDT), yvUSDT.pricePerShare()*1e12);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // deploy borrow actions
        positionAction = new PositionActionYV(address(flashlender), address(swapAction), address(poolAction));

        // add liquidity to yearn vaults to simulate withdrawals
        _yearnVaultDeposit(yvDAI, 1_000_000*1e18, address(this));
        _yearnVaultDeposit(yvUSDT, 1_000_000*1e6, address(this));

        vm.label(address(yvDAI), "yvDAI");
        vm.label(address(yvUSDT), "yvUSDT");

        // setup state variables to avoid stack too deep
        stablePoolIdArray.push(stablePoolId);
    }

    function test_deposit() public {

        // mint yvDAI
        uint256 depositAmount = _yearnVaultDeposit(yvDAI, 10_000 * 1e18, user);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(yvDAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });

        vm.prank(user);
        yvDAI.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(userProxy),
                address(yvDaiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_yvUSDT() public {
        // mint yvDAI
        uint256 depositAmount = _yearnVaultDeposit(yvUSDT, 10_000 * 1e6, user);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(yvUSDT),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });

        vm.prank(user);
        yvUSDT.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(userProxy),
                address(yvUsdtVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        assertEq(collateral, depositAmount * 1e12);
        assertEq(normalDebt, 0);
    }

    function test_deposit_yvDAI_with_DAI() public {
        uint256 depositAmount = 10_000*1e18;
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);
        deal(address(DAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });

        vm.prank(user);
        DAI.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(userProxy),
                address(yvDaiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, 0);
    }

    function test_deposit_yvDAI_vault_with_entry_swap_from_USDC() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 amountOutMin = depositAmount * 1e12 * 99 / 100; // convert 6 decimals to 18 and add 1% slippage

        deal(address(USDC), user, depositAmount);

        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(DAI);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(USDC),
                amount: depositAmount, // amount to swap in
                limit: amountOutMin, // min amount of collateral token to receive
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedCollateral = _simulateBalancerSwap(collateralParams.auxSwap);
        expectedCollateral = _simulateYearnVaultDeposit(yvDAI, expectedCollateral);

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(userProxy),
                address(yvDaiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, 0);
    }

    function test_deposit_yvUSDT_vault_with_USDT() public {
        uint256 depositAmount = 10_000*1e6;
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvUSDT, depositAmount);
        deal(address(USDT), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDT),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.startPrank(user);
        USDT.safeApprove(address(userProxy), depositAmount);
        vm.stopPrank();

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(userProxy),
                address(yvUsdtVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral * 1e12);
        assertEq(normalDebt, 0);
    }

    function test_deposit_yvUSDT_vault_with_entry_swap_from_DAI() public {
        uint256 depositAmount = 10_000 * 1e18;
        uint256 amountOutMin = depositAmount * 99 / 100e12; // convert 18 decimals to 6 and add 1% slippage

        deal(address(DAI), user, depositAmount);

        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(DAI);
        assets[1] = address(USDT);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(DAI),
                amount: depositAmount, // amount to swap in
                limit: amountOutMin, // min amount of collateral token to receive
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedCollateral = _simulateBalancerSwap(collateralParams.auxSwap);
        expectedCollateral = _simulateYearnVaultDeposit(yvUSDT, expectedCollateral);

        vm.prank(user);
        DAI.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(userProxy),
                address(yvUsdtVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvUsdtVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral * 1e12);
        assertEq(normalDebt, 0);
    }

    function test_withdraw() public {
        // deposit DAI to vault
        uint256 initialDeposit = _deposit(userProxy, address(yvDaiVault), 1_000 * 1e18);

        // build withdraw params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(yvDAI),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(yvDaiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
    }

    function test_withdraw_and_swap() public {
        // deposit DAI to vault
        uint256 initialDeposit = _deposit(userProxy, address(yvDaiVault), 1_000*1e18);
        uint256 expectedWithdraw = _simulateYearnVaultWithdraw(yvDAI, initialDeposit);

        // build withdraw params
        uint256 expectedAmountOut;
        CollateralParams memory collateralParams;
        {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(DAI);
            assets[1] = address(USDT);

            collateralParams = CollateralParams({
                targetToken: address(DAI),
                amount: initialDeposit,
                collateralizer: address(user),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(DAI),
                    amount: expectedWithdraw,
                    limit: expectedWithdraw/1e12 * 99/100,
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                })
            });
            expectedAmountOut = _simulateBalancerSwap(collateralParams.auxSwap);
        }

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(yvDaiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(USDT.balanceOf(address(user)), expectedAmountOut);
    }

    function test_withdraw_USDT_and_swap_DAI() public {
        // deposit USDT to vault
        uint256 initialDeposit = _deposit(userProxy, address(yvUsdtVault), 1_000 * 1e6);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvUSDT, initialDeposit);

        // build withdraw params
        uint256 expectedAmountOut;
        CollateralParams memory collateralParams;
        {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(USDT);
            assets[1] = address(DAI);

            collateralParams = CollateralParams({
                targetToken: address(DAI),
                amount: initialDeposit*1e12,
                collateralizer: address(user),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDT),
                    amount: expectedWithdrawAmount,
                    limit: expectedWithdrawAmount*1e12 * 99/100,
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                })
            });
            expectedAmountOut = _simulateBalancerSwap(collateralParams.auxSwap);
        }

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(yvUsdtVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 debt) = yvUsdtVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(DAI.balanceOf(address(user)), expectedAmountOut);
    }

    function test_borrow() public {
        uint256 depositAmount = 10_000 * 1e18;
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);
        _deposit(userProxy, address(yvDaiVault), depositAmount);

        uint256 borrowAmount = 5_000 * 1e18;

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: emptySwap // no exit swap
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.borrow.selector,
                address(userProxy),
                address(yvDaiVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        assertEq(stablecoin.balanceOf(user), borrowAmount);
    }

    function test_borrow_yvDAI_vault_with_exit_swap_to_USDC() public {
        uint256 depositAmount = 10_000 * 1e18;
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);
        _deposit(userProxy, address(yvDaiVault), depositAmount);

        uint256 borrowAmount = 5_000 * 1e18; // borrow 5k stablecoin
        uint256 minAmountOut = borrowAmount * 99 / 100e12; // convert from stablecoin to usdc decimals

        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDC);

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount, // the amount of stablecoin to print
            creditor: user,
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount,
                limit: minAmountOut,
                recipient: address(user),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(creditParams.auxSwap);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.borrow.selector,
                address(userProxy),
                address(yvDaiVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        assertEq(USDC.balanceOf(user), expectedAmountOut);
    }

    function test_repay() public {
        uint256 depositAmount = 1_000*1e18; // DAI
        uint256 borrowAmount = 500*1e18; // stablecoin
        _depositAndBorrow(userProxy, address(yvDaiVault), depositAmount, borrowAmount);
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);

        // build repay params
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: emptySwap // no entry swap
        });

        vm.startPrank(user);
        stablecoin.approve(address(userProxy), borrowAmount);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.repay.selector,
                address(userProxy), // user proxy is the position
                address(yvDaiVault),
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_repay_from_swap() public {
        uint256 depositAmount = 1_000*1e18; // DAI
        uint256 borrowAmount = 500*1e18; // stablecoin
        _depositAndBorrow(userProxy, address(yvDaiVault), depositAmount, borrowAmount);
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);

        // mint usdc to pay back with
        uint256 swapAmount = borrowAmount/1e12 * 101/100;
        deal(address(USDC), address(user), swapAmount);

        // get rid of the stablecoin that was borrowed
        vm.prank(user);
        stablecoin.transfer(address(0x1), borrowAmount);

       // build repay params
       uint256 expectedAmountIn;
       CreditParams memory creditParams;
       {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDC);

            creditParams = CreditParams({
                amount: borrowAmount,
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: borrowAmount,
                    limit: swapAmount,
                    recipient: address(userProxy),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                })
            });
            expectedAmountIn = _simulateBalancerSwap(creditParams.auxSwap);
       }

       vm.startPrank(user);
       USDC.approve(address(userProxy), swapAmount);
       userProxy.execute(
           address(positionAction),
           abi.encodeWithSelector(
               positionAction.repay.selector,
               address(userProxy), // user proxy is the position
               address(yvDaiVault),
               creditParams,
               emptyPermitParams
           )
       );
       vm.stopPrank();

       (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
       uint256 creditAmount = credit(address(userProxy));

       assertEq(collateral, expectedCollateral);
       assertEq(debt, 0);
       assertEq(creditAmount, 0);
       assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_repay_from_swap_EXACT_IN() public {
        uint256 depositAmount = 1_000*1e18; // DAI
        uint256 borrowAmount = 500*1e18; // stablecoin
        _depositAndBorrow(userProxy, address(yvDaiVault), depositAmount, borrowAmount);
        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);

        // mint usdc to pay back with
        uint256 swapAmount = borrowAmount/2e12 * 101/100; // repay ~half debt
        deal(address(USDC), address(user), swapAmount);

        // get rid of the stablecoin that was borrowed
        vm.prank(user);
        stablecoin.transfer(address(0x1), borrowAmount);

       // build repay params
       uint256 expectedAmountOut;
       CreditParams memory creditParams;
       {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(USDC);
            assets[1] = address(stablecoin);

            creditParams = CreditParams({
                amount: borrowAmount/2, // swap amount out is used if auxSwap is present
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDC),
                    amount: swapAmount,
                    limit: borrowAmount/2,
                    recipient: address(userProxy),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                })
            });
            expectedAmountOut = _simulateBalancerSwap(creditParams.auxSwap);
       }

       vm.startPrank(user);
       USDC.approve(address(userProxy), swapAmount);
       userProxy.execute(
           address(positionAction),
           abi.encodeWithSelector(
               positionAction.repay.selector,
               address(userProxy), // user proxy is the position
               address(yvDaiVault),
               creditParams,
               emptyPermitParams
           )
       );
       vm.stopPrank();

       (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
       uint256 creditAmount = credit(address(userProxy));

       assertEq(collateral, expectedCollateral);
       assertEq(debt, borrowAmount/2);
       assertEq(creditAmount, expectedAmountOut - borrowAmount/2); // any leftover is stored as credit
       assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_depositAndBorrow() public {
        uint256 depositAmount = 10_000 * 1e18;
        uint256 expectedCollateral = _yearnVaultDeposit(yvDAI, depositAmount, user);
        
        uint256 borrowAmount = 5_000*1e18;

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(yvDAI),
            amount: expectedCollateral,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: emptySwap
        });

        vm.prank(user);
        yvDAI.approve(address(userProxy), expectedCollateral);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.depositAndBorrow.selector,
                address(userProxy),
                address(yvDaiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        assertEq(stablecoin.balanceOf(user), borrowAmount);
    }

    // enter a yvDAI vault with USDC and exit with USDT
    function test_depositAndBorrow_with_entry_and_exit_swap() public {
        uint256 depositAmount = 10_000*1e6; // in USDC
        uint256 borrowAmount = 5_000*1e18; // in stablecoin

        deal(address(USDC), user, depositAmount);

        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        uint256 expectedCollateral;
        uint256 expectedExitAmount;
        {
            address[] memory entryAssets = new address[](2);
            entryAssets[0] = address(USDC);
            entryAssets[1] = address(DAI);

            address[] memory exitAssets = new address[](2);
            exitAssets[0] = address(stablecoin);
            exitAssets[1] = address(USDT);

            collateralParams = CollateralParams({
                targetToken: address(USDC),
                amount: 0,
                collateralizer: address(user),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDC),
                    amount: depositAmount,
                    limit: depositAmount * 1e12 * 98 / 100, // amountOutMin in DAI 
                    recipient: address(userProxy),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, entryAssets)
                })
            });
            creditParams = CreditParams({
                amount: borrowAmount,
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: borrowAmount,
                    limit: borrowAmount * 98 / 100e12, // amountOutMin in USDT
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, exitAssets)
                })
            });

            (expectedCollateral, expectedExitAmount) = _simulateBalancerSwapMulti(collateralParams.auxSwap, creditParams.auxSwap);
            expectedCollateral = _simulateYearnVaultDeposit(yvDAI, expectedCollateral);
        }

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.depositAndBorrow.selector,
                address(userProxy),
                address(yvDaiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        assertEq(USDT.balanceOf(user), expectedExitAmount);
    }

    // enter a yvDAI vault with USDC and exit with USDT
    function test_depositAndBorrow_with_EXACT_OUT_entry_and_exit_swap() public {
        uint256 depositAmount = 10_000*1e6; // in USDC
        uint256 borrowAmount = 5_000*1e18; // in stablecoin

        deal(address(USDC), user, depositAmount);

        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        uint256 expectedEntryIn;
        uint256 expectedExitIn;
        uint256 expectedCollateral = depositAmount * 98e12 / 100; // in dai
        uint256 expectedExit = borrowAmount * 98/100e12; // in usdt
        {
            bytes32[] memory entryPoolIds = new bytes32[](1);
            entryPoolIds[0] = stablePoolId;

            address[] memory entryAssets = new address[](2);
            entryAssets[0] = address(DAI);
            entryAssets[1] = address(USDC);

            bytes32[] memory exitPoolIds = new bytes32[](1);
            exitPoolIds[0] = stablePoolId;

            address[] memory exitAssets = new address[](2);
            exitAssets[0] = address(USDT);
            exitAssets[1] = address(stablecoin);

            collateralParams = CollateralParams({
                targetToken: address(USDC),
                amount: 0,
                collateralizer: address(user),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: expectedCollateral, // exact out in DAI
                    limit: depositAmount, // amountInMax in USDC
                    recipient: address(userProxy),
                    deadline: block.timestamp + 100,
                    args: abi.encode(entryPoolIds, entryAssets)
                })
            });
            creditParams = CreditParams({
                amount: borrowAmount,
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(stablecoin),
                    amount: expectedExit, // exact out in USDT
                    limit: borrowAmount, // amountInMax in stablecoin
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(exitPoolIds, exitAssets)
                })
            });

            (expectedEntryIn, expectedExitIn) = _simulateBalancerSwapMulti(collateralParams.auxSwap, creditParams.auxSwap);
            expectedCollateral = _simulateYearnVaultDeposit(yvDAI, expectedCollateral);
        }

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.depositAndBorrow.selector,
                address(userProxy),
                address(yvDaiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = yvDaiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        // validate that the swap amounts are as expected w/ residual amounts being sent to msg.sender
        assertEq(USDT.balanceOf(user), expectedExit);
        assertEq(stablecoin.balanceOf(user), borrowAmount - expectedExitIn);

        // validate resiudals from entry swap
        assertEq(USDC.balanceOf(address(user)), depositAmount - expectedEntryIn);

        // validate that there is no unexpected dust
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
    }

    function test_withdrawAndRepay() public {
        uint256 depositAmount = 1_000*1e18;
        uint256 borrowAmount = 250*1e18;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(yvDaiVault), depositAmount, borrowAmount);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, expectedCollateral);


        // build withdraw and repay params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        {
            collateralParams = CollateralParams({
                targetToken: address(DAI),
                amount: expectedCollateral,
                collateralizer: user,
                auxSwap: emptySwap
            });
            creditParams = CreditParams({
                amount: borrowAmount,
                creditor: user,
                auxSwap: emptySwap
            });
        }

        vm.startPrank(user);
        stablecoin.approve(address(userProxy), borrowAmount);

        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdrawAndRepay.selector,
                address(userProxy), // user proxy is the position
                address(yvDaiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();


        (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(stablecoin.balanceOf(user), 0);
        assertEq(DAI.balanceOf(user), expectedWithdrawAmount); // assert .01% accuracy due to withdrawal fees
    }

    function test_withdrawAndRepay_with_swaps() public {
        uint256 depositAmount = 5_000*1e18;
        uint256 borrowAmount = 2_500*1e18;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(yvDaiVault), depositAmount, borrowAmount);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, expectedCollateral);

        // spend users stablecoin
        vm.prank(user);
        stablecoin.transfer(address(0x1), borrowAmount);

        // build withdraw and repay params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        uint256 debtSwapMaxAmountIn = borrowAmount * 101 /100e12;
        uint256 debtSwapAmountIn;
        uint256 expectedCollateralOut;
        {
            address[] memory collateralAssets = new address[](2);
            collateralAssets[0] = address(DAI);
            collateralAssets[1] = address(USDC);

            address[] memory debtAssets = new address[](2);
            debtAssets[0] = address(stablecoin);
            debtAssets[1] = address(USDC);

            collateralParams = CollateralParams({
                targetToken: address(USDC),
                amount: expectedCollateral,
                collateralizer: user,
                auxSwap: SwapParams({ // swap DAI for USDC
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(DAI),
                    amount: expectedWithdrawAmount,
                    limit: expectedWithdrawAmount * 99/100e12,
                    recipient: address(user), // sent directly to the user
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, collateralAssets)
                })
            });
            creditParams = CreditParams({
                amount: borrowAmount,
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: borrowAmount,
                    limit: debtSwapMaxAmountIn,
                    recipient: address(userProxy), // must be sent to proxy
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, debtAssets)
                })
            });
            (debtSwapAmountIn, expectedCollateralOut) = _simulateBalancerSwapMulti(creditParams.auxSwap, collateralParams.auxSwap);
        }

        vm.startPrank(user);
        deal(address(USDC), address(user), debtSwapMaxAmountIn);
        USDC.approve(address(userProxy), debtSwapMaxAmountIn);

        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdrawAndRepay.selector,
                address(userProxy), // user proxy is the position
                address(yvDaiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();


        // ensure that users position is cleared out
        (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);

        // ensure that ERC20 balances are as expected
        assertEq(stablecoin.balanceOf(address(userProxy)), 0); // ensure no stablecoin has been left on proxy
        assertEq(stablecoin.balanceOf(user), 0); // ensure no stablecoin has been left on user eoa

        // ensure that left over USDC from debt swap is kept on proxy and USDC from collateral swap is sent to user
        assertEq(USDC.balanceOf(user), expectedCollateralOut + debtSwapMaxAmountIn - debtSwapAmountIn);
    }

    // withdraw dai and swap to usdc, then repay dai vault debt by swapping to stablecoin from usdc
    function test_withdrawAndRepay_with_EXACT_OUT_swaps() public {
        uint256 depositAmount = 5_000*1e18;
        uint256 borrowAmount = 2_500*1e18;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(yvDaiVault), depositAmount, borrowAmount);

        uint256 expectedCollateral = _simulateYearnVaultDeposit(yvDAI, depositAmount);
        uint256 expectedWithdrawAmount = _simulateYearnVaultWithdraw(yvDAI, expectedCollateral);

        // spend users stablecoin
        vm.prank(user);
        stablecoin.transfer(address(0x1), borrowAmount);

        // build withdraw and repay params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        uint256 debtSwapMaxAmountIn = borrowAmount * 101 /100e12;
        uint256 collateralSwapOut = expectedWithdrawAmount * 99/100e12;
        uint256 debtSwapAmountIn; // usdc spent swapping debt to stablecoin
        uint256 expectedCollateralIn; // dai spent swapping collateral to usdc
        {
            address[] memory collateralAssets = new address[](2);
            collateralAssets[0] = address(USDC);
            collateralAssets[1] = address(DAI);

            address[] memory debtAssets = new address[](2);
            debtAssets[0] = address(stablecoin);
            debtAssets[1] = address(USDC);

            collateralParams = CollateralParams({
                targetToken: address(USDC),
                amount: expectedCollateral,
                collateralizer: user,
                auxSwap: SwapParams({ // swap DAI for USDC
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(DAI),
                    amount: collateralSwapOut,
                    limit: expectedWithdrawAmount,
                    recipient: address(user), // sent directly to the user
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, collateralAssets)
                })
            });
            creditParams = CreditParams({
                amount: borrowAmount,
                creditor: user,
                auxSwap: SwapParams({ // swap USDC for stablecoin
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: borrowAmount,
                    limit: debtSwapMaxAmountIn,
                    recipient: address(userProxy), // must be sent to proxy
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, debtAssets)
                })
            });
            (debtSwapAmountIn, expectedCollateralIn) = _simulateBalancerSwapMulti(creditParams.auxSwap, collateralParams.auxSwap);
        }

        vm.startPrank(user);
        deal(address(USDC), address(user), debtSwapMaxAmountIn);
        USDC.approve(address(userProxy), debtSwapMaxAmountIn);

        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdrawAndRepay.selector,
                address(userProxy), // user proxy is the position
                address(yvDaiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();


        // ensure that users position is cleared out
        (uint256 collateral, uint256 debt) = yvDaiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);

        // ensure that ERC20 balances are as expected
        assertEq(stablecoin.balanceOf(address(userProxy)), 0); // ensure no stablecoin has been left on proxy
        assertEq(stablecoin.balanceOf(user), 0); // ensure no stablecoin has been left on user eoa

        // ensure that left over USDC from debt swap and amount of from collateral swap is sent to user
        assertEq(USDC.balanceOf(user), collateralSwapOut + debtSwapMaxAmountIn - debtSwapAmountIn);
        assertEq(DAI.balanceOf(user), expectedWithdrawAmount - expectedCollateralIn); // ensure user got left over dai from collateral exact_out swap
    }

    /// @dev helper function simply add collateral to a vault, proxy is the position
    function _deposit(PRBProxy proxy, address vault, uint256 amount) internal returns (uint256 shares) {
        CDPVault cdpVault = CDPVault(vault);
        IYVault yVault = IYVault(address(cdpVault.token()));

        // mint vault token to position
        shares = _yearnVaultDeposit(yVault, amount, address(proxy));

        // build add collateral params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(yVault),
            amount: shares,
            collateralizer: address(proxy),
            auxSwap: emptySwap
        });

        vm.prank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                PositionAction.deposit.selector,
                address(proxy), // user proxy is the position
                vault,
                collateralParams,
                emptyPermitParams
            )
        );
    }

    function _depositAndBorrow(PRBProxy proxy, address vault, uint256 depositAmount, uint256 borrowAmount) internal {
        CDPVault cdpVault = CDPVault(vault);
        IYVault yVault = IYVault(address(cdpVault.token()));

        // mint vault token to position
        uint256 shares = _yearnVaultDeposit(yVault, depositAmount, address(proxy));

        // build add collateral params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(yVault),
            amount: shares,
            collateralizer: address(proxy),
            auxSwap: emptySwap // no entry swap
        });
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: proxy.owner(),
            auxSwap: emptySwap // no exit swap
        });

        vm.startPrank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.depositAndBorrow.selector,
                address(proxy), // user proxy is the position
                vault,
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();
    }

    /// @dev simulate yearn vault deposit to calculate the expected shares out
    function _simulateYearnVaultDeposit(IYVault yVault, uint256 assets) internal returns (uint256 shares) {
        uint256 snapshot = vm.snapshot();
        shares = _yearnVaultDeposit(yVault, assets, address(this));
        vm.revertTo(snapshot);
    }

    /// @dev simulate yearn vault withdrawal to calculate the expected assets out
    function _simulateYearnVaultWithdraw(IYVault yVault, uint256 shares) internal returns (uint256 assets) {
        uint256 snapshot = vm.snapshot();
        assets = yVault.withdraw(shares);
        vm.revertTo(snapshot);
    }

    /// @dev deposit into yearn vault and return shares out
    function _yearnVaultDeposit(IYVault yVault, uint256 assets, address to) internal returns (uint256 shares) {
        address token = yVault.token();

        // mint assetIn to leverActions so we can execute the swap
        deal(token, address(this), assets);

        ERC20(token).safeApprove(address(yVault), assets);
        shares = yVault.deposit(assets);
        if (to != address(this)) yVault.transfer(to, shares);
    }
}
