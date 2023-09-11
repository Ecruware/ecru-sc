// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {Permission} from "../../utils/Permission.sol";
import {toInt256, WAD} from "../../utils/Math.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {BaseAction} from "../../proxy/BaseAction.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PositionAction, CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {PositionAction20} from "../../proxy/PositionAction20.sol";

contract PositionAction20Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault_TypeA daiVault;
    CDPVault_TypeA usdcVault;
    CDPVault_TypeA usdtVault;

    // actions
    PositionAction20 positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    function setUp() public override {
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        usdcVault = createCDPVault_TypeA(
            USDC, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            1.1 ether, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        daiVault = createCDPVault_TypeA(
            DAI, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            1.1 ether, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        usdtVault = createCDPVault_TypeA(
            USDT, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            1.1 ether, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        daiVault.addLimitPriceTick(1 ether, 0);

        // configure oracle spot prices
        oracle.updateSpot(address(DAI), 1 ether);
        oracle.updateSpot(address(USDC), 1 ether);
        oracle.updateSpot(address(USDT), 1 ether);

        // configure vaults
        cdm.setParameter(address(daiVault), "debtCeiling", 5_000_000 ether);
        cdm.setParameter(address(usdcVault), "debtCeiling", 5_000_000 ether);
        cdm.setParameter(address(usdtVault), "debtCeiling", 5_000_000 ether);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // deploy position actions
        positionAction = new PositionAction20(address(flashlender), address(swapAction), address(joinAction));

        // set up variables to avoid stack too deep
        stablePoolIdArray.push(stablePoolId);

        // give minter credit to cover interest
        createCredit(address(minter), 5_000_000 ether);

        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(daiVault), "daiVault");
        vm.label(address(usdcVault), "usdcVault");
        vm.label(address(usdtVault), "usdtVault");
        vm.label(address(positionAction), "positionAction");
    }

    function test_deposit() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(DAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        DAI.approve(address(userProxy), depositAmount);


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_DAI_vault_with_entry_swap_from_USDC() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; // convert 6 decimals to 18 and add 1% slippage

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

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, 0);
    }

    function test_deposit_USDC_vault_with_entry_swap_from_DAI() public {
        uint256 depositAmount = 10_000 ether;
        uint256 amountOutMin = depositAmount * 99 / 100e12; // convert 18 decimals to 6 and add 1% slippage

        deal(address(DAI), user, depositAmount);


        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(DAI);
        assets[1] = address(USDC);

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

        // USDC out converted to DAI decimals
        uint256 expectedCollateral = _simulateBalancerSwap(collateralParams.auxSwap)*1e12;

        vm.prank(user);
        DAI.approve(address(userProxy), depositAmount);


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(usdcVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, 0);
    }

    function test_deposit_from_proxy_collateralizer() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(DAI), address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap
        });


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_to_an_unrelated_position() public {

        // create 2nd position
        address alice = vm.addr(0x45674567);
        PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

        uint256 depositAmount = 10_000 ether;

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
                positionAction.deposit.selector,
                address(aliceProxy),
                address(daiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(aliceProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_EXACT_OUT() public {
        uint256 depositAmount = 10_000 ether;
        //uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; 
        uint256 amountInMax = depositAmount * 101 / 100e12; // convert 6 decimals to 18 and add 1% slippage

        deal(address(USDC), user, amountInMax);

        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(DAI);
        assets[1] = address(USDC);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(USDC),
                amount: depositAmount, // amount to swap in
                limit: amountInMax, // min amount of collateral token to receive
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(collateralParams.auxSwap);

        vm.startPrank(user);
        USDC.approve(address(userProxy), amountInMax);


        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
        assertEq(USDC.balanceOf(user), amountInMax - expectedAmountIn); // assert residual is sent to user
    }

    function test_deposit_InvalidAuxSwap() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; // convert 6 decimals to 18 and add 1% slippage

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

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);

        // trigger PositionAction__deposit_InvalidAuxSwap
        collateralParams.auxSwap.recipient = user;
        vm.expectRevert(PositionAction.PositionAction__deposit_InvalidAuxSwap.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                emptyPermitParams
            )
        );
    }

    function test_withdraw() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(daiVault), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: auxSwap
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);
    }

    function test_withdraw_and_swap() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(daiVault), initialDeposit);

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
                    amount: initialDeposit,
                    limit: initialDeposit/1e12 * 99/100,
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
                address(daiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
        
        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);
        assertEq(USDT.balanceOf(address(user)), expectedAmountOut);
    }

    function test_withdraw_USDT_and_swap_DAI() public {
        // deposit USDT to vault
        uint256 initialDeposit = 1_000 * 1e6;
        _deposit(userProxy, address(usdtVault), initialDeposit);

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
                    amount: initialDeposit,
                    limit: initialDeposit*1e12 * 99/100,
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
                address(usdtVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(DAI.balanceOf(address(user)), expectedAmountOut);
    }

    function test_borrow() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(daiVault), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 500*1 ether;
        deal(address(DAI), user, borrowAmount);

        // build borrow params
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: emptySwap // no entry swap
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
        assertEq(collateral, initialDeposit);
        assertEq(normalDebt, borrowAmount);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);
        assertEq(stablecoin.balanceOf(user), borrowAmount);
    }

    function test_borrow_with_large_rate() public {
        // accure interest
        vm.warp(block.timestamp + 10 * 365 days);

        uint256 depositAmount = 10_000 ether;
        uint256 borrowAmount = 5_000 ether;
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, depositAmount);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, _debtToNormalDebt(address(daiVault), address(userProxy), borrowAmount));

        // assert that debt is minted to the user
        assertEq(stablecoin.balanceOf(user), borrowAmount);
    }

    function test_borrow_and_swap() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(daiVault), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 500*1 ether;
        uint256 minAmountOut = borrowAmount * 99 / 100e12; // convert from stablecoin to usdc decimals
        uint256 expectedAmountOut;
        deal(address(DAI), user, borrowAmount);

        // build borrow params
        CreditParams memory creditParams;
        {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDC);


            // build borrow params
            creditParams = CreditParams({
                amount: borrowAmount,
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
            expectedAmountOut = _simulateBalancerSwap(creditParams.auxSwap);
        }

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
        assertEq(collateral, initialDeposit);
        assertEq(normalDebt, borrowAmount);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(stablecoin.balanceOf(user), 0);
        assertEq(USDC.balanceOf(user), expectedAmountOut);
    }

    function test_borrow_and_swap_EXACT_OUT() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(daiVault), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 500*1 ether/1e12;
        uint256 maxAmountIn = borrowAmount * 101e12/100; // convert from stablecoin to usdc decimals
        uint256 expectedAmountIn;

        // build borrow params
        CreditParams memory creditParams;
        {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(USDC);
            assets[1] = address(stablecoin);


            // build borrow params
            creditParams = CreditParams({
                amount: maxAmountIn,
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(stablecoin),
                    amount: borrowAmount,
                    limit: maxAmountIn,
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                })
            });
            expectedAmountIn = _simulateBalancerSwap(creditParams.auxSwap);
        }

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
        assertEq(collateral, initialDeposit);
        assertEq(normalDebt, maxAmountIn);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(stablecoin.balanceOf(user), maxAmountIn - expectedAmountIn); // ensure left over stablecoin is sent to user
        assertEq(USDC.balanceOf(user), borrowAmount);
    }

    function test_borrow_DAI_vault_with_exit_swap_to_USDC() public {
        uint256 depositAmount = 10_000 ether;
        _deposit(userProxy, address(daiVault), depositAmount);

        uint256 borrowAmount = 5_000 ether; // borrow 5k stablecoin
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
                positionAction.borrow.selector,
                address(userProxy),
                address(daiVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, borrowAmount);

        assertEq(USDC.balanceOf(user), expectedAmountOut);
    }

    function test_borrow_USDC_vault_with_exit_swap_to_DAI() public {
        uint256 depositAmount = 10_000 * 1e6;
        _deposit(userProxy, address(usdcVault), depositAmount);

        uint256 borrowAmount = 5_000 ether; // borrow 5k stablecoin
        uint256 minAmountOut = borrowAmount * 99 / 100;

        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount, // the amount of stablecoin to mint
            creditor: address(0),
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
                positionAction.borrow.selector,
                address(userProxy),
                address(usdcVault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));

        assertEq(collateral, depositAmount*1e12);
        assertEq(normalDebt, borrowAmount);

        assertEq(DAI.balanceOf(user), expectedAmountOut);
    }

    function test_borrow_as_permission_agent() public {
        // create 2nd position
        address alice = vm.addr(0x45674567);
        PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

        // add collateral to 1st position
        uint256 upFrontUnderliers = 10_000 ether;
        _deposit(userProxy, address(daiVault), upFrontUnderliers);

        uint256 borrowAmount = 5_000 ether;

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: alice,
            auxSwap: emptySwap // no exit swap
        });

        // attempt to borrow from the 1st position as the 2nd position, expect revert due to lack of permission
        vm.prank(alice);
        vm.expectRevert(CDPVault.CDPVault__modifyCollateralAndDebt_noPermission.selector);
        aliceProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy),
                address(daiVault),
                creditParams
            )
        );

        // grant alice permission
        vm.startPrank(address(userProxy));
        cdm.setPermissionAgent(address(aliceProxy), true); // allow 2nd position to mint stablecoin using credit
        daiVault.modifyPermission(address(aliceProxy), true); // allow alice to modify this vault
        vm.stopPrank();


        // expect borrow to succeed
        vm.prank(alice);
        aliceProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy),
                address(daiVault),
                creditParams
            )
        );



        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, upFrontUnderliers);
        assertEq(normalDebt, borrowAmount);

        assertEq(stablecoin.balanceOf(alice), borrowAmount);


    }

    function test_borrow_InvalidAuxSwap() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(daiVault), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 500*1 ether;
        uint256 minAmountOut = borrowAmount * 99 / 100e12; // convert from stablecoin to usdc decimals
        uint256 expectedAmountOut;
        deal(address(DAI), user, borrowAmount);

        // build borrow params
        CreditParams memory creditParams;
        {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDC);


            // build borrow params
            creditParams = CreditParams({
                amount: borrowAmount,
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
            expectedAmountOut = _simulateBalancerSwap(creditParams.auxSwap);
        }

        // trigger PositionAction__borrow_InvalidAuxSwap
        creditParams.auxSwap.assetIn = address(USDC);
        vm.expectRevert(PositionAction.PositionAction__borrow_InvalidAuxSwap.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                creditParams
            )
        );
    }

    // REPAY TESTS

    function test_repay() public {
        uint256 depositAmount = 1_000*1 ether; // DAI
        uint256 borrowAmount = 500*1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        stablecoin.approve(address(userProxy), borrowAmount);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.repay.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_repay_with_interest() public {
        uint256 depositAmount = 1_000*1 ether; // DAI
        uint256 borrowAmount = 500*1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

        // accrue interest
        vm.warp(block.timestamp + 365 days);

        uint256 totalDebt = _virtualDebt(daiVault, address(userProxy));
        deal(address(stablecoin), user, totalDebt); // update stablecoin balance to cover normal debt plus accrued interest

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        stablecoin.approve(address(userProxy), totalDebt);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.repay.selector,
                address(userProxy), // user proxy is the position
                address(daiVault),
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(stablecoin.balanceOf(user), 0);

    }

    function test_repay_with_interest_with_swap() public {
        uint256 collateral = 1_000*1 ether; // DAI
        uint256 normalDebt = 500*1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(daiVault), collateral, normalDebt);

        // get rid of the stablecoin that was borrowed
        vm.prank(user);
        stablecoin.transfer(address(0x1), normalDebt);

        // accrue interest
        vm.warp(block.timestamp + 365 days);
        uint256 debt = _virtualDebt(daiVault, address(userProxy));

        // mint usdc to pay back with
        uint256 swapAmount = debt/1e12 * 101/100;
        deal(address(USDC), address(user), swapAmount);

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
                amount: normalDebt,
                creditor: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: debt,
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
               address(daiVault),
               creditParams,
               emptyPermitParams
           )
       );
       vm.stopPrank();

       (uint256 vCollateral, uint256 vNormalDebt) = daiVault.positions(address(userProxy));
       uint256 creditAmount = credit(address(userProxy));

       assertEq(vCollateral, collateral);
       assertEq(vNormalDebt, 0);
       assertEq(creditAmount, 0);
       assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_repay_from_swap() public {
        uint256 depositAmount = 1_000*1 ether; // DAI
        uint256 borrowAmount = 500*1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

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
               address(daiVault),
               creditParams,
               emptyPermitParams
           )
       );
       vm.stopPrank();

       (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
       uint256 creditAmount = credit(address(userProxy));

       assertEq(collateral, depositAmount);
       assertEq(normalDebt, 0);
       assertEq(creditAmount, 0);
       assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_repay_from_swap_EXACT_IN() public {
        uint256 depositAmount = 1_000*1 ether; // DAI
        uint256 borrowAmount = 500*1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

        // mint usdc to pay back with
        uint256 swapAmount = ((borrowAmount/2) * 101)/100e12; // repay half debt, mint extra to ensure our minimum is the exact amount
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
                amount: borrowAmount/2,
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
               address(daiVault),
               creditParams,
               emptyPermitParams
           )
       );
       vm.stopPrank();

       (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
       uint256 creditAmount = credit(address(userProxy));

       assertEq(collateral, depositAmount);
       assertEq(normalDebt, borrowAmount/2);
       assertEq(creditAmount, expectedAmountOut - borrowAmount/2); // ensure that any extra credit is stored as credit for the user
       assertEq(stablecoin.balanceOf(user), 0);
    }

    function test_repay_InvalidAuxSwap() public {
        uint256 depositAmount = 1_000*1 ether; // DAI
        uint256 borrowAmount = 500*1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

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

       vm.prank(user);
       USDC.approve(address(userProxy), swapAmount);

       // trigger PositionAction__repay_InvalidAuxSwap
       creditParams.auxSwap.recipient = user;
       vm.prank(user);
       vm.expectRevert(PositionAction.PositionAction__repay_InvalidAuxSwap.selector);
       userProxy.execute(
           address(positionAction),
           abi.encodeWithSelector(
               positionAction.repay.selector,
               address(userProxy), // user proxy is the position
               address(daiVault),
               creditParams,
               emptyPermitParams
           )
       );
    }

    function test_withdrawAndRepay() public {
        uint256 depositAmount = 5_000*1 ether;
        uint256 borrowAmount = 2_500*1 ether;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

        // build withdraw and repay params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        {
            collateralParams = CollateralParams({
                targetToken: address(DAI),
                amount: depositAmount,
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
                address(daiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();


        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(stablecoin.balanceOf(user), 0);
        assertEq(DAI.balanceOf(user), depositAmount);
    }

    function test_withdrawAndRepay_with_swaps() public {
        uint256 depositAmount = 5_000*1 ether;
        uint256 borrowAmount = 2_500*1 ether;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

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
                amount: depositAmount,
                collateralizer: user,
                auxSwap: SwapParams({ // swap DAI for USDC
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(DAI),
                    amount: depositAmount,
                    limit: depositAmount * 99/100e12,
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
                address(daiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();


        // ensure that users position is cleared out
        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
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

    // withdraw dai and swap to usdc, then repay usdc debt by swapping to stablecoin
    function test_withdrawAndRepay_with_EXACT_OUT_swaps() public {
        uint256 depositAmount = 5_000*1 ether;
        uint256 borrowAmount = 2_500*1 ether;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

        // spend users stablecoin
        vm.prank(user);
        stablecoin.transfer(address(0x1), borrowAmount);

        // build withdraw and repay params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        uint256 debtSwapMaxAmountIn = borrowAmount * 101 /100e12;
        uint256 collateralSwapOut = depositAmount * 99/100e12;
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
                amount: depositAmount,
                collateralizer: user,
                auxSwap: SwapParams({ // swap DAI for USDC
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(DAI),
                    amount: collateralSwapOut,
                    limit: depositAmount,
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
                address(daiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();


        // ensure that users position is cleared out
        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);

        // ensure that ERC20 balances are as expected
        assertEq(stablecoin.balanceOf(address(userProxy)), 0); // ensure no stablecoin has been left on proxy
        assertEq(stablecoin.balanceOf(user), 0); // ensure no stablecoin has been left on user eoa

        // ensure that left over USDC from debt swap and amount of from collateral swap is sent to user
        assertEq(USDC.balanceOf(user), collateralSwapOut + debtSwapMaxAmountIn - debtSwapAmountIn);
        assertEq(DAI.balanceOf(user), depositAmount - expectedCollateralIn); // ensure user got left over dai from collateral exact_out swap
    }

    function test_depositAndBorrow() public {
        uint256 upFrontUnderliers = 10_000*1 ether;
        uint256 borrowAmount = 5_000*1 ether;

        deal(address(DAI), user, upFrontUnderliers);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: upFrontUnderliers,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: emptySwap // no exit swap
        });

        vm.prank(user);
        DAI.approve(address(userProxy), upFrontUnderliers);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.depositAndBorrow.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, upFrontUnderliers);
        assertEq(normalDebt, borrowAmount);

        assertEq(stablecoin.balanceOf(user), borrowAmount);
    }

    // enter a DAI vault with USDC and exit with USDT
    function test_depositAndBorrow_with_entry_and_exit_swaps() public {
        uint256 upFrontUnderliers = 10_000*1e6; // in USDC
        uint256 borrowAmount = 5_000*1 ether; // in stablecoin

        deal(address(USDC), user, upFrontUnderliers);

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
                    amount: upFrontUnderliers,
                    limit: upFrontUnderliers * 1e12 * 98 / 100, // amountOutMin in DAI 
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
                    recipient: user,
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, exitAssets)
                })
            });

            (expectedCollateral, expectedExitAmount) = _simulateBalancerSwapMulti(collateralParams.auxSwap, creditParams.auxSwap);
        }

        vm.prank(user);
        USDC.approve(address(userProxy), upFrontUnderliers);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.depositAndBorrow.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        assertEq(USDT.balanceOf(user), expectedExitAmount);
    }

    // enter a DAI vault with USDC and exit with USDT using EXACT_OUT swaps
    function test_depositAndBorrow_with_EXACT_OUT_entry_and_exit_swaps() public {
        uint256 depositAmount = 10_100*1e6; // in USDC
        uint256 borrowAmount = 5_100*1 ether; // in stablecoin

        deal(address(USDC), user, depositAmount);

        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        uint256 expectedEntryIn;
        uint256 expectedExitIn;
        uint256 expectedCollateral = depositAmount * 99e12 / 100;
        uint256 expectedExit = borrowAmount * 99/100e12;
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
                collateralizer: user,
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: expectedCollateral,
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
                    amount: expectedExit,
                    limit: borrowAmount, // amountInMax in stablecoin
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(exitPoolIds, exitAssets)
                })
            });

            (expectedEntryIn, expectedExitIn) = _simulateBalancerSwapMulti(collateralParams.auxSwap, creditParams.auxSwap);
        }

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.depositAndBorrow.selector,
                address(userProxy),
                address(daiVault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, borrowAmount);

        // validate that the swap amounts are as expected w/ residual amounts being sent to msg.sender
        assertEq(USDT.balanceOf(user), expectedExit);
        assertEq(stablecoin.balanceOf(user), borrowAmount - expectedExitIn);

        // validate resiudal amounts from entry swap
        assertEq(USDC.balanceOf(address(user)), depositAmount - expectedEntryIn);

        // validate that there is no dust
        assertEq(USDT.balanceOf(address(userProxy)), 0);
        assertEq(stablecoin.balanceOf(address(userProxy)), 0);
        assertEq(DAI.balanceOf(address(userProxy)), 0);
    }

    // MULTISEND

    // send a direct call to multisend and expect revert
    function test_multisend_no_direct_call() public {
        address[] memory targets = new address[](1);
        targets[0] = address(DAI);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(DAI.balanceOf.selector, user);

        bool[] memory delegateCall = new bool[](1);
        delegateCall[0] = false;

        vm.expectRevert(PositionAction.PositionAction__onlyDelegatecall.selector);
        positionAction.multisend(targets, data, delegateCall);
    }

    function test_multisend_revert_on_inner_revert() public {
        address[] memory targets = new address[](1);
        targets[0] = address(DAI);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(PositionAction.multisend.selector); // random selector

        bool[] memory delegateCall = new bool[](1);
        delegateCall[0] = false;

        vm.expectRevert(BaseAction.Action__revertBytes_emptyRevertBytes.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.multisend.selector,
                targets,
                data,
                delegateCall
            )
        );
    }

    function test_multisend_simple_delegatecall() public {
        uint256 depositAmount = 1_000 ether;
        uint256 borrowAmount = 500 ether;

        deal(address(DAI), address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap
        });

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(userProxy),
            auxSwap: emptySwap
        });

        address[] memory targets = new address[](2);
        targets[0] = address(positionAction);
        targets[1] = address(daiVault);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            positionAction.depositAndBorrow.selector,
            address(userProxy),
            address(daiVault),
            collateralParams,
            creditParams,
            emptyPermitParams
        );
        data[1] = abi.encodeWithSelector(CDPVault.createLimitOrder.selector, 1 ether);

        bool[] memory delegateCall = new bool[](2);
        delegateCall[0] = true;
        delegateCall[1] = false;

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.multisend.selector,
                targets,
                data,
                delegateCall
            )
        );

        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
        assertEq(collateral, depositAmount);
        assertEq(debt, borrowAmount);
    }

    function test_multisend_deposit_and_limit_order() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(DAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        DAI.approve(address(userProxy), depositAmount);

        address[] memory targets = new address[](3);
        targets[0] = address(positionAction);
        targets[1] = address(daiVault);
        targets[2] = address(daiVault);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(positionAction.deposit.selector, address(userProxy), daiVault, collateralParams, emptyPermitParams);
        data[1] = abi.encodeWithSelector(
            daiVault.modifyCollateralAndDebt.selector,
            address(userProxy),
            address(userProxy),
            address(userProxy),
            0,
            toInt256(100 ether)
        );
        data[2] = abi.encodeWithSelector(CDPVault.createLimitOrder.selector, 1 ether);

        bool[] memory delegateCall = new bool[](3);
        delegateCall[0] = true;
        delegateCall[1] = false;
        delegateCall[2] = false;

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.multisend.selector,
                targets,
                data,
                delegateCall
            )
        );

        uint256 expectedOrderId = uint256(uint160(address(userProxy)));
        // expect new limit order to be both the head and tail because it is the only order
        assertEq(daiVault.getLimitOrder(1 ether, 0), expectedOrderId);

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 100 ether);
    }

    function test_multisend_exchange_limit_order() public {

        // create 1st position
        uint256 aliceDeposit = 10_000 ether;
        address alice = vm.addr(0x45674567);
        PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));
        deal(address(DAI), address(alice), aliceDeposit);

        // execute 2 actions as 1st position, 1. deposit collateral and borrow 2. create limit order on position
        {
            CollateralParams memory collateralParams = CollateralParams({
                targetToken: address(DAI),
                amount: aliceDeposit,
                collateralizer: address(alice),
                auxSwap: emptySwap
            });

            CreditParams memory creditParams = CreditParams({
                amount: aliceDeposit/2,
                creditor: address(alice),
                auxSwap: emptySwap
            });

            address[] memory targets = new address[](2);
            targets[0] = address(positionAction);
            targets[1] = address(daiVault);

            bytes[] memory data = new bytes[](2);
            data[0] = abi.encodeWithSelector(positionAction.depositAndBorrow.selector, address(aliceProxy), daiVault, collateralParams, creditParams, emptyPermitParams);
            data[1] = abi.encodeWithSelector(daiVault.createLimitOrder.selector, 1 ether);

            bool[] memory delegateCall = new bool[](2);
            delegateCall[0] = true;
            delegateCall[1] = false;

            vm.prank(alice);
            DAI.approve(address(aliceProxy), aliceDeposit);

            vm.prank(alice);
            aliceProxy.execute(
                address(positionAction),
                abi.encodeWithSelector(
                    positionAction.multisend.selector,
                    targets,
                    data,
                    delegateCall
                )
            );
        }

        // create 2nd position and execute 1st position's limit order in one multisend
        uint256 userDeposit = aliceDeposit*2;
        deal(address(DAI), user, userDeposit);

        {
            CollateralParams memory collateralParams = CollateralParams({
                targetToken: address(DAI),
                amount: userDeposit,
                collateralizer: address(user),
                auxSwap: emptySwap
            });

            address[] memory targets = new address[](5);
            targets[0] = address(positionAction);
            targets[1] = address(cdm);
            targets[2] = address(daiVault);
            targets[3] = address(daiVault);
            targets[4] = address(cdm);

            bytes[] memory data = new bytes[](5);
            data[0] = abi.encodeWithSelector(positionAction.deposit.selector, address(userProxy), daiVault, collateralParams, emptyPermitParams);
            data[1] = abi.encodeWithSelector(bytes4(keccak256("modifyPermission(address,bool)")), address(daiVault), true);
            data[2] = abi.encodeWithSelector(
                daiVault.modifyCollateralAndDebt.selector,
                address(userProxy),
                address(userProxy),
                address(userProxy),
                0,
                toInt256(userDeposit/2)
            );
            data[3] = abi.encodeWithSelector(daiVault.exchange.selector, 1 ether, userDeposit/4);
            data[4] = abi.encodeWithSelector(bytes4(keccak256("modifyPermission(address,bool)")), address(daiVault), false);

            bool[] memory delegateCall = new bool[](5);
            delegateCall[0] = true;
            delegateCall[1] = false;
            delegateCall[2] = false;
            delegateCall[3] = false;
            delegateCall[4] = false;

            vm.prank(user);
            DAI.approve(address(userProxy), userDeposit);

            vm.prank(user);
            userProxy.execute(
                address(positionAction),
                abi.encodeWithSelector(
                    positionAction.multisend.selector,
                    targets,
                    data,
                    delegateCall
                )
            );
        }

        (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
        uint256 cash = daiVault.cash(address(userProxy));
        uint256 userCredit = credit(address(userProxy));

        (uint256 aliceCollateral, uint256 aliceDebt) = daiVault.positions(address(aliceProxy));
        uint256 aliceCash = daiVault.cash(address(aliceProxy));
        uint256 aliceCredit = credit(address(aliceProxy));

        // assert 2nd position received 1st positions collateral as cash
        assertEq(collateral, userDeposit);
        assertEq(debt, userDeposit/2); // original debt taken out to generate credit
        assertEq(cash, userDeposit/4); // user received half of alice's collateral as cash
        assertEq(userCredit, userDeposit/4); // user spent half of their credit to execute limit order

        // assert 1st positions limit order was executed correctly
        assertEq(aliceCollateral, aliceDeposit/2); // alice lost half of her collateral
        assertEq(aliceDebt, 0); // alice lost all debt
        assertEq(aliceCredit, 0);
        assertEq(aliceCash, 0);
    }

    // HELPER FUNCTIONS

    function _deposit(PRBProxy proxy, address vault, uint256 amount) internal {
        CDPVault_TypeA cdpVault = CDPVault_TypeA(vault);
        address token = address(cdpVault.token());

        // mint vault token to position
        deal(token, address(proxy), amount);

        // build collateral params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: token,
            amount: amount,
            collateralizer: address(proxy),
            auxSwap: emptySwap
        });

        vm.prank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy), // user proxy is the position
                vault,
                collateralParams,
                emptyPermitParams
            )
        );
    }

    function _borrow(PRBProxy proxy, address vault, uint256 borrowAmount) internal {
        // build borrow params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(proxy),
            auxSwap: auxSwap // no entry swap
        });

        vm.prank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(proxy), // user proxy is the position
                vault,
                creditParams
            )
        );
    }

    function _depositAndBorrow(PRBProxy proxy, address vault, uint256 depositAmount, uint256 borrowAmount) internal {
        CDPVault cdpVault = CDPVault(vault);
        address token = address(cdpVault.token());

        // mint vault token to position
        deal(token, address(proxy), depositAmount);

        // build add collateral params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: token,
            amount: depositAmount,
            collateralizer: address(proxy),
            auxSwap: auxSwap // no entry swap
        });
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: proxy.owner(),
            auxSwap: auxSwap // no exit swap
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
}
