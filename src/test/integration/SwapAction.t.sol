// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxyRegistry} from "prb-proxy/PRBProxyRegistry.sol";
import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";
import {IVault as IBalancerVault} from "../../vendor/IBalancerVault.sol";

import {PermitMaker} from "../utils/PermitMaker.sol";

import {ApprovalType, PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";

contract SwapActionTest is Test {
    using SafeERC20 for ERC20;

    SwapAction internal swapAction;

    // user and permit2 related variables
    PRBProxy internal userProxy;
    uint256 internal userPk;
    address internal user;
    uint256 internal constant NONCE = 0;

    // swap protocols
    address internal constant ONE_INCH = 0x1111111254EEB25477B68fb85Ed929f73A960582;
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant UNISWAP_V3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Permit2
    ISignatureTransfer internal constant permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // tokens
    ERC20 internal constant DAI = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    ERC20 internal constant USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 internal constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 internal constant BOND = ERC20(0x0391D2021f89DC339F60Fff84546EA23E337750f);
    ERC20 internal constant BAL = ERC20(0xba100000625a3754423978a60c9317c58a424e3D);

    // Chainlink oracles
    IPriceFeed internal constant DAI_ETH_FEED = IPriceFeed(0x773616E4d11A78F511299002da57A0a94577F1f4); // DAI:ETH
    IPriceFeed internal constant USDC_ETH_FEED = IPriceFeed(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4); // USDC:ETH
    IPriceFeed internal constant BAL_USD_FEED = IPriceFeed(0xdF2917806E30300537aEB49A7663062F4d1F2b5F); // BAL:USD

    // uni v3
    IUniswapV3Router univ3Router = IUniswapV3Router(UNISWAP_V3);
    bytes internal constant DAI_USDC_PATH = abi.encodePacked(address(DAI), uint24(100), address(USDC));
    bytes internal constant DAI_WETH_BOND_PATH =
        abi.encodePacked(address(DAI), uint24(3000), address(WETH), uint24(3000), address(BOND));
    bytes internal constant DAI_WETH_USDC_PATH =
        abi.encodePacked(address(DAI), uint24(3000), address(WETH), uint24(3000), address(USDC));

    // Balancer
    bytes32 internal constant wethDaiPoolId = 0x0b09dea16768f0799065c475be02919503cb2a3500020000000000000000001a;
    bytes32 internal constant balWethPoolId = 0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;
    // USDC, DAI, USDT StablePool
    bytes32 internal constant balancerStablePoolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
    IBalancerVault internal constant balancerVault = IBalancerVault(BALANCER_VAULT);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 17055414); // 15/04/2023 20:43:00 UTC

        swapAction = new SwapAction(ONE_INCH, balancerVault, univ3Router);

        userPk = 0x12341234;
        user = vm.addr(userPk);

        PRBProxyRegistry prbProxyRegistry = new PRBProxyRegistry();
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // set allowance for permit2 transfers
        vm.startPrank(user);
        DAI.approve(address(permit2), type(uint256).max);
        USDC.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(DAI), "DAI");
        vm.label(address(BOND), "BOND");
        vm.label(address(permit2), "permit2");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(user), "user");
    }

    /// ======== transferAndSwap tests ======== ///

    /// @dev Permit2 transfer and swap on univ3, using exact-in, with single-hop path (DAI to USDC).
    function test_transferAndSwap_Permit2_Uniswap_ExactIn_SingleHop() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 amountOutMin = (amountIn * 98) / 100e12; // allow 2% slippage and convert to USDC decimals
        deal(address(DAI), user, amountIn);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(DAI),
            address(userProxy),
            amountIn,
            NONCE,
            deadline,
            userPk
        );
        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: amountIn,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.UNIV3,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: DAI_USDC_PATH
        });

        // call transfer and swap from user proxy
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        uint256 amountOut = abi.decode(response, (uint256));

        // assert swap success
        assertEq(USDC.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);
    }

    /// @dev Permit2 transfer and swap on univ3, using exact-in, with multi-hop path (DAI to WETH to BOND).
    function test_transferAndSwap_Permit2_Uniswap_ExactIn_MultiHop() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 amountOutMin = (amountIn * 98) / 100e12; // allow 2% slippage and convert to USDC decimals
        deal(address(DAI), user, amountIn);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(DAI),
            address(userProxy),
            amountIn,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: amountIn,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.UNIV3,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: DAI_WETH_BOND_PATH
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        uint256 amountOut = abi.decode(response, (uint256));

        // assert swap success
        assertEq(BOND.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);
    }

    /// @dev Standard erc20 transfer and swap on univ3, using exact-out, with single-hop path (USDC to DAI).
    function test_transferAndSwap_Permit1_Uniswap_ExactOut_SingleHop() public {
        uint256 amountOut = 1_000 * 1e18; // amount out of DAI we expect
        uint256 amountInMax = (amountOut * 102) / 100e12; // allow 2% slippage
        deal(address(USDC), user, amountInMax);

        // get permit signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermitTransferFromSignature(
            address(USDC),
            address(userProxy),
            amountInMax,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT,
            approvalAmount: amountInMax,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.UNIV3,
            swapType: SwapType.EXACT_OUT,
            assetIn: address(USDC),
            amount: amountOut,
            limit: amountInMax,
            recipient: user,
            deadline: deadline,
            args: DAI_USDC_PATH
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );

        uint256 amountIn = abi.decode(response, (uint256));

        // assert swap success
        assertEq(DAI.balanceOf(user), amountOut);
        assertEq(USDC.balanceOf(user), amountInMax - amountIn);
        assertLe(amountIn, amountInMax);
    }

    /// @dev Standard erc20 transfer and swap on univ3, using exact-out, with multi-hop path (USDC to WETH to DAI).
    function test_transferAndSwap_Permit1_Uniswap_ExactOut_MultiHop() public {
        uint256 amountOut = 1_000 * 1e18; // amount out of DAI we expect
        uint256 amountInMax = (amountOut * 102) / 100e12; // allow 2% slippage
        deal(address(USDC), user, amountInMax);

        // get permit signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermitTransferFromSignature(
            address(USDC),
            address(userProxy),
            amountInMax,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT,
            approvalAmount: amountInMax,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.UNIV3,
            swapType: SwapType.EXACT_OUT,
            assetIn: address(USDC),
            amount: amountOut,
            limit: amountInMax,
            recipient: user,
            deadline: deadline,
            args: DAI_WETH_USDC_PATH
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );

        uint256 amountIn = abi.decode(response, (uint256));

        // assert swap success
        assertEq(DAI.balanceOf(user), amountOut);
        assertEq(USDC.balanceOf(user), amountInMax - amountIn);
        assertLe(amountIn, amountInMax);
    }

    /// @dev Permit2 transfer and swap on Balancer, using exact-in, with single-hop path (DAI to USDC)
    function test_transferAndSwap_Permit2_Balancer_ExactIn_SingleHop() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 amountOutMin = (amountIn * 98) / 100e12; // allow 2% slippage and convert to USDC decimals
        deal(address(DAI), user, amountIn);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(DAI),
            address(userProxy),
            amountIn,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: amountIn,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = balancerStablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(DAI);
        assets[1] = address(USDC);

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: abi.encode(poolIds, assets)
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        uint256 amountOut = abi.decode(response, (uint256));

        // assert swap success
        assertEq(USDC.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);
    }

    /// @dev Standard erc20 transfer and swap on Balancer, using exact-out, with single-hop path (USDC to DAI).
    function test_transferAndSwap_Permit1_Balancer_ExactOut_SingleHop() public {
        uint256 amountOut = 1_000 * 1e18; // amount out of DAI we expect
        uint256 amountInMax = (amountOut * 102) / 100e12; // allow 2% slippage
        deal(address(USDC), user, amountInMax);

        // get permit signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermitTransferFromSignature(
            address(USDC),
            address(userProxy),
            amountInMax,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT,
            approvalAmount: amountInMax,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = balancerStablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(DAI);
        assets[1] = address(USDC);

        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_OUT,
            assetIn: address(USDC),
            amount: amountOut,
            limit: amountInMax,
            recipient: user,
            deadline: deadline,
            args: abi.encode(poolIds, assets)
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );

        uint256 amountIn = abi.decode(response, (uint256));

        // assert swap success
        assertEq(DAI.balanceOf(user), amountOut);
        assertEq(USDC.balanceOf(user), amountInMax - amountIn);
        assertLe(amountIn, amountInMax);
    }

    /// @dev Standard erc20 transfer and swap on Balancer, using exact-out, with multi-hop path (USDC to DAI to WETH).
    function test_transferAndSwap_Permit1_Balancer_ExactOut_MultiHop() public {
        uint256 amountOut = 1 ether; // amount out of WETH we expect
        uint256 amountInMax = ((amountOut / uint256(USDC_ETH_FEED.latestAnswer())) * 102e6) / 100; // allow 2% slippage, convert to USDC decimals
        deal(address(USDC), user, amountInMax);

        // get permit signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermitTransferFromSignature(
            address(USDC),
            address(userProxy),
            amountInMax,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT,
            approvalAmount: amountInMax,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        bytes32[] memory poolIds = new bytes32[](2);
        poolIds[0] = wethDaiPoolId;
        poolIds[1] = balancerStablePoolId;

        address[] memory assets = new address[](3);
        assets[0] = address(WETH);
        assets[1] = address(DAI);
        assets[2] = address(USDC);

        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_OUT,
            assetIn: address(USDC),
            amount: amountOut,
            limit: amountInMax,
            recipient: user,
            deadline: deadline,
            args: abi.encode(poolIds, assets)
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );

        uint256 amountIn = abi.decode(response, (uint256));

        // assert swap success
        assertEq(WETH.balanceOf(user), amountOut);
        assertEq(USDC.balanceOf(user), amountInMax - amountIn);
        assertLe(amountIn, amountInMax);
    }

    /// @dev Standard erc20 transfer and swap on Balancer, using exact-out, with multi-hop path (USDC to DAI to WETH to BAL).
    function test_transferAndSwap_Permit1_Balancer_ExactOut_MultiHop2() public {
        uint256 rawAmountIn = 1_000 * 1e6; // amount in of USDC we expect to put in [1e6]
        uint256 amountOut = (rawAmountIn * 1e20) / uint256(BAL_USD_FEED.latestAnswer()); // amount out of BAL we expect [WAD]
        uint256 amountInMax = (rawAmountIn * 102) / 100; // allow 2% slippage [1e6]
        deal(address(USDC), user, amountInMax);

        // get permit signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermitTransferFromSignature(
            address(USDC),
            address(userProxy),
            amountInMax,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT,
            approvalAmount: amountInMax,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        bytes32[] memory poolIds = new bytes32[](3);
        poolIds[0] = balWethPoolId;
        poolIds[1] = wethDaiPoolId;
        poolIds[2] = balancerStablePoolId;

        address[] memory assets = new address[](4);
        assets[0] = address(BAL);
        assets[1] = address(WETH);
        assets[2] = address(DAI);
        assets[3] = address(USDC);

        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_OUT,
            assetIn: address(USDC),
            amount: amountOut,
            limit: amountInMax,
            recipient: user,
            deadline: deadline,
            args: abi.encode(poolIds, assets)
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );

        uint256 amountIn = abi.decode(response, (uint256));

        // assert swap success
        assertEq(BAL.balanceOf(user), amountOut);
        assertEq(USDC.balanceOf(user), amountInMax - amountIn);
        assertLe(amountIn, amountInMax);
    }

    /// @dev Permit2 transfer and swap on Balancer, using exact-in, with multi-hop path (DAI to WETH to BAL).
    function test_transferAndSwap_Permit2_Balancer_ExactIn_MultiHop() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 amountOutMin = (amountIn * 98e8) / (uint256(BAL_USD_FEED.latestAnswer()) * 100); // allow 2% slippage and convert to BAL decimals
        deal(address(DAI), user, amountIn);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(DAI),
            address(userProxy),
            amountIn,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: amountIn,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        bytes32[] memory poolIds = new bytes32[](2);
        poolIds[0] = wethDaiPoolId;
        poolIds[1] = balWethPoolId;

        address[] memory assets = new address[](3);
        assets[0] = address(DAI);
        assets[1] = address(WETH);
        assets[2] = address(BAL);

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: abi.encode(poolIds, assets)
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        uint256 amountOut = abi.decode(response, (uint256));

        // assert swap success
        assertEq(BAL.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);
    }

    /// @dev Permit2 transfer and swap on Balancer, using exact-in, with multi-hop path (USDC to DAI to WETH to BAL).
    function test_transferAndSwap_Permit2_Balancer_ExactIn_MultiHop2() public {
        uint256 amountIn = 1_000 * 1e6; //amountIn USDC decimals
        uint256 amountOutMin = (amountIn * 98e20) / (uint256(BAL_USD_FEED.latestAnswer()) * 100); // allow 2% slippage and convert to BAL decimals
        deal(address(USDC), user, amountIn);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(USDC),
            address(userProxy),
            amountIn,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: amountIn,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // construct swap params
        bytes32[] memory poolIds = new bytes32[](3);
        poolIds[0] = balancerStablePoolId;
        poolIds[1] = wethDaiPoolId;
        poolIds[2] = balWethPoolId;

        address[] memory assets = new address[](4);
        assets[0] = address(USDC);
        assets[1] = address(DAI);
        assets[2] = address(WETH);
        assets[3] = address(BAL);

        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: address(USDC),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: abi.encode(poolIds, assets)
        });

        // call transferAndSwap
        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        uint256 amountOut = abi.decode(response, (uint256));

        // assert swap success
        assertEq(BAL.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);
    }

    ///@dev Permit2 transfer and swap on 1inch, using exact-in, with multiple dexes.
    function test_transferAndSwap_Permit2_1Inch() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 amountOutMin = (amountIn * 97) / 100e12; // allow 2% slippage and convert to USDC decimals
        deal(address(DAI), user, amountIn);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(DAI),
            address(userProxy),
            amountIn,
            NONCE,
            deadline,
            userPk
        );

        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: amountIn,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // create snapshot to revert to after each swap
        uint256 snapshot = vm.snapshot();

        // SUSHI

        // route through DAI -> WETH -> USDC, at .03% slippage through SUSHI
        // calldata generated via 1inch api
        bytes memory args = bytes.concat(
            hex"f78dc253",
            bytes32(uint256(uint160(user))), // receiver
            hex"0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000003635c9adc5dea00000000000000000000000000000000000000000000000000000000000003a9458f200000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000003b6d0340c3d03e4f041fd4cd388c549ee2a29a9e5075882f80000000000000003b6d0340397ff1542f962076d0bfe58ea045ffa2d347aca0cfee7c08"
        );

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.ONEINCH,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: args
        });

        vm.prank(user);
        bytes memory response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        uint256 amountOut = abi.decode(response, (uint256));

        // assert sushi swap success
        assertEq(USDC.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);

        // clear state
        vm.revertTo(snapshot);
        snapshot = vm.snapshot();

        // CURVE
        // calldata generated via 1inch api
        args = bytes.concat(
            hex"12aa3caf0000000000000000000000007122db0ebe4eb9b434a9f2ffe6760bc03bfbd0e00000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000007122db0ebe4eb9b434a9f2ffe6760bc03bfbd0e0",
            bytes32(uint256(uint160(user))), // receiver
            hex"00000000000000000000000000000000000000000000003635c9adc5dea00000000000000000000000000000000000000000000000000000000000003a65b5a6000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001160000000000000000000000000000000000000000000000f80000ca0000b05120a5407eae9ba41422680e2e00537571bcc53efbfd6b175474e89094c44da98b954eedeac495271d0f00443df02124000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003a65b5a60020d6bdbf78a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4880a06c4eca27a0b86991c6218b36c1d19d4a2e9eb0ce3606eb481111111254eeb25477b68fb85ed929f73a96058200000000000000000000cfee7c08"
        );

        // construct swap params
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.ONEINCH,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: args
        });

        vm.prank(user);
        response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        amountOut = abi.decode(response, (uint256));

        // assert curve swap success
        assertEq(USDC.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);

        vm.revertTo(snapshot);

        // UNI V2
        // calldata generated via 1inch api
        args = bytes.concat(
            hex"f78dc253",
            bytes32(uint256(uint160(user))),
            hex"0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000003635c9adc5dea00000000000000000000000000000000000000000000000000000000000003ac77eb500000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000100000000000000003b6d0340ae461ca67b15dc8dc81ce7615e0320da1a9ab8d5cfee7c08"
        );

        // construct swap params
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.ONEINCH,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: args
        });

        vm.prank(user);
        response = userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        amountOut = abi.decode(response, (uint256));

        // assert univ2 swap success
        assertEq(USDC.balanceOf(user), amountOut);
        assertGe(amountOut, amountOutMin);
    }

    /// ======== oneInchSwap tests ======== ///

    ///@dev Test that correct error is thrown when there is no 1inch revert message.
    function test_revert_swap1Inch_emptyMsg() public {
        uint256 amountIn = 1 * 1e18; // swap more DAI than userProxy has to trigger revert

        // sanity check that userProxy has less than amountIn
        assertLt(DAI.balanceOf(address(userProxy)), amountIn);

        // calldata generated via 1inch api
        // route DAI 1_001 -> WETH -> USDC at .03% slippage through SUSHI
        bytes
            memory sushiSwapArgs = hex"0502b1c50000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000003643AA6479860400000000000000000000000000000000000000000000000000000000000039efb87b0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000200000000000000003b6d0340c3d03e4f041fd4cd388c549ee2a29a9e5075882f80000000000000003b6d0340397ff1542f962076d0bfe58ea045ffa2d347aca0cfee7c08";

        
        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.ONEINCH,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountIn * 99/100,
            recipient: address(userProxy),
            deadline: block.timestamp + 100,
            args: sushiSwapArgs
        });

        vm.expectRevert(abi.encodeWithSignature("SwapAction__revertBytes_emptyRevertBytes()"));
        vm.prank(user);
        userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.swap.selector, swapParams)
        );
    }

    ///@dev Test that revert messages from 1inch are relayed correctly.
    function test_revert_swap1Inch_nonEmptyMsg() public {
        uint256 amountIn = 1_000 * 1e18; // swap more DAI than userProxy has to trigger revert

        // sanity check that userProxy has zero DAI in it
        assertEq(DAI.balanceOf(address(userProxy)), 0);

        // route through DAI -> WETH -> USDC, at .03% slippage through SUSHI
        // calldata generated via 1inch api
        bytes
            memory sushiSwapArgs = hex"0502b1c50000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000000000002386f26fc1000000000000000000000000000000000000000000000000000000000000000026120000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000003b6d0340aaf5110db6e744ff70fb339de037b990a20bdacecfee7c08";


        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.ONEINCH,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountIn * 99/100,
            recipient: address(userProxy),
            deadline: block.timestamp + 100,
            args: sushiSwapArgs
        });

        vm.expectRevert("Dai/insufficient-balance");
        vm.prank(user);
        userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.swap.selector, swapParams)
        );
    }

    function test_swap_notSupported() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 amountOutMin = (amountIn * 97) / 100e12; // allow 2% slippage and convert to USDC decimals
        deal(address(DAI), user, amountIn);

        PermitParams memory permitParams;
        uint256 deadline = block.timestamp + 100;

        // route through DAI -> WETH -> USDC, at .03% slippage through SUSHI
        // calldata generated via 1inch api
        bytes memory args = bytes.concat(
            hex"f78dc253",
            bytes32(uint256(uint160(user))), // receiver
            hex"0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000003635c9adc5dea00000000000000000000000000000000000000000000000000000000000003a9458f200000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000003b6d0340c3d03e4f041fd4cd388c549ee2a29a9e5075882f80000000000000003b6d0340397ff1542f962076d0bfe58ea045ffa2d347aca0cfee7c08"
        );

        // construct swap params
        SwapParams memory swapParams = SwapParams({
            swapProtocol: SwapProtocol.ONEINCH,
            swapType: SwapType.EXACT_IN,
            assetIn: address(DAI),
            amount: amountIn,
            limit: amountOutMin,
            recipient: user,
            deadline: deadline,
            args: args
        });

        vm.prank(user);
        DAI.approve(address(userProxy), amountIn);

        // trigger SwapAction__swap_notSupported
        swapParams.swapType = SwapType.EXACT_OUT;
        vm.prank(user);
        vm.expectRevert(SwapAction.SwapAction__swap_notSupported.selector);
        userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(swapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
    }
}

interface IPriceFeed {
    /// @dev decimals of latestAnswer
    function decimals() external view returns (uint256);

    function latestAnswer() external view returns (int256 answer);
}
