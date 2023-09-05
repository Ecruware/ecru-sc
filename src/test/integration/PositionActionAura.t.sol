// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {WAD} from "../../utils/Math.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {JoinAction, JoinParams, JoinProtocol} from "../../proxy/JoinAction.sol";
import {PositionAction, LeverParams, CollateralParams} from "../../proxy/PositionAction.sol";

import {ApprovalType, PermitParams} from "../../proxy/TransferAction.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {PermitMaker} from "../utils/PermitMaker.sol";
import {PositionAction4626} from "../../proxy/PositionAction4626.sol";

// temp stuff
import {IVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IBaseRewardPool4626, IOperator} from "../../vendor/IBaseRewardPool4626.sol";
import {AuraVault} from "aura/AuraVault.sol";

contract PositionActionAuraTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    address wstETH_bb_a_WETH_BPTl = 0x41503C9D499ddbd1dCdf818a1b05e9774203Bf46;
    bytes32 poolId = 0x41503c9d499ddbd1dcdf818a1b05e9774203bf46000000000000000000000594;

    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant bbaweth = 0xbB6881874825E60e1160416D6C426eae65f2459E;
    address constant rewardToken = 0xba100000625a3754423978a60c9317c58a424e3D;

    ERC4626 constant auraRewardsPool = ERC4626(0xA822b750F8f84020ECD691164c5f6a0F7A5e7C64);

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
        vm.label(bbaweth, "bbaweth");
        vm.label(wstETH_bb_a_WETH_BPTl, "wstETH-bb-a-WETH-BPTl");

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        auraVault = new AuraVault({
            rewardPool_: address(auraRewardsPool),
            asset_ : wstETH_bb_a_WETH_BPTl,
            feed_: address(oracle),
            maxClaimerIncentive_: 100,
            maxLockerIncentive_: 100,
            tokenName_:  "Aura Vault",
            tokenSymbol_: "auraVault"
        });

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

        vault.addLimitPriceTick(1 ether, 0);

        // configure oracle spot prices
        oracle.updateSpot(address(wstETH_bb_a_WETH_BPTl), WAD);
        oracle.updateSpot(address(rewardToken), WAD);
        oracle.updateSpot(address(auraVault), WAD);

        // configure vaults
        cdm.setParameter(address(vault), "debtCeiling", 5_000_000 ether);

        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        vm.startPrank(user);
        ERC20(wstETH).approve(address(permit2), type(uint256).max);
        ERC20(bbaweth).approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // setup state variables to avoid stack too deep
        weightedPoolIdArray.push(weightedPoolId); 

        // deploy position actions
        positionAction = new PositionAction4626(address(flashlender), address(swapAction), address(joinAction));
    }

    function test_deposit() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(wstETH_bb_a_WETH_BPTl), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_bb_a_WETH_BPTl),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        ERC20(wstETH_bb_a_WETH_BPTl).approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_joinAndDeposit() public {
        uint256 depositAmount = 1000 ether;

        deal(wstETH, user, depositAmount);

        (JoinParams memory joinParams, PermitParams[] memory permitParams) = _getJoinActionParams(user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_bb_a_WETH_BPTl),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
            
        ERC20(wstETH_bb_a_WETH_BPTl).approve(address(userProxy), depositAmount);

        address[] memory targets = new address[](2);
        targets[0] = address(joinAction);
        targets[1] = address(positionAction);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            joinAction.transferAndJoin.selector,
            user,
            permitParams,
            joinParams
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
        uint256 bbawethAmount = 1000 ether;

        deal(wstETH, user, wstETHAmount);
        deal(bbaweth, user, bbawethAmount);

        JoinParams memory joinParams;

        // transfer the tokens to the proxy and call join on the joinAction
        vm.startPrank(user);
        ERC20(wstETH).transfer(address(userProxy), wstETHAmount);
        ERC20(bbaweth).transfer(address(userProxy), bbawethAmount);
        vm.stopPrank();

        address[] memory tokens = new address[](3);
        tokens[0] = wstETH_bb_a_WETH_BPTl;
        tokens[1] = wstETH;
        tokens[2] = bbaweth;

        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[0] = 0;
        maxAmountsIn[1] = wstETHAmount;
        maxAmountsIn[2] = bbawethAmount;

        uint256[] memory tokensIn = new uint256[](2);
        tokensIn[0] = wstETHAmount;
        tokensIn[1] = bbawethAmount;

        joinParams = JoinParams({
            protocol: JoinProtocol.BALANCER,
            poolId: poolId,
            assets: tokens,
            assetsIn: tokensIn,
            maxAmountsIn: maxAmountsIn,
            minOut: 0,
            recipient: user
        });

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(wstETH_bb_a_WETH_BPTl),
            amount: wstETHAmount + bbawethAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.startPrank(user);
        ERC20(wstETH_bb_a_WETH_BPTl).approve(address(userProxy), wstETHAmount + bbawethAmount);
        vm.stopPrank();

        address[] memory targets = new address[](2);
        targets[0] = address(joinAction);
        targets[1] = address(positionAction);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            joinAction.join.selector,
            joinParams
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
        assertEq(collateral, wstETHAmount + bbawethAmount);
    }

    function test_increaseLever_balancerToken_upfront() public {
        uint256 upFrontUnderliers = 20000 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 69000 ether;

        (JoinParams memory joinParams, ) = _getJoinActionParams(address(positionAction), amountOutMin);

        deal(address(wstETH_bb_a_WETH_BPTl), user, upFrontUnderliers);

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
            auxJoin: joinParams
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        vm.prank(user);
        ERC20(wstETH_bb_a_WETH_BPTl).approve(address(userProxy), upFrontUnderliers);

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(wstETH_bb_a_WETH_BPTl),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(userProxy));
        // assert that collateral is now equal to the upFrontAmount + the amount received from the join
        assertEq(collateral, expectedAmountIn + upFrontUnderliers);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

    }

    function test_increaseLever_balancerUnderlier_upfront() public {
        uint256 upFrontUnderliers = 20000 ether;
        uint256 borrowAmount = 70000 ether;
        uint256 amountOutMin = 69000 ether;

        (JoinParams memory joinParams, ) = _getJoinActionParams(address(positionAction), amountOutMin + upFrontUnderliers);

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
            auxJoin: joinParams
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

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
        // assert that collateral is now equal to the upFrontAmount + the amount received from the join
        assertEq(collateral, expectedAmountIn + upFrontUnderliers);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = vault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function _getJoinActionParams(address user_, uint256 depositAmount) view internal returns (
        JoinParams memory joinParams,
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

        address[] memory tokens = new address[](3);
        tokens[0] = wstETH_bb_a_WETH_BPTl;
        tokens[1] = wstETH;
        tokens[2] = bbaweth;

        permitParams[1] = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: depositAmount,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[0] = 0;
        maxAmountsIn[1] = depositAmount;
        maxAmountsIn[2] = 0;

        uint256[] memory tokensIn = new uint256[](2);
        tokensIn[0] = depositAmount;
        tokensIn[1] = 0;

        joinParams = JoinParams({
            protocol: JoinProtocol.BALANCER,
            poolId: poolId,
            assets: tokens,
            assetsIn: tokensIn,
            maxAmountsIn: maxAmountsIn,
            minOut: 0,
            recipient: user_
        });
    }

    function getForkBlockNumber() internal virtual override(IntegrationTestBase) pure returns (uint256){
        return 17870449; // Aug-08-2023 01:17:35 PM +UTC
    }
}