// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";
import {wdiv, WAD} from "../../utils/Math.sol";
import {Permission} from "../../utils/Permission.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {JoinAction, JoinParams} from "../../proxy/JoinAction.sol";
import {LeverParams, PositionAction} from "../../proxy/PositionAction.sol";

import {PositionAction20} from "../../proxy/PositionAction20.sol";

contract PositionAction20_Lever_Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // vaults
    CDPVault_TypeA usdtVault;
    CDPVault_TypeA usdcVault;
    CDPVault_TypeA daiVault;

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
        usdtVault = createCDPVault_TypeA(
            USDT, // token
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
        usdcVault = createCDPVault_TypeA(
            USDC, // token
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
        daiVault = createCDPVault_TypeA(
            DAI, // token
            5_000_000 ether, // debt ceiling
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

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // deploy actions
        positionAction = new PositionAction20(address(flashlender), address(swapAction), address(joinAction));

        // configure oracle spot prices
        oracle.updateSpot(address(DAI), 1 ether);
        oracle.updateSpot(address(USDC), 1 ether);
        oracle.updateSpot(address(USDT), 1 ether);

        // configure vaults
        cdm.setParameter(address(daiVault), "debtCeiling", 5_000_000 ether);
        cdm.setParameter(address(usdcVault), "debtCeiling", 5_000_000 ether);
        cdm.setParameter(address(usdtVault), "debtCeiling", 5_000_000 ether);

        // setup state variables to avoid stack too deep
        stablePoolIdArray.push(stablePoolId);

        vm.label(address(userProxy), "UserProxy");
        vm.label(address(user), "User");
        vm.label(address(daiVault), "DAIVault");
        vm.label(address(usdcVault), "USDCVault");
        vm.label(address(positionAction), "PositionAction");
    }

    function test_increaseLever() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 ether;

        deal(address(DAI), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(daiVault),
            collateralToken: address(DAI),
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
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        vm.prank(user);
        DAI.approve(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedAmountOut + upFrontUnderliers);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_increaseLever_with_large_rate() public {
        vm.warp(block.timestamp + 10 * 365 days);
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 40_000 ether;

        uint256 swapAmountOut = _increaseLever(
            userProxy, // position
            daiVault, // vault
            upFrontUnderliers,
            borrowAmount,
            39_000 ether // amountOutMin
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, swapAmountOut + upFrontUnderliers);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, _debtToNormalDebt(address(daiVault), address(userProxy), borrowAmount));

        assertEq(_normalDebtToDebt(address(daiVault), address(userProxy), normalDebt), borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

    }

    function test_increaseLever_USDC() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 * 1e6;

        deal(address(USDC), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDC);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(usdcVault),
            collateralToken: address(USDC),
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
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        vm.prank(user);
        USDC.approve(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of USDC received from the swap
        assertEq(collateral, wdiv(expectedAmountOut + upFrontUnderliers, usdcVault.tokenScale()));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);
    }

    function test_increaseLever_USDT() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 * 1e6;

        deal(address(USDT), user, upFrontUnderliers);

        // build increase lever params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDT);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(usdtVault),
            collateralToken: address(USDT),
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
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        // no transfer

        vm.startPrank(user);
        USDT.safeApprove(address(userProxy), upFrontUnderliers);
        vm.stopPrank();

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(USDT),
                upFrontUnderliers,
                user,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdtVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of USDC received from the swap
        assertEq(collateral, wdiv(expectedAmountOut + upFrontUnderliers, usdtVault.tokenScale()));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);
    }

    function test_increaseLever_zero_upfront() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            daiVault,
            20_000 ether, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 ether // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(userProxy));

        // now lever up further without passing any upFrontUnderliers
        uint256 borrowAmount = 5_000 ether; // amount to lever up
        uint256 amountOutMin = 4_950 ether; // min amount of DAI to receive

        // build increase lever params
        LeverParams memory leverParams;
        {
            SwapParams memory auxSwap;
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: borrowAmount, // amount of stablecoin to swap in
                    limit: amountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                }),
                auxSwap: auxSwap, 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
        }

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        PermitParams memory permitParams;

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(0),
                0, // zero up front collateral
                address(0), // collateralizer
                permitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert that collateral is now equal to the initial collateral + the amount of DAI received from the swap
        assertEq(collateral, initialCollateral + expectedAmountOut);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, initialNormalDebt + borrowAmount);
    }

    function test_increaseLever_with_proxy_collateralizer() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 ether;

        // put the tokens directly on the proxy
        deal(address(DAI), address(userProxy), upFrontUnderliers);

        // build increase lever params
        LeverParams memory leverParams;
        {

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
        }

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        // call transferAndIncreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(DAI),
                upFrontUnderliers,
                address(userProxy),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // verify the collateral amount is the same as the upFrontUnderliers + amount of DAI returned from swap
        assertEq(collateral, expectedAmountOut + upFrontUnderliers);

        // assert normalDebt is the same as borrowAmount
        assertEq(normalDebt, borrowAmount);
    }

    function test_increaseLever_with_different_EOA_collateralizer() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 70_000 ether;
        uint256 amountOutMin = 69_000 ether;

        // this is the EOA collateralizer that is not related to the position
        address alice = vm.addr(0x56785678);
        vm.label(alice, "alice");

        deal(address(DAI), address(alice), upFrontUnderliers);

        // approve the userProxy to spend the collateral token from alice
        vm.startPrank(alice);
        DAI.approve(address(userProxy), type(uint256).max);
        vm.stopPrank();

        // build increase lever params
        LeverParams memory leverParams;
        {
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
        }

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        // call transferAndIncreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(DAI),
                upFrontUnderliers,
                alice,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // verify the collateral amount is the same as the upFrontUnderliers + amount of DAI returned from swap
        assertEq(collateral, expectedAmountOut + upFrontUnderliers);

        // assert normalDebt is the same as borrowAmount
        assertEq(normalDebt, borrowAmount);
    }

    function test_increaseLever_with_permission_agent() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 40_000 ether;
        uint256 amountOutMin = 39_000 ether;

        // create 1st position. This is the user(bob) that will lever up the other users (alice) position
        address bob = user;
        PRBProxy bobProxy = userProxy;

        // create 2nd position. This is the user that will be levered up by bob
        address alice = vm.addr(0x56785678);
        PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

        vm.label(alice, "alice");
        vm.label(address(aliceProxy), "aliceProxy");

        // alice creates an initial position
        _increaseLever(aliceProxy, daiVault, upFrontUnderliers, borrowAmount, amountOutMin);

        // build increaseLever Params
        LeverParams memory leverParams;
        {
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(aliceProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                auxJoin: emptyJoin,
auxJoinToken: address(0)
            });
        }

        deal(address(DAI), bob, upFrontUnderliers);

        vm.prank(bob);
        DAI.approve(address(bobProxy), upFrontUnderliers);

        // call increaseLever on alice's position as bob but expect failure because bob does not have permission
        vm.prank(bob);
        vm.expectRevert(Permission.Permission__modifyPermission_notPermitted.selector);
        bobProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(DAI),
                upFrontUnderliers,
                bob,
                emptyPermitParams
            )
        );

        // call setPermissionAgent as alice to allow bob to modify alice's position
        vm.prank(address(aliceProxy));
        daiVault.setPermissionAgent(address(bobProxy), true);

        // call increaseLever on alice's position as bob and now expect success
        vm.prank(bob);
        bobProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(DAI),
                upFrontUnderliers,
                bob,
                emptyPermitParams
            )
        );

        // assert alice's position is levered up once by her and a 2nd time by bob
        (uint256 aliceCollateral, uint256 aliceNormalDebt) = daiVault.positions(address(aliceProxy));
        assertGe(aliceCollateral, amountOutMin * 2 + upFrontUnderliers * 2);
        assertEq(aliceNormalDebt, borrowAmount * 2);

        // assert bob's position is unaffected
        (uint256 bobCollateral, uint256 bobNormalDebt) = daiVault.positions(address(bobProxy));
        assertEq(bobCollateral, 0);
        assertEq(bobNormalDebt, 0);
    }

    function test_decreaseLever() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            daiVault,
            20_000 ether, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 ether // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(userProxy));

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(daiVault),
            collateralToken: address(DAI),
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
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                maxAmountIn, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - maxAmountIn);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy
        assertEq(maxAmountIn - expectedAmountIn, DAI.balanceOf(address(userProxy)));

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_decreaseLever_with_interest() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            daiVault,
            20_000 ether, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 ether // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(userProxy));

        // accrue interest
        vm.warp(block.timestamp + 365 days);

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(daiVault),
            collateralToken: address(DAI),
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
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                maxAmountIn, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - maxAmountIn);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - _debtToNormalDebt(address(daiVault), address(userProxy), amountOut));

        // assert that the left over was transfered to the user proxy
        assertEq(maxAmountIn - expectedAmountIn, DAI.balanceOf(address(userProxy)));

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0); 
    }

    function test_decreaseLever_USDC() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            usdcVault,
            20_000 * 1e6, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 * 1e6 // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = usdcVault.positions(address(userProxy));

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 * 1e6;
        uint256 tokenScale = usdcVault.tokenScale();

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDC);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(usdcVault),
            collateralToken: address(USDC),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(USDC),
                amount: amountOut, // exact amount of stablecoin to receive
                limit: maxAmountIn, // max amount of USDC to pay
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                wdiv(maxAmountIn, tokenScale), // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - wdiv(maxAmountIn, tokenScale));

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy
        assertEq(maxAmountIn - expectedAmountIn, USDC.balanceOf(address(userProxy)));
    }

    function test_decreaseLever_USDT() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            usdtVault, // vault
            20_000 * 1e6, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 * 1e6 // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = usdtVault.positions(address(userProxy));

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 * 1e6;
        uint256 tokenScale = usdtVault.tokenScale();

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(USDT);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(usdtVault),
            collateralToken: address(USDT),
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
            auxJoin: emptyJoin,
            auxJoinToken: address(0)
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        // call decreaseLever
        vm.startPrank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                wdiv(maxAmountIn, tokenScale), // collateral to decrease by
                address(userProxy) // residualRecipient, zero address == flash loan initiator == userProxy
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = usdtVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - wdiv(maxAmountIn, tokenScale));

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy
        assertEq(maxAmountIn - expectedAmountIn, USDT.balanceOf(address(userProxy)));
    }

    function test_decreaseLever_with_residual_recipient() public {
        address residualRecipient = address(0x56785678);

        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            daiVault,
            20_000 ether, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 ether // amountOutMin
        );

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(daiVault),
            collateralToken: address(DAI),
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
            auxJoin: emptyJoin,
auxJoinToken: address(0)
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                maxAmountIn, // collateral to decrease by
                residualRecipient
            )
        );

        // assert that the left over was transfered to the residualRecipient
        assertEq(maxAmountIn - expectedAmountIn, DAI.balanceOf(address(residualRecipient)));
    }

    function test_decreaseLever_with_permission_agent() public {
        // create 1st position (this is the user that will lever up the other users position)
        address bob = user;
        PRBProxy bobProxy = userProxy;

        // create 2nd position. This is the user that will be levered up by bob
        address alice = vm.addr(0x56785678);
        PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

        // create alice's initial position
        _increaseLever(
            aliceProxy,
            daiVault,
            20_000 ether, // upFrontUnderliers
            40_000 ether, // borrowAmount
            39_000 ether // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(aliceProxy));

        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;
        LeverParams memory leverParams;
        {
            // now decrease alice's leverage as bob
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);


            leverParams = LeverParams({
                position: address(aliceProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
        }

        // call decreaseLever on alice's position as bob and expect failure because alice did not give bob permission
        vm.prank(bob);
        vm.expectRevert(Permission.Permission__modifyPermission_notPermitted.selector);
        bobProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(positionAction.decreaseLever.selector, leverParams, maxAmountIn, address(bob))
        );

        // call setPermissionAgent as alice to allow bob to modify alice's position
        vm.prank(address(aliceProxy));
        daiVault.setPermissionAgent(address(bobProxy), true);

        // now call decreaseLever on alice's position as bob and expect success because alice gave bob permission
        vm.prank(bob);
        bobProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(positionAction.decreaseLever.selector, leverParams, maxAmountIn, address(bob))
        );

        (uint256 aliceCollateral, uint256 aliceNormalDebt) = daiVault.positions(address(aliceProxy));
        (uint256 bobCollateral, uint256 bobNormalDebt) = daiVault.positions(address(bobProxy));

        // assert alice's position is levered down by bob
        assertEq(aliceCollateral, initialCollateral - maxAmountIn);
        assertEq(aliceNormalDebt, initialNormalDebt - amountOut);

        // assert bob's position is unaffected
        assertEq(bobCollateral, 0);
        assertEq(bobNormalDebt, 0);
    }

    // lever up DAI position by entering with WETH
    function test_increaseLever_DAI_vault_with_aux_swap_from_WETH() public {
        uint256 upFrontUnderliers = 5 ether;
        uint256 auxAmountOutMin =  _getWethRateInDai() * upFrontUnderliers / 1 ether * 99 /100;
        uint256 borrowAmount = auxAmountOutMin; // we want the amount of stablecoin we borrow to be equal to the amount of underliers we swap in
        uint256 amountOutMin = borrowAmount * 98 / 100;

        uint256 expectedAmountOut; // amount out after swaping stablecoin for collateral token
        uint256 auxExpectedAmoutOut; // amount out after swaping upFrontUnderliers for collateral token

        LeverParams memory leverParams;

        {
            deal(address(WETH), user, upFrontUnderliers);

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
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                    limit: auxAmountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(auxPoolIds, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });

            expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

            auxExpectedAmoutOut = _simulateBalancerSwap(leverParams.auxSwap);
        }

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

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, expectedAmountOut + auxExpectedAmoutOut);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        
        // and no tokens were left on the contract
        assertEq(DAI.balanceOf(address(positionAction)),  0);
        assertEq(WETH.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // completely delever and exit DAI position and receieve WETH on exit
    function test_decreaseLever_DAI_vault_with_aux_swap_to_WETH() public {
        uint256 upFrontUnderliers = 10_000*1 ether;
        _increaseLever(
            userProxy,
            daiVault,
            upFrontUnderliers,
            10_000 ether, // borrowAmount
            10_000 ether * 99/100 // amountOutMin
        );

        // we will completely delever the position so use full collateral and debt amounts
        uint256 collateralAmount;
        uint256 amountOut;
        uint256 maxAmountIn;
        {
            (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(userProxy));
            collateralAmount = initialCollateral; // delever the entire collateral amount
            amountOut = initialNormalDebt; // delever the entire debt amount
            maxAmountIn = initialNormalDebt * 101/100; // allow 1% slippage on primary swap
        }
        
        // build decrease lever params
        LeverParams memory leverParams;
        uint256 expectedAmountIn;
        uint256 expectedAuxAmoutOut;
        uint256 minResidualRate = _getDaiRateInWeth() * 99/100; // allow 1% slippage on aux swap

        {

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            bytes32[] memory auxPoolIds = new bytes32[](2);
            auxPoolIds[0] = daiOhmPoolId;
            auxPoolIds[1] = wethOhmPoolId;

            address[] memory auxAssets = new address[](3);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(OHM);  // TODO why is this needed?
            auxAssets[2] = address(WETH);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                    amount: 0, // this will be autocalculated
                    limit: 0, // this will be calculated by the `minResidualRate` variable
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(auxPoolIds, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // simulate the primary swap
            expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

            // simulate the aux swap by setting the amount and limit
            leverParams.auxSwap.amount = collateralAmount - expectedAmountIn;
            leverParams.auxSwap.limit = minResidualRate * leverParams.auxSwap.amount / 1 ether;
            expectedAuxAmoutOut = _simulateBalancerSwap(leverParams.auxSwap);
        }

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                user // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // this should be equal to zero since we are completely delevering
        assertEq(collateral, 0);

        // this should be equal to zero since we are completely delevering
        assertEq(normalDebt, 0);

        // assert that the left over collateral was transfered to the user proxy
        assertEq(expectedAuxAmoutOut, WETH.balanceOf(address(user)));
        
        
        // assert that the amount of WETH we got back is relatively equal to the amount of DAI we put in
        assertApproxEqRel(
            WETH.balanceOf(address(user)),
            upFrontUnderliers * minResidualRate / 1 ether,
            2e16 // allow for a 2% difference due to swap losses
        );

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // and no tokens were left on the contract
        assertEq(DAI.balanceOf(address(positionAction)),  0);
        assertEq(WETH.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // lever up DAI position by entering with USDC
    function test_increaseLever_DAI_vault_with_aux_swap_from_USDC() public {
        uint256 upFrontUnderliers = 20_000*1e6;
        uint256 auxAmountOutMin = upFrontUnderliers * 1e12 * 99 / 100; // allow 1% slippage on aux swap and convert to dai decimals
        uint256 borrowAmount = auxAmountOutMin; // we want the amount of stablecoin we borrow to be equal to the amount of underliers we receieve in aux swap
        uint256 amountOutMin = borrowAmount * 99 / 100;

        uint256 expectedAmountOut; // amount out after swaping stablecoin for collateral token
        uint256 auxExpectedAmountOut; // amount out after swaping upFrontUnderliers for collateral token

        LeverParams memory leverParams;

        {   
            // mint USDC to user
            deal(address(USDC), user, upFrontUnderliers);

            // build increase lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDC);
            auxAssets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                    amount: upFrontUnderliers, // amount of USDC to swap in
                    limit: auxAmountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // get expected return amounts
            (auxExpectedAmountOut, expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);
        }

        vm.prank(user);
        USDC.approve(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the primary swap and aux swap
        assertEq(collateral, expectedAmountOut + auxExpectedAmountOut);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        
        // and no tokens were left on the contract
        assertEq(DAI.balanceOf(address(positionAction)),  0);
        assertEq(USDC.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // completely delever and exit DAI position and receive USDC on exit
    function test_decreaseLever_DAI_vault_with_aux_swap_to_USDC() public {
        uint256 upFrontUnderliers = 20_000*1 ether;
        _increaseLever(
            userProxy,
            daiVault,
            upFrontUnderliers,
            40_000 ether, // borrowAmount
            40_000 ether * 99/100 // amountOutMin
        );

        // we will completely delever the position so use full collateral and debt amounts
        uint256 collateralAmount;
        uint256 amountOut;
        uint256 maxAmountIn;
        {
            (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(userProxy));
            collateralAmount = initialCollateral; // delever the entire collateral amount
            amountOut = initialNormalDebt; // delever the entire debt amount
            maxAmountIn = initialNormalDebt * 101/100; // allow 1% slippage on primary swap
        }
        
        // build decrease lever params
        LeverParams memory leverParams;
        uint256 expectedAmountIn;
        uint256 expectedAuxAmoutOut;
        uint256 minResidualRate = 1e6 * 99/100; // allow 1% slippage on aux swap, rate should be in out token decimals

        {

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(USDC);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                    amount: 0, // this will be autocalculated
                    limit: 0, // this will be calculated by the `minResidualRate` variable
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // first simulate the primary swap to calculate values for aux swap
            expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
            leverParams.auxSwap.amount = collateralAmount - expectedAmountIn;
            leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 1 ether;

            // now simulate both swaps
            (expectedAmountIn, expectedAuxAmoutOut) = _simulateBalancerSwapMulti(leverParams.primarySwap, leverParams.auxSwap);
        }

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                user // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

        // this should be equal to zero since we are completely delevering
        assertEq(collateral, 0);

        // this should be equal to zero since we are completely delevering
        assertEq(normalDebt, 0);

        // assert that the left over collateral was transfered to the user proxy
        assertEq(expectedAuxAmoutOut, USDC.balanceOf(address(user)));
        
        
        // assert that the amount of USDC we got back is relatively equal to the amount of DAI we put in
        assertApproxEqRel(
            USDC.balanceOf(address(user)),
            upFrontUnderliers * minResidualRate / 1 ether,
            1e16 // allow for a 1% difference due to swap losses
        );

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = daiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // and no tokens were left on the contract
        assertEq(DAI.balanceOf(address(positionAction)),  0);
        assertEq(USDC.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // lever up USDT position by entering with DAI
    function test_increaseLever_USDT_vault_with_aux_swap_from_DAI() public {
        uint256 upFrontUnderliers = 20_000*1 ether; // DAI decimals
        uint256 auxAmountOutMin = upFrontUnderliers * 99 / 100e12; // allow 1% slippage on aux swap and convert to usdt decimals
        uint256 borrowAmount = auxAmountOutMin * 1e12; // borrow the same amount of stablecoin as the aux swap returns in USDT (so we are levering up 2x)
        uint256 amountOutMin = borrowAmount * 99 / 100e12; // allow 1% slippage on primary swap and convert to usdt decimals

        uint256 expectedAmountOut; // amount out after swaping stablecoin for collateral token
        uint256 auxExpectedAmountOut; // amount out after swaping upFrontUnderliers for collateral token

        LeverParams memory leverParams;

        {   
            deal(address(DAI), user, upFrontUnderliers);

            // build increase lever params

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDT);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(USDT);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(usdtVault),
                collateralToken: address(USDT),
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
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(DAI),
                    amount: upFrontUnderliers, // amount of DAI to swap in
                    limit: auxAmountOutMin, // min amount of USDT to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // get expected return amounts
            (auxExpectedAmountOut, expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);
        }

        vm.prank(user);
        DAI.approve(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = usdtVault.positions(address(userProxy));

        // assert that collateral is now equal to the amount of USDT received from the primary swap and aux swap
        assertEq(collateral, (expectedAmountOut + auxExpectedAmountOut)*1e12);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = usdtVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        
        // and no tokens were left on the contract
        assertEq(DAI.balanceOf(address(positionAction)),  0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // completely delever and exit USDT position and receive DAI on exit
    function test_decreaseLever_USDT_vault_with_aux_swap_to_DAI() public {
        uint256 upFrontUnderliers = 20_000*1e6;
        _increaseLever(
            userProxy,
            usdtVault,
            upFrontUnderliers,
            40_000 ether, // borrowAmount
            40_000 * 1e6 * 99/100 // amountOutMin
        );

        // we will completely delever the position so use full collateral and debt amounts
        uint256 collateralAmount;
        uint256 amountOut;
        uint256 maxAmountIn;
        {
            (uint256 initialCollateral, uint256 initialNormalDebt) = usdtVault.positions(address(userProxy));
            collateralAmount = initialCollateral; // delever the entire collateral amount
            amountOut = initialNormalDebt; // delever the entire debt amount
            maxAmountIn = initialNormalDebt * 101/100; // allow 1% slippage on primary swap
        }
        
        // build decrease lever params
        LeverParams memory leverParams;
        uint256 expectedAmountIn;
        uint256 expectedAuxAmoutOut;
        uint256 minResidualRate = 1 ether * 99/100; // allow 1% slippage on aux swap, rate should be in out token decimals

        {
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDT);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDT);
            auxAssets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(usdtVault),
                collateralToken: address(USDT),
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
                    amount: 0, // this will be autocalculated
                    limit: 0, // this will be calculated by the `minResidualRate` variable
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // first simulate the primary swap to calculate values for aux swap
            expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
            leverParams.auxSwap.amount = collateralAmount/1e12 - expectedAmountIn;
            leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 1 ether;

            // now simulate both swaps
            (expectedAmountIn, expectedAuxAmoutOut) = _simulateBalancerSwapMulti(leverParams.primarySwap, leverParams.auxSwap);
        }

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                user // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdtVault.positions(address(userProxy));

        // this should be equal to zero since we are completely delevering
        assertEq(collateral, 0);

        // this should be equal to zero since we are completely delevering
        assertEq(normalDebt, 0);

        // assert that the left over collateral was transfered to the user proxy
        assertEq(expectedAuxAmoutOut, DAI.balanceOf(address(user)));
        
        
        // assert that the amount of DAI we got back is relatively equal to the amount of USDT we put in
        assertApproxEqRel(
            DAI.balanceOf(address(user)),
            upFrontUnderliers * minResidualRate / 1e6, // convert to dai decimals
            1e16 // allow for a 3% difference due to swap losses
        );

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = usdtVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // and no tokens were left on the contract
        assertEq(DAI.balanceOf(address(positionAction)),  0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // lever up USDC position by entering with USDT
    function test_increaseLever_USDC_vault_with_aux_swap_to_USDT() public {
        uint256 upFrontUnderliers = 20_000*1e6; // USDT decimals
        uint256 auxAmountOutMin = upFrontUnderliers * 99/100; // allow 1% slippage on aux swap
        uint256 borrowAmount = auxAmountOutMin * 1e12; // borrow the same amount of stablecoin as the aux swap returns in USDT (so we are levering up 2x)
        uint256 amountOutMin = borrowAmount * 99 / 100e12; // allow 1% slippage on primary swap and convert to usdt decimals

        uint256 expectedAmountOut; // amount out after swaping stablecoin for collateral token
        uint256 auxExpectedAmountOut; // amount out after swaping upFrontUnderliers for collateral token

        LeverParams memory leverParams;
        {
            deal(address(USDT), user, upFrontUnderliers);

            // build increase lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDC);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDT);
            auxAssets[1] = address(USDC);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(usdcVault),
                collateralToken: address(USDC),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(stablecoin),
                    amount: borrowAmount, // amount of stablecoin to swap in
                    limit: amountOutMin, // min amount of USDC to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDT),
                    amount: upFrontUnderliers, // amount of USDT to swap in
                    limit: auxAmountOutMin, // min amount of USDC to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // get expected return amounts
            (auxExpectedAmountOut, expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);
        }

        vm.prank(user);
        USDT.forceApprove(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));

        // assert that collateral is now equal to the amount of USDC received from the primary swap and aux swap
        assertEq(collateral, (expectedAmountOut + auxExpectedAmountOut)*1e12);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = usdcVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
        
        // and no tokens were left on the contract
        assertEq(USDC.balanceOf(address(positionAction)),  0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // completely delever and exit USDC position and receive USDT on exit
    function test_decreaseLever_USDC_vault_with_aux_swap_to_USDT() public {
        uint256 upFrontUnderliers = 20_000*1e6;
        _increaseLever(
            userProxy,
            usdcVault,
            upFrontUnderliers,
            40_000 ether, // borrowAmount
            40_000 * 1e6 * 99/100 // amountOutMin
        );

        // we will completely delever the position so use full collateral and debt amounts
        uint256 collateralAmount;
        uint256 amountOut;
        uint256 maxAmountIn;
        {
            (uint256 initialCollateral, uint256 initialNormalDebt) = usdcVault.positions(address(userProxy));
            collateralAmount = initialCollateral; // delever the entire collateral amount
            amountOut = initialNormalDebt; // delever the entire debt amount
            maxAmountIn = initialNormalDebt * 101/100; // allow 1% slippage on primary swap
        }
        
        // build decrease lever params
        LeverParams memory leverParams;
        uint256 expectedAmountIn;
        uint256 expectedAuxAmoutOut;
        uint256 minResidualRate = 1e6 * 99/100; // allow 1% slippage on aux swap, rate should be in out token decimals

        {
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(USDC);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDC);
            auxAssets[1] = address(USDT);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(usdcVault),
                collateralToken: address(USDC),
                primarySwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_OUT,
                    assetIn: address(USDC),
                    amount: amountOut, // exact amount of stablecoin to receive
                    limit: maxAmountIn, // max amount of USDC to pay
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, assets)
                }),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(USDC),
                    amount: 0, // this will be autocalculated
                    limit: 0, // this will be calculated by the `minResidualRate` variable
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // first simulate the primary swap to calculate values for aux swap
            expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
            leverParams.auxSwap.amount = collateralAmount/1e12 - expectedAmountIn;
            leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 1e6;

            // now simulate both swaps
            (expectedAmountIn, expectedAuxAmoutOut) = _simulateBalancerSwapMulti(leverParams.primarySwap, leverParams.auxSwap);
        }

        // call decreaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                user // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt) = usdcVault.positions(address(userProxy));

        // this should be equal to zero since we are completely delevering
        assertEq(collateral, 0);

        // this should be equal to zero since we are completely delevering
        assertEq(normalDebt, 0);

        // assert that the left over collateral was transfered to the user proxy
        assertEq(expectedAuxAmoutOut, USDT.balanceOf(address(user)));
        
        
        // assert that the amount of USDT we got back is relatively equal to the amount of DAI we put in
        assertApproxEqRel(
            USDT.balanceOf(address(user)),
            upFrontUnderliers * minResidualRate / 1e6, // convert to usdt decimals
            1e16 // allow for a 1% difference due to swap losses
        );

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = usdcVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // and no tokens were left on the contract
        assertEq(USDC.balanceOf(address(positionAction)),  0);
        assertEq(USDT.balanceOf(address(positionAction)), 0);
        assertEq(stablecoin.balanceOf(address(positionAction)), 0);
    }

    // ERRORS
    function test_increaseLever_invalidSwaps() public {
        uint256 upFrontUnderliers = 20_000*1e6;
        uint256 auxAmountOutMin = upFrontUnderliers * 1e12 * 99 / 100; // allow 1% slippage on aux swap and convert to dai decimals
        uint256 borrowAmount = auxAmountOutMin; // we want the amount of stablecoin we borrow to be equal to the amount of underliers we receieve in aux swap
        uint256 amountOutMin = borrowAmount * 99 / 100;

        LeverParams memory leverParams;
        {   
            // mint USDC to user
            deal(address(USDC), user, upFrontUnderliers);

            // build increase lever params
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(USDC);
            auxAssets[1] = address(DAI);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                    amount: upFrontUnderliers, // amount of USDC to swap in
                    limit: auxAmountOutMin, // min amount of DAI to receive
                    recipient: address(positionAction),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
        }

        vm.prank(user);
        USDC.approve(address(userProxy), upFrontUnderliers);

        leverParams.primarySwap.recipient = address(userProxy); // this should trigger PositionAction__increaseLever_invalidPrimarySwap
        vm.expectRevert(PositionAction.PositionAction__increaseLever_invalidPrimarySwap.selector);
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
        leverParams.primarySwap.recipient = address(positionAction); // fix the error


        leverParams.auxSwap.recipient = address(userProxy); // this should trigger PositionAction__increaseLever_invalidAuxSwap
        vm.expectRevert(PositionAction.PositionAction__increaseLever_invalidAuxSwap.selector);
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
    }

    function test_decreaseLever_invalidSwaps() public {
        _increaseLever(
            userProxy,
            daiVault,
            20_000*1 ether,
            40_000 ether, // borrowAmount
            40_000 ether * 99/100 // amountOutMin
        );

        // we will completely delever the position so use full collateral and debt amounts
        uint256 collateralAmount;
        uint256 amountOut;
        uint256 maxAmountIn;
        {
            (uint256 initialCollateral, uint256 initialNormalDebt) = daiVault.positions(address(userProxy));
            collateralAmount = initialCollateral; // delever the entire collateral amount
            amountOut = initialNormalDebt; // delever the entire debt amount
            maxAmountIn = initialNormalDebt * 101/100; // allow 1% slippage on primary swap
        }
        
        // build decrease lever params
        LeverParams memory leverParams;
        uint256 minResidualRate = 1e6 * 99/100; // allow 1% slippage on aux swap, rate should be in out token decimals

        {
            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(USDC);

            leverParams = LeverParams({
                position: address(userProxy),
                vault: address(daiVault),
                collateralToken: address(DAI),
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
                    amount: 0,
                    limit: 0,
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(stablePoolIdArray, auxAssets)
                }), 
                auxJoin: emptyJoin,
                auxJoinToken: address(0)
            });
            
            // first simulate the primary swap to calculate values for aux swap
            leverParams.auxSwap.amount = collateralAmount - _simulateBalancerSwap(leverParams.primarySwap);
            leverParams.auxSwap.limit = leverParams.auxSwap.amount * minResidualRate / 1 ether;
        }


        // trigger PositionAction__decreaseLever_invalidPrimarySwap
        leverParams.primarySwap.recipient = address(userProxy);
        vm.expectRevert(PositionAction.PositionAction__decreaseLever_invalidPrimarySwap.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                address(0) // residualRecipient
            )
        );
        leverParams.primarySwap.recipient = address(positionAction); // fix the error


        // trigger PositionAction__decreaseLever_invalidAuxSwap
        leverParams.auxSwap.swapType = SwapType.EXACT_OUT;
        vm.expectRevert(PositionAction.PositionAction__decreaseLever_invalidAuxSwap.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                address(0) // residualRecipient
            )
        );
        leverParams.auxSwap.swapType = SwapType.EXACT_IN; // fix the error

        // trigger PositionAction__decreaseLever_invalidResidualRecipient
        leverParams.auxSwap = emptySwap;
        vm.expectRevert(PositionAction.PositionAction__decreaseLever_invalidResidualRecipient.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                collateralAmount, // collateral to decrease by
                address(0) // <=== this should trigger the error
            )
        );

    }

    function test_onFlashLoan_cannotCallDirectly() public {
        vm.expectRevert(PositionAction.PositionAction__onFlashLoan__invalidSender.selector);
        positionAction.onFlashLoan(address(0), address(0), 0, 0, "");
    }

    function test_onCreditFlashLoan_cannotCallDirectly() public {
        vm.expectRevert(PositionAction.PositionAction__onCreditFlashLoan__invalidSender.selector);
        positionAction.onCreditFlashLoan(address(0), 0, 0, "");
    }


    // simple helper function to increase lever
    function _increaseLever(
        PRBProxy proxy,
        CDPVault vault,
        uint256 upFrontUnderliers,
        uint256 amountToLever,
        uint256 amountToLeverLimit
    ) public returns (uint256 expectedAmountIn) {
        LeverParams memory leverParams;
        {
            address upFrontToken = address(vault.token());

            address[] memory assets = new address[](2);
            assets[0] = address(stablecoin);
            assets[1] = address(upFrontToken);

            // mint directly to swap actions for simplicity
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
                auxSwap: emptySwap, // no aux swap
                auxJoin: emptyJoin,
                auxJoinToken: address(0) 
            });

            expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        }

        vm.startPrank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(vault.token()),
                upFrontUnderliers,
                address(proxy),
                emptyPermitParams
            )
        );
        vm.stopPrank();
    }
}