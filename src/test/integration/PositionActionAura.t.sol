// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {PRBProxy} from "prb-proxy/PRBProxy.sol";
import {WAD, wmul, wdiv} from "../../utils/Math.sol";
import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PoolAction, PoolActionParams, Protocol} from "../../proxy/PoolAction.sol";
import {PositionAction, LeverParams, CollateralParams} from "../../proxy/PositionAction.sol";
import {ApprovalType, PermitParams} from "../../proxy/TransferAction.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {PermitMaker} from "../utils/PermitMaker.sol";
import {PositionAction4626} from "../../proxy/PositionAction4626.sol";
import {IVault} from "../../vendor/IBalancerVault.sol";
import {AuraVault} from "../../vendor/AuraVault.sol";

interface IBalancerComposableStablePool{
    function getActualSupply() external returns (uint256);
}

contract PositionActionAuraTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    bytes32 wstETH_WETH_PoolId = 0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2;
    address wstETH_WETH_BPT = 0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD;
    address BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    ERC4626 constant auraRewardsPool = ERC4626(0x2a14dB8D09dB0542f6A371c0cB308A768227D67D);

    // user
    PRBProxy userProxy;
    address internal user;
    uint256 internal userPk;
    uint256 internal constant NONCE = 0;

    PositionAction4626 positionAction;

    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] weightedPoolIdArray;

    // Permit2
    ISignatureTransfer internal constant permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // cdp vaults
    CDPVault_TypeA vault;

    AuraVault auraVault;

    function setUp() public override {
        super.setUp();

        vm.label(BALANCER_VAULT, "balancer");
        vm.label(wstETH, "wstETH");
        vm.label(wstETH_WETH_BPT, "wstETH-WETH-BPT");
        vm.label(BAL, "BAL");

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        auraVault = new AuraVault({
            rewardPool_: address(auraRewardsPool),
            asset_ : wstETH_WETH_BPT,
            feed_: address(oracle),
            maxClaimerIncentive_: 100,
            maxLockerIncentive_: 100,
            tokenName_:  "Aura Vault",
            tokenSymbol_: "auraVault"
        });

        vm.label(address(auraVault), "auraVault");
        vm.label(address(auraRewardsPool), "auraRewardsPool");

        // deploy vaults
        vault = createCDPVault_TypeA(
            ERC20(auraVault), // token
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

        vm.label(address(vault), "CDPVault_TypeA");

        vault.addLimitPriceTick(1 ether, 0);

        // configure oracle spot prices
        uint256 balancerTokenRate = _getBalancerTokenRateInUSD();
        oracle.updateSpot(address(wstETH_WETH_BPT), balancerTokenRate);
        oracle.updateSpot(address(auraVault), balancerTokenRate);
        oracle.updateSpot(address(WETH),_getWETHRateInUSD());
        oracle.updateSpot(address(stablecoin), _getStablecoinRateInUSD());
        oracle.updateSpot(address(BAL), _getBALRateInUSD());

        // configure vaults
        cdm.setParameter(address(vault), "debtCeiling", 5_000_000 ether);

        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        vm.label(address(userProxy), "userProxy");
        vm.label(address(user), "user");

        vm.startPrank(user);
        ERC20(wstETH).approve(address(permit2), type(uint256).max);
        WETH.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // setup state variables to avoid stack too deep
        weightedPoolIdArray.push(weightedPoolId); 

        // deploy position actions
        positionAction = new PositionAction4626(address(flashlender), address(swapAction), address(poolAction));
    }

    function test_deposit() public {
        uint256 depositAmount = 10_000 ether;

        _deposit(userProxy, address(vault), depositAmount);

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_joinAndDeposit_withPermit() public {
        uint256 depositAmount = 1000 ether;
        uint256 minOut = 1000 ether;

        deal(wstETH, user, depositAmount);

        PoolActionParams memory poolActionParams;
        PermitParams[] memory permitParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory maxAmountsIn = new uint256[](3);
            maxAmountsIn[0] = depositAmount;
            uint256[] memory tokensIn = new uint256[](2);
            tokensIn[0] = depositAmount;
            
            (poolActionParams, permitParams) = _getPoolActionParams(
                user,
                wstETH_WETH_PoolId,
                tokens,
                maxAmountsIn,
                tokensIn,
                0, //wstETH is at index 0
                depositAmount,
                minOut
            );
        }

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_WETH_BPT),
            amount: minOut,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
            
        ERC20(wstETH_WETH_BPT).approve(address(userProxy), minOut);

        address[] memory targets = new address[](2);
        targets[0] = address(poolAction);
        targets[1] = address(positionAction);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            PoolAction.transferAndJoin.selector,
            user,
            permitParams,
            poolActionParams
        );

        data[1] = abi.encodeWithSelector(
            positionAction.deposit.selector,
            address(userProxy),
            address(vault),
            collateralParams,
            emptyPermitParams
        );

        bool[] memory delegateCall = new bool[](2);
        delegateCall[0] = true;
        delegateCall[1] = true;

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

        (uint256 collateral, ) = vault.positions(address(userProxy));
        assertEq(collateral, depositAmount);
    }

    function test_joinAndDeposit_multipleTokens() public {
        uint256 wstETHAmount = 1000 ether;
        uint256 wETHAmount = 1000 ether;
        uint256 joinMinOut = (wstETHAmount + wETHAmount)*90/100;

        deal(wstETH, user, wstETHAmount);
        deal(address(WETH), user, wETHAmount);

        PoolActionParams memory poolActionParams;

        // transfer the tokens to the proxy and call join on the PoolAction
        vm.startPrank(user);
        ERC20(wstETH).transfer(address(userProxy), wstETHAmount);
        ERC20(address(WETH)).transfer(address(userProxy), wETHAmount);
        vm.stopPrank();

        address[] memory tokens = new address[](3);
        tokens[0] = wstETH;
        tokens[1] = wstETH_WETH_BPT;
        tokens[2] = address(WETH);

        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[0] = wstETHAmount;
        maxAmountsIn[1] = 0;
        maxAmountsIn[2] = wETHAmount;

        uint256[] memory tokensIn = new uint256[](2);
        tokensIn[0] = wstETHAmount;
        tokensIn[1] = wETHAmount;

        poolActionParams = PoolActionParams({
            protocol: Protocol.BALANCER,
            minOut: 0,
            recipient: user,
            args: abi.encode(
                wstETH_WETH_PoolId,
                tokens,
                tokensIn,
                maxAmountsIn
            )
        });        


        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_WETH_BPT),
            amount: joinMinOut,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.startPrank(user);
        ERC20(wstETH_WETH_BPT).approve(address(userProxy), joinMinOut);
        vm.stopPrank();

        address[] memory targets = new address[](2);
        targets[0] = address(poolAction);
        targets[1] = address(positionAction);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            PoolAction.join.selector,
            poolActionParams
        );

        data[1] = abi.encodeWithSelector(
            positionAction.deposit.selector,
            address(userProxy),
            address(vault),
            collateralParams,
            emptyPermitParams
        );

        bool[] memory delegateCall = new bool[](2);
        delegateCall[0] = true;
        delegateCall[1] = true;

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

        (uint256 collateral, ) = vault.positions(address(userProxy));
        uint256 shares = auraVault.convertToShares(joinMinOut);
        assertGe(collateral, shares);
    }

    function test_increaseLever_balancerToken_upfront() public {
        uint256 upFrontUnderliers = 20 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 69000 ether;
        uint256 joinOutMin = 0 ether;

        PoolActionParams memory poolActionParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory maxAmountsIn = new uint256[](3);
            uint256[] memory tokensIn = new uint256[](2);
            
            (poolActionParams, ) = _getPoolActionParams(
                address(positionAction), 
                wstETH_WETH_PoolId,
                tokens,
                maxAmountsIn,
                tokensIn,
                0,
                0,
                joinOutMin
            );
        }

        deal(address(wstETH_WETH_BPT), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(wstETH);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(auraVault),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount,
                limit: amountOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(weightedPoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: poolActionParams
        });

        vm.prank(user);
        ERC20(wstETH_WETH_BPT).approve(address(userProxy), upFrontUnderliers);

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(wstETH_WETH_BPT),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));
        
        // assert that collateral is now equal to the upFrontAmount + the amount received from the join
        uint256 shares = auraVault.convertToShares(joinOutMin + upFrontUnderliers);
        assertGe(collateral, shares);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_increaseLever_balancerUnderlier_upfront() public {
        uint256 upFrontUnderliers = 10 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 69000 ether;
        uint256 joinOutMin = 0 ether;
        _joinHelper(upFrontUnderliers, borrowAmount, amountOutMin, joinOutMin);
    }

    function test_increaseLever_multiswap() public {
        uint256 upFrontUnderliers = 20 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 0;
        uint256 joinOutMin = 0 ether;

        PoolActionParams memory poolActionParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory maxAmountsIn = new uint256[](3);
            uint256[] memory tokensIn = new uint256[](2);
            
            (poolActionParams, ) = _getPoolActionParams(
                address(positionAction),
                wstETH_WETH_PoolId, 
                tokens,
                maxAmountsIn,
                tokensIn,
                0,
                0,
                joinOutMin
            );
        }

        deal(address(wstETH), user, upFrontUnderliers);

        bytes32[] memory poolIdArray = new bytes32[](3);
        poolIdArray[0] = stablePoolId; 
        poolIdArray[1] = wethDaiPoolId;
        poolIdArray[2] = wstEthWethPoolId;

        // build increase lever params
        address[] memory assets = new address[](4);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);
        assets[2] = address(WETH);
        assets[3] = address(wstETH);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(auraVault),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount,
                limit: amountOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: poolActionParams
        });

        vm.prank(user);
        ERC20(wstETH).approve(address(userProxy), upFrontUnderliers);

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(wstETH),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));
        assertGe(collateral, auraVault.convertToShares(joinOutMin));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_increaseLever_upfrontTokenSwap() public {
        uint256 upFrontUnderliers = 40000 ether;
        uint256 upFrontUnderlierOutMin = 0 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 0;
        uint256 joinOutMin = 0 ether;
        
        PoolActionParams memory poolActionParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory maxAmountsIn = new uint256[](3);
            uint256[] memory tokensIn = new uint256[](2);
            
            (poolActionParams, ) = _getPoolActionParams(
                address(positionAction),
                wstETH_WETH_PoolId,
                tokens,
                maxAmountsIn,
                tokensIn,
                0,
                0,
                joinOutMin
            );
        }

        deal(address(DAI), user, upFrontUnderliers);

        bytes memory auxArgs;
        bytes memory primaryArgs;
        {
        bytes32[] memory auxPoolIdArray = new bytes32[](2);
        auxPoolIdArray[0] = wethDaiPoolId;
        auxPoolIdArray[1] = wstEthWethPoolId;

        address[] memory auxAssets = new address[](3);
        auxAssets[0] = address(DAI);
        auxAssets[1] = address(WETH);
        auxAssets[2] = address(wstETH);

        auxArgs = abi.encode(auxPoolIdArray, auxAssets);
        bytes32[] memory poolIdArray = new bytes32[](3);
        poolIdArray[0] = stablePoolId; 
        poolIdArray[1] = wethDaiPoolId;
        poolIdArray[2] = wstEthWethPoolId;

        // build increase lever params
        address[] memory assets = new address[](4);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);
        assets[2] = address(WETH);
        assets[3] = address(wstETH);
        primaryArgs = abi.encode(poolIdArray, assets);
        }

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(auraVault),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount,
                limit: amountOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: primaryArgs
            }),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(DAI),
                amount: upFrontUnderliers,
                limit: upFrontUnderlierOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: auxArgs
            }),
            auxAction: poolActionParams
        });

        vm.prank(user);
        ERC20(DAI).approve(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));
        assertGe(collateral, auraVault.convertToShares(joinOutMin));
        
        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_increaseLever_joinMultipleTokens() public {
        uint256 upFrontUnderliers = 40000 ether;
        uint256 upFrontUnderlierOutMin = 0 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 0;
        uint256 joinOutMin = 0 ether;

        PoolActionParams memory poolActionParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory maxAmountsIn = new uint256[](3);
            uint256[] memory tokensIn = new uint256[](2);
            
            (poolActionParams, ) = _getPoolActionParams(
                address(positionAction),
                wstETH_WETH_PoolId,
                tokens,
                maxAmountsIn,
                tokensIn,
                0,
                0,
                joinOutMin
            );
        }

        deal(address(DAI), user, upFrontUnderliers);

        vm.prank(user);
        ERC20(DAI).approve(address(userProxy), upFrontUnderliers);

        bytes memory auxArgs;
        bytes memory primaryArgs;
        {
            bytes32[] memory auxPoolIdArray = new bytes32[](1);
            auxPoolIdArray[0] = wethDaiPoolId;

            address[] memory auxAssets = new address[](2);
            auxAssets[0] = address(DAI);
            auxAssets[1] = address(WETH);

            auxArgs = abi.encode(auxPoolIdArray, auxAssets);

            bytes32[] memory poolIdArray = new bytes32[](3);
            poolIdArray[0] = stablePoolId; 
            poolIdArray[1] = wethDaiPoolId;
            poolIdArray[2] = wstEthWethPoolId;

            // build increase lever params
            address[] memory assets = new address[](4);
            assets[0] = address(stablecoin);
            assets[1] = address(DAI);
            assets[2] = address(WETH);
            assets[3] = address(wstETH);

            primaryArgs = abi.encode(poolIdArray, assets);
        }

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(auraVault),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount,
                limit: amountOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: primaryArgs
            }),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(DAI),
                amount: upFrontUnderliers,
                limit: upFrontUnderlierOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: auxArgs
            }),
            auxAction: poolActionParams
        });

        vm.prank(user);
        ERC20(wstETH).approve(address(userProxy), upFrontUnderliers);

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

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));
        assertGe(collateral, auraVault.convertToShares(joinOutMin));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_withdraw() public {
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(vault), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_WETH_BPT),
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
                address(vault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(ERC20(wstETH_WETH_BPT).balanceOf(user), initialDeposit);
    }

    function test_decreaseLever() public {
        uint256 upFrontUnderliers = 14 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 0 ether;
        uint256 joinOutMin = 0 ether;

        _joinHelper(upFrontUnderliers, borrowAmount, amountOutMin, joinOutMin);

        (uint256 initialCollateral, uint256 initialNormalDebt) = vault.positions(address(userProxy));

        uint256 amountOut = initialNormalDebt;
        uint256 maxAmountIn = initialCollateral;
        uint256 subCollateral = auraVault.previewWithdraw(maxAmountIn);

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(wstETH);

        PoolActionParams memory poolActionParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory minAmountsOut = new uint256[](3);
            uint256 outIndex = 0;
            uint256 bptAmount = subCollateral;

            poolActionParams = PoolActionParams({
                protocol: Protocol.BALANCER,
                minOut: 0,
                recipient: address(positionAction),
                args: abi.encode(
                    wstETH_WETH_PoolId,
                    wstETH_WETH_BPT,
                    bptAmount,
                    outIndex,
                    tokens,
                    minAmountsOut
                )
            });
        }

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(auraVault),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(wstETH),
                amount: amountOut, // exact amount of stablecoin to receive
                limit: maxAmountIn,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(weightedPoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: poolActionParams
        });

        // call decreaseLever
        vm.startPrank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                subCollateral, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - subCollateral);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function _deposit(PRBProxy proxy, address vault_, uint256 amount) internal {
        CDPVault_TypeA cdpVault = CDPVault_TypeA(vault_);
        deal(address(wstETH_WETH_BPT), user, amount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_WETH_BPT),
            amount: amount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        ERC20(wstETH_WETH_BPT).approve(address(proxy), amount);

        vm.prank(user);
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(proxy),
                address(cdpVault),
                collateralParams,
                emptyPermitParams
            )
        );
    }

    function _joinHelper(
        uint256 upFrontUnderliers,
        uint256 borrowAmount,
        uint256 amountOutMin,
        uint256 joinOutMin
    ) internal {
        PoolActionParams memory poolActionParams;
        {
            address[] memory tokens = new address[](3);
            tokens[0] = wstETH;
            tokens[1] = wstETH_WETH_BPT;
            tokens[2] = address(WETH);

            uint256[] memory maxAmountsIn = new uint256[](3);
            uint256[] memory tokensIn = new uint256[](2);
            
            (poolActionParams, ) = _getPoolActionParams(
                address(positionAction),
                wstETH_WETH_PoolId, 
                tokens,
                maxAmountsIn,
                tokensIn,
                0,
                0,
                joinOutMin
            );
        }
        deal(address(wstETH), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(wstETH);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(auraVault),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(stablecoin),
                amount: borrowAmount,
                limit: amountOutMin,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(weightedPoolIdArray, assets)
            }),
            auxSwap: emptySwap,
            auxAction: poolActionParams
        });

        vm.prank(user);
        ERC20(wstETH).approve(address(userProxy), upFrontUnderliers);

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(wstETH),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );
    }

    /// @dev Helper function that returns the lp token rate in USD
    function _getBalancerTokenRateInUSD() internal returns (uint256 price) {
        (, uint256[] memory balances, ) = IVault(BALANCER_VAULT).getPoolTokens(wstETH_WETH_PoolId);
        uint256 tokenWSTETHSupply = wmul(balances[0], _getWstETHRateInUSD());
        uint256 tokenWETHSupply = wmul(balances[2], _getWETHRateInUSD());
        uint256 totalSupply = IBalancerComposableStablePool(wstETH_WETH_BPT).getActualSupply();

        return wdiv(tokenWSTETHSupply + tokenWETHSupply, totalSupply);
    }

    /// @dev Helper function that returns a PoolActionParams struct and a permitParams array for a wstETH join
    function _getPoolActionParams(
        address user_,
        bytes32 poolId_,
        address[] memory tokens,
        uint256[] memory maxAmountsIn,
        uint256[] memory tokensIn,
        uint256 permitIndex,
        uint256 depositAmount,
        uint256 minOut_
    ) view internal returns (
        PoolActionParams memory poolActionParams,
        PermitParams[] memory permitParams
    ) {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(wstETH),
            address(userProxy),
            depositAmount,
            NONCE,
            deadline,
            userPk
        );
         
        permitParams = new PermitParams[](3);
        permitParams[permitIndex] = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: depositAmount,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        poolActionParams = PoolActionParams({
            protocol: Protocol.BALANCER,
            minOut: minOut_,
            recipient: user_,
            args: abi.encode(
                poolId_,
                tokens,
                tokensIn,
                maxAmountsIn
            )
        });
    }

    function getForkBlockNumber() internal virtual override(IntegrationTestBase) pure returns (uint256){
        return 18163902; //Sep-18-2023 04:06:35 PM +UTC
    }
}