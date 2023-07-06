// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {WAD} from "../../utils/Math.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PositionAction, LeverParams, CollateralParams} from "../../proxy/PositionAction.sol";
import {IChai, PositionActionChai} from "../../proxy/PositionActionChai.sol";

contract PositionActionChaiTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault_TypeA chaiVault;

    // actions
    PositionActionChai positionAction;

    // tokens
    ERC20 constant CHAI = ERC20(0x06AF07097C9Eeb7fD685c692751D5C66dB49c215);

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    function setUp() public override {
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        chaiVault = createCDPVault_TypeA(
            CHAI, // token
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

        chaiVault.addLimitPriceTick(1 ether, 0);

        // configure oracle spot prices
        oracle.updateSpot(address(CHAI), _chaiToDai(1 ether));
        oracle.updateSpot(address(DAI), 1 ether);

        // configure vaults
        cdm.setParameter(address(chaiVault), "debtCeiling", 5_000_000 ether);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // deploy position actions
        positionAction = new PositionActionChai(address(flashlender), address(swapAction));

        // set up variables to avoid stack too deep
        stablePoolIdArray.push(stablePoolId);
    }


    function test_deposit() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(CHAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(CHAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        CHAI.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(chaiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_DAI() public {
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
                address(chaiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        assertEq(collateral, _daiToChai(depositAmount));
        assertEq(normalDebt, 0);
    }

    function test_deposit_USDC() public {
        uint256 depositAmount = 10_000 * 1e6;

        deal(address(USDC), user, depositAmount);

        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(DAI);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(USDC),
                amount: depositAmount,
                limit: depositAmount * 1e12 / 100,
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(collateralParams.auxSwap);

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(chaiVault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        assertEq(collateral, _daiToChai(expectedAmountOut));
        assertEq(normalDebt, 0);
    }

    function test_withdraw() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(chaiVault), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(CHAI),
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
                address(chaiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(CHAI.balanceOf(user), initialDeposit);
    }

    function test_withdraw_DAI() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(chaiVault), initialDeposit);

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
                address(chaiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(DAI.balanceOf(user), _chaiToDai(initialDeposit));
    }

    function test_withdraw_USDC() public {
        // deposit DAI to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(chaiVault), initialDeposit);

        // build withdraw params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(DAI);
        assets[1] = address(USDC);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(DAI),
                amount: initialDeposit,
                limit: initialDeposit * 99 / 100e12,
                recipient: address(user),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(collateralParams.auxSwap);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(chaiVault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (int256 balance,) = cdm.accounts(address(userProxy));
        assertEq(balance, 0);

        assertEq(USDC.balanceOf(user), expectedAmountOut);
    }

    function test_increaseLever() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 50_000 ether;
        uint256 amountOutMin = 49_000 ether;

        deal(address(CHAI), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(chaiVault),
            collateralToken: address(CHAI),
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
            auxSwap: emptySwap
        });

        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);

        vm.prank(user);
        CHAI.approve(address(userProxy), upFrontUnderliers);

        // call increaseLever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(CHAI),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, _daiToChai(expectedAmountOut) + upFrontUnderliers);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = chaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_increaseLever_DAI_upfront() public {
        uint256 upFrontUnderliers = 20_000 ether;
        uint256 borrowAmount = 50_000 ether;
        uint256 amountOutMin = 49_000 ether;

        deal(address(DAI), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(chaiVault),
            collateralToken: address(CHAI),
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
            auxSwap: emptySwap
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

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, _daiToChai(expectedAmountOut) + _daiToChai(upFrontUnderliers));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = chaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_increaseLever_USDC_upfront() public {
        uint256 upFrontUnderliers = 20_000 * 1e6;
        uint256 borrowAmount = 50_000 ether;
        uint256 amountOutMin = 49_000 ether;

        deal(address(USDC), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        address[] memory auxAssets = new address[](2);
        auxAssets[0] = address(USDC);
        auxAssets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(chaiVault),
            collateralToken: address(CHAI),
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
                amount: upFrontUnderliers,
                limit: upFrontUnderliers * 99e12 / 100,
                recipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(stablePoolIdArray, auxAssets)
            })
        });

        // get expected return amounts
        (uint256 auxExpectedAmountOut, uint256 expectedAmountOut) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);

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

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, _daiToChai(expectedAmountOut) + _daiToChai(auxExpectedAmountOut));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertEq(normalDebt, borrowAmount);

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt) = chaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_decreaseLever() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            chaiVault,
            20_000 ether, // upFrontUnderliers
            50_000 ether, // borrowAmount
            49_000 ether // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = chaiVault.positions(address(userProxy));

        // build decrease lever params
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(chaiVault),
            collateralToken: address(CHAI),
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
            auxSwap: emptySwap
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        // call decreaseLever
        vm.startPrank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                _daiToChai(maxAmountIn), // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - _daiToChai(maxAmountIn));

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy, assert always more or equal than expected
        assertApproxEqRel(DAI.balanceOf(address(userProxy)), maxAmountIn - expectedAmountIn, 5e15); // shouldnt be more than .1% diff

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = chaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function test_decreaseLever_and_receive_USDC() public {
        // lever up first and record the current collateral and normalized debt
        _increaseLever(
            userProxy, // position
            chaiVault,
            20_000 ether, // upFrontUnderliers
            50_000 ether, // borrowAmount
            49_000 ether // amountOutMin
        );
        (uint256 initialCollateral, uint256 initialNormalDebt) = chaiVault.positions(address(userProxy));

        // build decrease lever params
        uint256 auxExpectedAmountOut;
        uint256 expectedAmountIn;
        uint256 amountOut = 5_000 ether;
        uint256 maxAmountIn = 5_100 ether;

        address[] memory assets = new address[](2);
        assets[0] = address(stablecoin);
        assets[1] = address(DAI);

        address[] memory auxAssets = new address[](2);
        auxAssets[0] = address(DAI);
        auxAssets[1] = address(USDC);

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(chaiVault),
            collateralToken: address(CHAI),
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
            })
        });

        // first simulate the primary swap to calculate values for aux swap
        expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);
        leverParams.auxSwap.amount = _chaiToDai(_daiToChai(maxAmountIn)) - expectedAmountIn;
        leverParams.auxSwap.limit = leverParams.auxSwap.amount * 99 / 100e12;

        // get expected return amounts
        (auxExpectedAmountOut, expectedAmountIn) = _simulateBalancerSwapMulti(leverParams.auxSwap, leverParams.primarySwap);

        // call decreaseLever
        vm.startPrank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                _daiToChai(maxAmountIn), // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = chaiVault.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of DAI we swapped for stablecoin
        assertEq(collateral, initialCollateral - _daiToChai(maxAmountIn));

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping DAI
        assertEq(normalDebt, initialNormalDebt - amountOut);

        // assert that the left over was transfered to the user proxy, assert always more or equal than expected
        assertApproxEqRel(USDC.balanceOf(address(user)), auxExpectedAmountOut, 5e15); // shouldnt be more than .5% diff

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt) = chaiVault.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }


    // HELPER FUNCTIONS

    function _daiToChai(uint256 wad) internal returns (uint256) {
        IPot pot = IPot(IChai(address(CHAI)).pot());
        uint256 chi = block.timestamp > pot.rho() ? pot.drip() : pot.chi();
        return wad * 1e27 / chi;
    }

    function _chaiToDai(uint256 wad) internal returns (uint256) {
        IPot pot = IPot(IChai(address(CHAI)).pot());
        uint256 chi = block.timestamp > pot.rho() ? pot.drip() : pot.chi();
        return chi * wad / 1e27;
    }

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

    // simple helper function to increase lever
    function _increaseLever(
        PRBProxy proxy,
        CDPVault vault,
        uint256 upFrontUnderliers, // in DAI
        uint256 amountToLever, // in DAI
        uint256 amountToLeverLimit // in DAI
    ) public {
        LeverParams memory leverParams;
        {
            address upFrontToken = address(DAI);

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
                auxSwap: emptySwap // no aux swap
            });
        }

        vm.startPrank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(DAI),
                upFrontUnderliers,
                address(proxy),
                emptyPermitParams
            )
        );
        vm.stopPrank();
    }

}

interface IPot {
    function chi() external returns (uint256);
    function rho() external returns (uint256);
    function drip() external returns (uint256);
}
