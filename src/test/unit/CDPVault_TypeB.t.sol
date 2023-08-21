// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICDM} from "../../interfaces/ICDM.sol";
import {IBuffer} from "../../interfaces/IBuffer.sol";
import {IOracle} from "../../interfaces/IOracle.sol";
import {ICDPVaultBase} from "../../interfaces/ICDPVault.sol";
import {IPermission} from "../../interfaces/IPermission.sol";

import {WAD, wmul, wdiv, wpow} from "../../utils/Math.sol";
import {CDM} from "../../CDM.sol";
import {CDPVault, calculateDebt, calculateNormalDebt, VAULT_CONFIG_ROLE, TICK_MANAGER_ROLE} from "../../CDPVault.sol";
import {CDPVault_TypeB} from "../../CDPVault_TypeB.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";

contract CDPVaultWrapper is CDPVault_TypeB {

    constructor (
        ICDM cdm_,
        IOracle oracle_,
        IBuffer buffer_,
        IERC20 token_,
        uint256 tokenScale_,
        uint256 protocolFee_,
        uint256 rebateParams_,
        uint256 limitOrderFloor_,
        VaultConfig memory vaultConfig_,
        LiquidationConfig memory liquidationConfig_,
        AccessConfig memory roles_
    ) CDPVault_TypeB(
        cdm_,
        oracle_,
        buffer_,
        token_,
        tokenScale_,
        protocolFee_,
        rebateParams_,
        limitOrderFloor_,
        vaultConfig_,
        liquidationConfig_,
        roles_
    ) {}

    function enteredEmergencyMode(
        uint64 globalLiquidationRatio,
        uint256 spotPrice_,
        uint256 totalNormalDebt_,
        uint64 rateAccumulator,
        uint256 globalAccruedRebate
    ) public view returns (bool) {
        return _enteredEmergencyMode(
            globalLiquidationRatio,
            spotPrice_,
            totalNormalDebt_,
            rateAccumulator,
            globalAccruedRebate
        );
    }

    function checkLimitOrder(
        address owner, uint256 normalDebt, uint64 currentRebateFactor
    ) public returns (uint64 rebateFactor) {
        return _checkLimitOrder(owner, normalDebt, currentRebateFactor);
    }

    function checkLimitOrder(
        uint256 limitOrderId, uint256 priceTick, uint256 normalDebt, uint64 currentRebateFactor
    ) public returns (uint64 rebateFactor) {
        return _checkLimitOrder(limitOrderId, priceTick, normalDebt, currentRebateFactor);
    }

    function calculateRateAccumulator(GlobalIRS memory globalIRS) public view returns(uint64) {
        return _calculateRateAccumulator(globalIRS, uint64(globalIRS.baseRate));
    }

    function deriveLimitOrderId(address maker) public pure returns (uint256 orderId){
        return _deriveLimitOrderId(maker);
    }
}


contract PositionOwner {
    constructor(IPermission vault) {
        // Allow deployer to modify Position
        vault.modifyPermission(msg.sender, true);
    }
}

contract CDPVault_TypeBTest is TestBase {
    
    uint256 constant internal BASE_RATE_1_0 = 1 ether; // 0% base rate
    uint256 constant internal BASE_RATE_1_005 = 1000000000157721789; // 0.5% base rate
    uint256 constant internal BASE_RATE_1_025 = 1000000000780858271; // 2.5% base rate

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _virtualDebt(CDPVault_TypeB vault, address position) internal view returns (uint256) {
        (, uint256 normalDebt) = vault.positions(position);
        (uint64 rateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(position);
        return wmul(rateAccumulator, normalDebt) - accruedRebate;
    }

    function _updateSpot(uint256 price) internal {
        oracle.updateSpot(address(token), price);
    }

    function _calculateUtilizationBasedInterestRate(
        CDPVault_TypeB vault, 
        InterestRateModel.GlobalIRS memory globalIRS,
        uint256 targetUtilizationRatio,
        uint256 minInterestRate,
        uint256 maxInterestRate,
        uint256 targetInterestRate
    ) internal view returns (uint64 interestRate){
        // derive interest rate from utilization
        uint256 totalDebt_ = calculateDebt(vault.totalNormalDebt(), globalIRS.rateAccumulator, globalIRS.globalAccruedRebate);
        uint256 utilizationRatio = (totalDebt_ == 0)
            ? 0 : wdiv(totalDebt_, totalDebt_ + cdm.creditLine(address(this)));
        // if utilization is below the optimal utilization ratio,
        // the interest rate is scaled linearly between the minimum and target base rate

        if (utilizationRatio <= targetUtilizationRatio){
            interestRate = uint64(minInterestRate + wmul(
                wdiv(targetInterestRate - minInterestRate, targetUtilizationRatio),
                utilizationRatio
            ));
        // if utilization is above the optimal utilization ratio,
        // the interest rate is scaled linearly between the target and maximum base rate
        } else {
            interestRate = uint64(targetInterestRate + wmul(
                wdiv(maxInterestRate - targetInterestRate, WAD - targetUtilizationRatio), 
                utilizationRatio - targetUtilizationRatio
            ));
        }
    }

    function _createCDPVault_TypeB(
        uint256 protocolFee,
        uint128 maxRebate,
        uint128 rebateRate,
        uint256 baseRate,
        uint256 liquidationRatio
    ) private returns (CDPVaultWrapper vault){
        vault = new CDPVaultWrapper({
            cdm_: cdm,
            oracle_: oracle,
            buffer_: buffer,
            token_: token,
            tokenScale_: 10**IERC20Metadata(address(token)).decimals(),
            protocolFee_: protocolFee,
            rebateParams_: uint256(rebateRate) | (uint256(maxRebate) << 128),
            limitOrderFloor_: WAD,
            vaultConfig_: _getDefaultVaultConfig(),
            liquidationConfig_: _getDefaultLiquidationConfig(),
            roles_: _getDefaultAccessConfig()
            }
        );

        vault.setParameter("baseRate", baseRate);
        vault.setParameter("liquidationRatio", liquidationRatio);

        vault.setUp();
    }

    function _createCDPVault_TypeB(
        uint256 protocolFee,
        uint128 maxRebate,
        uint128 rebateRate,
        uint256 baseRate,
        uint256 liquidationRatio,
        uint256 debtCeiling,
        uint128 debtFloor
    ) private returns (CDPVaultWrapper vault){
        vault = new CDPVaultWrapper({
            cdm_: cdm,
            oracle_: oracle,
            buffer_: buffer,
            token_: token,
            tokenScale_: 10**IERC20Metadata(address(token)).decimals(),
            protocolFee_: protocolFee,
            rebateParams_: uint256(rebateRate) | (uint256(maxRebate) << 128),
            limitOrderFloor_: WAD,
            vaultConfig_: _getDefaultVaultConfig(),
            liquidationConfig_: _getDefaultLiquidationConfig(),
            roles_: _getDefaultAccessConfig()
            }
        );

        vault.setParameter("baseRate", baseRate);
        vault.setParameter("liquidationRatio", liquidationRatio);
        vault.setParameter("debtFloor", debtFloor);
        _setDebtCeiling(vault, debtCeiling);

        vault.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_setParameter() public {
        CDPVault_TypeB vault = _createCDPVault_TypeB({
            protocolFee: 0,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1 ether
        });

        vault.setParameter("debtFloor", 100 ether);
        vault.setParameter("liquidationRatio", 1.25 ether);
        vault.setParameter("globalLiquidationRatio", 1.1 ether);
        vault.setParameter("limitOrderFloor", 50 ether);
        vault.setParameter("baseRate", BASE_RATE_1_005);

        (uint128 debtFloor, uint64 liquidationRatio, uint64 globalLiquidationRatio) = vault.vaultConfig();
        assertEq(debtFloor, 100 ether);
        assertEq(liquidationRatio, 1.25 ether);
        assertEq(globalLiquidationRatio, 1.1 ether);
        assertEq(vault.limitOrderFloor(), 50 ether);

        CDPVault_TypeB.GlobalIRS memory globalIRS = vault.getGlobalIRS();
        assertEq(globalIRS.baseRate, int256(BASE_RATE_1_005));

        vault.setParameter("baseRate", type(uint256).max);
        globalIRS = vault.getGlobalIRS();
        assertEq(globalIRS.baseRate, int64(-1));
    }
    
    function test_setParameter_revertsOnUnrecognizedParam() public {
        CDPVault_TypeB vault = _createCDPVault_TypeB({
            protocolFee: 0,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1 ether
        });
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__setParameter_unrecognizedParameter.selector);
        vault.setParameter("asd", 100 ether);
    }

    function test_enteredEmergencyMode() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 0,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: WAD,
            liquidationRatio : 1.25 ether
        });

        // not in emergency mode
        assertEq(vault.paused(), false);
        assertEq(vault.pausedAt(), 0);

        // not in emergency mode
        assertEq(vault.enteredEmergencyMode(1.25 ether, 1 ether, 0, 0, 0), false);
        
        // in emergency mode because collateralization ratio is too low
        assertEq(vault.enteredEmergencyMode(1.25 ether, 1 ether, 1 ether, uint64(WAD), 0), true);
        
        // collateralize the vault
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);

        // not in emergency mode because collateralization ratio is high enough
        assertEq(vault.enteredEmergencyMode(1.25 ether, 1 ether, 1 ether, uint64(WAD), 0), false);
    }

    function test_checkLimitOrder() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 0,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether
        });

        vault.grantRole(TICK_MANAGER_ROLE, address(this));
        vault.setParameter("limitOrderFloor", 10 ether);

        // delegate credit
        _setDebtCeiling(vault, 100 ether);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 80 ether);
        
        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);

        uint64 rebateFactor = vault.calculateRebateFactorForPriceTick(WAD);

        // check limit order rebateFactor
        assertEq(
            vault.checkLimitOrder(address(this), 80 ether, rebateFactor),
            rebateFactor
        );

        // check the limit order is still active
        assertEq(
            vault.limitOrders(vault.deriveLimitOrderId(address(this))),
            WAD
        );
    }

    function test_checkLimitOrder_removesOrderBelowFloor_1() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 0,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether
        });

        vault.setParameter("limitOrderFloor", 30 ether);

        _setDebtCeiling(vault, 200 ether);
        // createCredit(address(vault), 100 ether);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);

        // call the check with a fictive normalDebt to test the floor check
        uint64 rebateFactor = vault.checkLimitOrder(address(this), 10 ether, uint64(WAD));

        // check that the limit order was removed        
        assertEq(rebateFactor, 0);
        assertEq(
            vault.limitOrders(vault.deriveLimitOrderId(address(this))),
            0
        );

    }

    function test_deriveLimitOrderId(address maker) public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 0,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: WAD,
            liquidationRatio: 1.25 ether
        });

        assertEq(
            vault.deriveLimitOrderId(maker),
            uint256(uint160(maker))
        );
    }

    function test_claimFees() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether
        });

        _setDebtCeiling(vault, 100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        vm.warp(block.timestamp + 60 days);

        cdm.modifyPermission(address(vault), true);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 0, -40 ether);

        // fees are sent to the buffer
        uint256 feesClaimed = vault.claimFees();
        (int256 balance, ) = cdm.accounts(address(buffer));

        assertGt(feesClaimed, 0);
        assertEq(feesClaimed, uint256(balance));
    }

    function test_modifyCollateralAndDebt_depositCollateral() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 10 ether
        });

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 0);
    }

    function test_modifyCollateralAndDebt_createDebt() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 10 ether
        });

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 0);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 0, 50 ether);
    }

    function test_modifyCollateralAndDebt_depositCollateralAndDrawDebt() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 80 ether);
    }

    function test_modifyCollateralAndDebt_emptyCall() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 0, 0);
    }

    function test_modifyCollateralAndDebt_repayPositionAndWidthdraw() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 80 ether);
        cdm.modifyPermission(address(vault), true);
        vault.modifyCollateralAndDebt(position, address(this), address(this), -100 ether, -80 ether);
    }

    function test_modifyCollateralAndDebt_revertsOnUnsafePosition() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        // vm.expectRevert (CDPVault_TypeB.CDPVault_TypeB__modifyCollateralAndDebt_notSafe.selector);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 100 ether);
    }

    function test_modifyCollateralAndDebt_revertsOnDebtFloor() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 10 ether
        });

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__modifyPosition_debtFloor.selector);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 5 ether);
    }

    function test_addLimitPriceTick_addMultipleTicks() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });

        uint256 limitOrderPriceIncrement = 0.25 ether;
        uint256 price = 100 ether;
        uint256 nextPrice = 0;
        while(price >= 1 ether) {
            vault.addLimitPriceTick(price, nextPrice);
            assertTrue(vault.activeLimitPriceTicks(price));
            nextPrice = price;
            price -= limitOrderPriceIncrement;
        }
    }

    function test_addLimitPriceTick_revertsOnOutOfRange() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__addLimitPriceTick_limitPriceTickOutOfRange.selector);
        vault.addLimitPriceTick(0, 0);

        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__addLimitPriceTick_limitPriceTickOutOfRange.selector);
        vault.addLimitPriceTick(100 ether + 1, 0);
    }

    function test_addLimitPriceTick_revertsOnInvalidOrder() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });
        vault.addLimitPriceTick(2 ether, 0);

        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__addLimitPriceTick_invalidPriceTickOrder.selector);
        vault.addLimitPriceTick(2 ether, 1 ether);
    }

    function test_removeLimitPriceTick() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });
        uint256 limitOrderPriceIncrement = 0.25 ether;
        uint256 price = 100 ether;
        uint256 nextPrice = 0;
        while(price >= 1 ether) {
            vault.addLimitPriceTick(price, nextPrice);
            nextPrice = price;
            price -= limitOrderPriceIncrement;
        }
        price = 100 ether;
        while(price >= 1 ether) {
            vault.removeLimitPriceTick(price);
            assertTrue(vault.activeLimitPriceTicks(price) == false);
            price -= limitOrderPriceIncrement;
        }
    }

    function test_getPriceTick() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });
        vault.addLimitPriceTick(WAD, 0);

        (uint priceTick, bool isActive) = vault.getPriceTick(0);

        assertEq(priceTick, WAD);
        assertTrue(isActive);
    }

    function test_getPriceTick_notFound() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });
        vault.addLimitPriceTick(WAD, 0);

        (uint priceTick, bool isActive) = vault.getPriceTick(1);

        assertEq(priceTick, 0);
        assertTrue(isActive == false);
    }

    function test_createLimitOrder() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);

    }

    function test_createLimitOrder_priceTickNotActive() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        // create limit order
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__createLimitOrder_limitPriceTickNotActive.selector);
        vault.createLimitOrder(WAD);     
    }

    function test_createLimitOrder_revertsOnLimitOrderFloor() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        vault.setParameter("limitOrderFloor", 20 ether);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 15 ether);
        
        vault.addLimitPriceTick(WAD, 0);

        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__createLimitOrder_limitOrderFloor.selector);
        vault.createLimitOrder(WAD);     
    }

    function test_createLimitOrder_revertsOnExistingLimitOrder() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

    //     // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        vault.addLimitPriceTick(WAD, 0);

        vault.createLimitOrder(WAD);     

        // attempt to create the limit order again
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__createLimitOrder_limitOrderAlreadyExists.selector);
        vault.createLimitOrder(WAD);     
    }

    function test_getLimitOrder_returnsCorrectID() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);

        assertEq(
            uint256(uint160(address(this))),
            vault.getLimitOrder(WAD,0)
        );
    }

    function test_getLimitOrder_returnsDefaultOnNotFound () public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        assertEq(
            0,
            vault.getLimitOrder(WAD,0)
        );
    }

    function test_getLimitOrder_multiple() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: 1.1 ether,
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  200 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 400 ether);
        token.approve(address(vault), 400 ether);
        vault.deposit(address(this), 400 ether);

        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 100 ether, 50 ether);

        address positionB = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionB, address(this), address(this), 100 ether, 50 ether);
        
        address positionC = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionC, address(this), address(this), 100 ether, 50 ether);
        
        vault.addLimitPriceTick(WAD, 0);

        vm.prank(address(positionA));
        vault.createLimitOrder(WAD);

        vm.prank(address(positionB));
        vault.createLimitOrder(WAD);
        
        vm.prank(address(positionC));
        vault.createLimitOrder(WAD);

        uint256 limitOrderID = uint256(uint160(address(positionA)));
        vm.startPrank(address(positionA));
        assertEq(
            limitOrderID,
            vault.getLimitOrder(WAD,0)
        );
        vm.stopPrank();

        limitOrderID = limitOrderID = uint256(uint160(address(positionB)));
        vm.startPrank(address(positionB));
        assertEq(
            limitOrderID,
            vault.getLimitOrder(WAD,1)
        );
        vm.stopPrank();

        limitOrderID = limitOrderID = uint256(uint160(address(positionC)));
        vm.startPrank(address(positionC));
        assertEq(
            limitOrderID,
            vault.getLimitOrder(WAD,2)
        );
        vm.stopPrank();
    }

    function test_reserve_interest() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_005)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 80 ether);
        assertEq(credit(address(this)), 80 ether);
        
        assertEq(_virtualDebt(vault, address(this)), 80 ether);
        vm.warp(block.timestamp + 365 days);
        assertGt(_virtualDebt(vault, address(this)), 80 ether);
        // (uint256 debt, ) = cdm.debtors(address(vault)); // does not collect anymore
        // assertGt(debt, 80 ether);
    }

    function test_reserve_interest_repayAtDebtCeiling() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_005)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  150 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 200 ether);
        token.approve(address(vault), 200 ether);
        vault.deposit(address(this), 200 ether);
        assertEq(vault.cash(address(this)), 200 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 200 ether, 150 ether);
        assertEq(credit(address(this)), 150 ether);
        
        assertEq(_virtualDebt(vault, address(this)), 150 ether);
        vm.warp(block.timestamp + 365 days);
        assertGt(_virtualDebt(vault, address(this)), 150 ether);

        // obtain additional credit to repay interest
        createCredit(address(this), 1 ether);
        
        cdm.modifyPermission(address(vault), true);

        // repay debt
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), -200 ether, -150 ether);
    }

    function test_non_reserve_interest() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_005)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 80 ether);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(this)), 80 ether);

        // accrue interest        
        assertEq(_virtualDebt(vault, address(this)), 80 ether);
        vm.warp(block.timestamp + 365 days);
        assertGt(_virtualDebt(vault, address(this)), 80 ether);

        // obtain additional credit to repay interest
        createCredit(address(this), 0.5 ether);

        cdm.modifyPermission(address(vault), true);

        // repay debt
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), -100 ether, -80 ether);
        assertEq(_virtualDebt(vault, address(this)), 0);
        assertGt(credit(address(vault)), 100 ether);
    }

    function test_exchange_simple_reserve() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        cdm.modifyPermission(address(vault), true);
        
        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);
        assertEq(vault.cash(address(this)), 0);
        
        // exchange
        assertEq(debt(address(vault)), 50 ether);
        vault.exchange(WAD, 50 ether);
        assertEq(credit(address(this)), 0);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(vault)), 0);
        assertEq(vault.cash(address(this)), 50 ether);
    }

    function test_exchange_simple_non_reserve() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  50 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);
        assertEq(vault.cash(address(this)), 0);

        cdm.modifyPermission(address(vault), true);

        // exchange
        assertEq(credit(address(vault)), 0);
        vault.exchange(WAD, 50 ether);
        assertEq(credit(address(this)), 0);
        assertEq(credit(address(vault)), 50 ether);
        assertEq(vault.cash(address(this)), 50 ether);
    }

    function test_exchange_debtFloor() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 10 ether
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);
        assertEq(vault.cash(address(this)), 0);
        assertEq(debt(address(vault)), 50 ether);
        cdm.modifyPermission(address(vault), true);

        uint256 id = vm.snapshot();
        
        // exchange all the debt (no dust)
        vault.exchange(WAD, 50 ether);
        assertEq(credit(address(this)), 0);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(vault)), 0);
        assertEq(vault.cash(address(this)), 50 ether);

        // exchange reverts since debt floor amount had to be left behind
        vm.revertTo(id);
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__exchange_notEnoughExchanged.selector);
        vault.exchange(WAD, 45 ether);

        // exchange up to the debt ceiling
        vm.revertTo(id);
        vault.exchange(WAD, 40 ether);
        assertEq(credit(address(this)), 10 ether);
        assertEq(debt(address(vault)), 10 ether);
        assertEq(vault.cash(address(this)), 40 ether);

        assertEq(credit(address(vault)), 0);
    }

    function test_exchange_multipleTicks() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  200 ether,
            debtFloor: 40 ether
        });

        // create position
        token.mint(address(this), 400 ether);
        token.approve(address(vault), 400 ether);
        vault.deposit(address(this), 400 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 100 ether, 50 ether);
        address positionB = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionB, address(this), address(this), 100 ether, 50 ether);
        address positionC = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionC, address(this), address(this), 100 ether, 50 ether);
        address positionD = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionD, address(this), address(this), 100 ether, 50 ether);
        assertEq(vault.cash(address(this)), 0);
        
        // create limit order
        // [WAD]
        vault.addLimitPriceTick(WAD, 0);
        vm.expectRevert();
        vault.addLimitPriceTick(1.01 ether, WAD);
        // [WAD, 1.01 ether]
        vault.addLimitPriceTick(1.01 ether, 0);
        vm.expectRevert();
        vault.addLimitPriceTick(1.005 ether, WAD);
        // [WAD, 1.005 ether, 1.01 ether]
        vault.addLimitPriceTick(1.005 ether, 1.01 ether);
        assertEq(vault.activeLimitPriceTicks(WAD), true);
        assertEq(vault.activeLimitPriceTicks(1.01 ether), true);
        
        // invalid price tick
        vm.startPrank(address(positionA));
        vm.expectRevert();
        vault.createLimitOrder(1.02 ether);
        vm.stopPrank();
        vm.prank(address(positionA));
        vault.createLimitOrder(1.0 ether);
        
        vm.prank(address(positionB));
        vault.createLimitOrder(1.01 ether);
        vm.prank(address(positionB));
        vault.cancelLimitOrder();
        
        vm.prank(address(positionC));
        vault.createLimitOrder(1.01 ether);

        vm.prank(address(positionD));
        vault.createLimitOrder(1.01 ether);

        // logLimitOrders(ICDPVault(address(vault)));

        // exchange
        assertEq(debt(address(vault)), 200 ether);
        vm.expectRevert();
        vault.exchange(WAD, 125 ether);

        vault.exchange(1.01 ether, 105 ether);
        assertEq(credit(address(this)), 95 ether);
        assertEq(debt(address(vault)), 95 ether);
        assertEq(vault.cash(address(this)), 50 ether + wdiv(uint256(55 ether), uint256(1.01 ether)));
        assertEq(credit(address(vault)), 0);
    }

    function test_exchange_skipUnsafe() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  110 ether,
            debtFloor: 1 ether
        });

        // create position
        token.mint(address(this), 110 ether);
        token.approve(address(vault), 110 ether);
        vault.deposit(address(this), 110 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 10 ether, 8 ether);
        address positionB = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionB, address(this), address(this), 100 ether, 50 ether);
        assertEq(vault.cash(address(this)), 0);

        _updateSpot(0.8 ether);
        
        // create limit order
        // [WAD]
        vault.addLimitPriceTick(WAD, 0);
        // [WAD, 1.01 ether]
        vault.addLimitPriceTick(1.01 ether, 0);
        // [WAD, 1.005 ether, 1.01 ether]
        vault.addLimitPriceTick(1.005 ether, 1.01 ether);
        assertEq(vault.activeLimitPriceTicks(WAD), true);
        assertEq(vault.activeLimitPriceTicks(1.01 ether), true);
        
        vm.prank(address(positionA));
        vault.createLimitOrder(1.0 ether);
        vm.prank(address(positionB));
        vault.createLimitOrder(1.01 ether);

        assertEq(vault.limitOrders(uint160(positionA)), 1.0 ether);
        assertEq(vault.limitOrders(uint160(positionB)), 0);
    }
    
    function test_emergencyMode() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_0)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create positions
        token.mint(address(this), 110 ether);
        token.approve(address(vault), 110 ether);
        vault.deposit(address(this), 110 ether);
        address positionA = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionA, address(this), address(this), 10 ether, 2 ether);
        address positionB = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(positionB, address(this), address(this), 100 ether, 80 ether);
        
        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vm.prank(address(positionA));
        vault.createLimitOrder(WAD);
        assertEq(vault.cash(address(this)), 0);

        _updateSpot(0.5 ether - 1);
        
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__checkEmergencyMode_entered.selector);
        vault.exchange(WAD, 1);

        vault.enterEmergencyMode();
    }

    function test_exchange_triggersEmergencyMode() public {
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 80 ether);
        
        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);
        assertEq(vault.cash(address(this)), 0);

        vault.setParameter("globalLiquidationRatio", 4 ether);
        assertTrue(vault.paused() == false);

        vm.warp(block.timestamp + 366 days);
        
        // exchange should trigger the emergency mode
        vm.expectRevert (CDPVault_TypeB.CDPVault_TypeB__checkEmergencyMode_entered.selector);
        vault.exchange(WAD, 30 ether);
    }

    function test_calculateNormalDebt() public {
        uint256 initialDebt = 50 ether;
        CDPVaultWrapper vault = _createCDPVault_TypeB({
            protocolFee: 1.05 ether,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether,
            debtCeiling:  100 ether,
            debtFloor: 0
        });

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, int256(initialDebt));

        (uint64 rateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(address(this));

        // debt and normal debt should be equal at this point
        uint256 debt = _virtualDebt(vault, address(this));
        assertEq(calculateNormalDebt(debt, rateAccumulator, accruedRebate), initialDebt);

        // accrue interest
        vm.warp(block.timestamp + 365 days);
        (rateAccumulator, accruedRebate, ) = vault.virtualIRS(address(this));

        // normally this would result in a division rounding error, assert that the rounding error is accounted for
        debt = _virtualDebt(vault, address(this));
        assertEq(calculateNormalDebt(debt, rateAccumulator, accruedRebate), initialDebt);

        // accrue more interest
        vm.warp(block.timestamp + 10 * 365 days);
        (rateAccumulator, accruedRebate, ) = vault.virtualIRS(address(this));

        // check rounding error is accounted for again
        debt = _virtualDebt(vault, address(this));
        assertEq(calculateNormalDebt(debt, rateAccumulator, accruedRebate), initialDebt);
    }


    /// Helper functions 

    function _setDebtCeiling(CDPVault_TypeB vault, uint256 debtCeiling) internal {
        cdm.setParameter(address(vault), "debtCeiling", debtCeiling);
    }

    function _getDefaultLiquidationConfig() internal pure returns (CDPVault_TypeB.LiquidationConfig memory) {
        return CDPVault_TypeB.LiquidationConfig({
            liquidationPenalty: uint64(WAD),
            liquidationDiscount: uint64(WAD),
            targetHealthFactor: 1.25 ether
        });
    }

    function _getDefaultVaultConfig() internal pure returns (CDPVault_TypeB.VaultConfig memory) {
        return CDPVault_TypeB.VaultConfig({
            debtFloor: 0,
            liquidationRatio: 1.25 ether,
            globalLiquidationRatio: 1.25 ether
        });
    }

    function _getDefaultAccessConfig() internal view returns (CDPVault_TypeB.AccessConfig memory){
        return CDPVault_TypeB.AccessConfig({
            configAdminRole: address(this),
            tickManagerRole: address(this),
            pauseRole: address(this),
            unwinderRole: address(this),
            adminRole: address(this)
        });
    }
}