// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICDM} from "../../interfaces/ICDM.sol";
import {IBuffer} from "../../interfaces/IBuffer.sol";
import {IOracle} from "../../interfaces/IOracle.sol";
import {ICDPVaultBase} from "../../interfaces/ICDPVault.sol";
import {ICDPVault_TypeBBase} from "../../interfaces/ICDPVault_TypeB.sol";
import {CDPVaultConstants, CDPVaultConfig, CDPVault_TypeBConfig} from "../../interfaces/ICDPVault_TypeB_Factory.sol";
import {IPermission} from "../../interfaces/IPermission.sol";
import {ICDPVault_Deployer} from "../../interfaces/ICDPVault_Deployer.sol";

import {WAD, wmul, wdiv, wpow} from "../../utils/Math.sol";
import {VAULT_CONFIG_ROLE, TICK_MANAGER_ROLE, VAULT_UNWINDER_ROLE} from "../../CDPVault.sol";
import {CDM} from "../../CDM.sol";
import {PAUSER_ROLE} from "../../utils/Pause.sol";
import {CDPVault, calculateDebt, calculateNormalDebt, VAULT_CONFIG_ROLE, TICK_MANAGER_ROLE} from "../../CDPVault.sol";
import {CDPVault_TypeB} from "../../CDPVault_TypeB.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";
import {CDPVault_TypeB_Factory, CreditWithholder, DEPLOYER_ROLE} from "../../CDPVault_TypeB_Factory.sol";

contract CDPVaultWrapper is CDPVault_TypeB {
    constructor(address factory) CDPVault_TypeB(factory) { }

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

    function calculateAssetsAndLiabilities(uint256 totalCreditWithheld) public returns (
        uint256 assets, uint256 liabilities, uint256 credit, uint256 creditLine
    ) {
        return _calculateAssetsAndLiabilities(totalCreditWithheld);
    }

    function calculateRateAccumulator(GlobalIRS memory globalIRS) public view returns(uint64) {
        return _calculateRateAccumulator(globalIRS, totalNormalDebt);
    }

    function deriveLimitOrderId(address maker) public pure returns (uint256 orderId){
        return _deriveLimitOrderId(maker);
    }
}

// CDPVault_TypeB wrapper contract to test internal methods
contract VaultWrapperFactory {
    ICDM private cdm;
    IOracle private oracle;
    IBuffer private buffer;
    IERC20 private token;
    uint256 private protocolFee;
    uint256 private utilizationParams;
    uint256 private rebateParams;
    uint256 private tokenScale;
    address private unwinderFactory;
    uint256 private maxUtilizationRatio;

    struct Params{
        ICDM cdm;
        IOracle oracle;
        IBuffer buffer;
        IERC20 token;
        address unwinderFactory;
        uint256 protocolFee;
        uint64 targetUtilizationRatio;
        uint64 maxUtilizationRatio;
        uint64 minInterestRate;
        uint64 maxInterestRate;
        uint64 targetInterestRate;
        uint128 maxRebate;
        uint128 rebateRate;
    }

    constructor(
        Params memory params
    ) {
        cdm = params.cdm;
        oracle = params.oracle;
        buffer = params.buffer;
        token = params.token;
        tokenScale = IERC20Metadata(address(params.token)).decimals();
        protocolFee = params.protocolFee;

        unwinderFactory = params.unwinderFactory;

        utilizationParams =
            uint256(params.targetUtilizationRatio) | (uint256(params.maxUtilizationRatio) << 64) | (uint256(params.minInterestRate - WAD) << 128) |
            (uint256(params.maxInterestRate - WAD) << 168) | (uint256(params.targetInterestRate - WAD) << 208);

        rebateParams = uint256(params.rebateRate) | (uint256(params.maxRebate) << 128);
    }

    function getConstants() view external returns (
        ICDM cdm_,
        IOracle oracle_,
        IBuffer buffer_,
        IERC20 token_,
        uint256 tokenScale_,
        uint256 protocolFee_,
        uint256 utilizationParams_,
        uint256 rebateParams_
    ) {
        return (
            cdm,
            oracle,
            buffer,
            token,
            tokenScale,
            protocolFee,
            utilizationParams,
            rebateParams
        );
    }

    function creditWithholder() external returns (address) {
        return address(new CreditWithholder(cdm, address(unwinderFactory), msg.sender));
    } 

    function create() external returns(CDPVaultWrapper vault) {
        vault = new CDPVaultWrapper(address(this));
        vault.setUp();
        vault.setUnwinderFactory(unwinderFactory);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender);
    }
}

contract PositionOwner {
    constructor(IPermission vault) {
        // Allow deployer to modify Position
        vault.modifyPermission(msg.sender, true);
    }
}

contract CreditDelegator {

    ICDM internal cdm;

    constructor(ICDM cdm_) {
        cdm = cdm_;
    }

    function delegateCredit(ICDPVault_TypeBBase vault, uint256 creditAmount) public {
        cdm.modifyPermission(address(vault), true);
        vault.delegateCredit(creditAmount);
    }

    function undelegateCredit(
        ICDPVault_TypeBBase vault, uint256 shareAmount, uint256[] memory prevQueuedEpochs
    ) external returns (
        uint256 estimatedClaim, uint256 currentEpoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
    ) {
        return vault.undelegateCredit(shareAmount, prevQueuedEpochs);
    }

    function claimUndelegatedCredit(ICDPVault_TypeBBase vault, uint256 epoch) public returns (uint256) {
        return vault.claimUndelegatedCredit(epoch);
    }
}

contract CDPVaultTest is TestBase {
    
    uint256 constant internal BASE_RATE_1_0 = 1 ether; // 0% base rate
    uint256 constant internal BASE_RATE_1_005 = 1000000000157721789; // 0.5% base rate
    uint256 constant internal BASE_RATE_1_025 = 1000000000780858271; // 2.5% base rate

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createVaultWrapper(
        uint256 protocolFee,
        uint64 targetUtilizationRatio,
        uint64 minInterestRate,
        uint64 maxInterestRate,
        uint64 targetInterestRate,
        uint128 maxRebate,
        uint128 rebateRate,
        uint256 baseRate,
        uint256 liquidationRatio

    ) private returns (CDPVaultWrapper vault){
        VaultWrapperFactory factory = new VaultWrapperFactory(VaultWrapperFactory.Params({
            cdm: cdm,
            oracle: oracle,
            buffer: buffer,
            token: token,
            unwinderFactory: address(cdpVaultUnwinderFactory),
            protocolFee: protocolFee,
            targetUtilizationRatio: targetUtilizationRatio,
            maxUtilizationRatio: uint64(WAD),
            minInterestRate: minInterestRate,
            maxInterestRate: maxInterestRate,
            targetInterestRate: targetInterestRate,
            maxRebate: maxRebate,
            rebateRate: rebateRate
        }));

        vault = factory.create();
        vault.grantRole(VAULT_CONFIG_ROLE, address(this));

        vault.setParameter("baseRate", baseRate);
        vault.setParameter("liquidationRatio", liquidationRatio);
    }

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

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_enteredEmergencyMode() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 0,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
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

    function test_enteredEmergencyMode() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 0,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
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
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 0,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether
        });

        vault.grantRole(TICK_MANAGER_ROLE, address(this));
        vault.setParameter("limitOrderFloor", 10 ether);

        // delegate credit
        createCredit(address(this), 100 ether);
        cdm.modifyPermission(address(vault), true);
        vault.delegateCredit(100 ether);

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

    function test_checkLimitOrder_removesOrderBelowFloor() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 0,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: uint256(uint64(BASE_RATE_1_025)),
            liquidationRatio : 1.25 ether
        });

        vault.grantRole(TICK_MANAGER_ROLE, address(this));
        vault.setParameter("limitOrderFloor", 30 ether);

        // delegate credit
        createCredit(address(this), 100 ether);
        cdm.modifyPermission(address(vault), true);
        vault.delegateCredit(100 ether);

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
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 0,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
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

    function test_calculateAssetsAndLiabilities() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 0,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: WAD,
            liquidationRatio: 1.25 ether
        });
        
        createCredit(address(this), 100 ether);
        cdm.modifyPermission(address(vault), true);
        vault.delegateCredit(100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 75 ether);

        (
            uint256 assets, 
            uint256 liabilities, 
            uint256 credit, 
            uint256 creditLine
        ) = vault.calculateAssetsAndLiabilities(0);

        assertEq(assets, 100 ether);
        assertEq(liabilities, 0);
        assertEq(credit, 25 ether);
        assertEq(creditLine, 25 ether);
    }

    function test_calculateAssetsAndLiabilities_revertsOnInsufficientAssets() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 2.1 ether,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: 1000000021919499726,
            liquidationRatio : WAD
        });

        createCredit(address(this), 100 ether);
        cdm.modifyPermission(address(vault), true);
        vault.delegateCredit(100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 100 ether);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__calculateAssetsAndLiabilities_insufficientAssets.selector);
        vault.calculateAssetsAndLiabilities(0);
    }

    function test_calculateRateAccumulator_staticRate(uint64 baseRate) public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 2.1 ether,
            targetUtilizationRatio: 0,
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: WAD,
            liquidationRatio: 1.25 ether 
        });

        vm.warp(block.timestamp + 30 days);

        uint64 maxBaseRate = 1000000021919499726;
        // bound the baseRate between 0 and maxBaseRate
        baseRate = uint64(bound(baseRate, WAD, maxBaseRate));

        vault.setParameter("baseRate", baseRate);
        InterestRateModel.GlobalIRS memory globalIRS = vault.getGlobalIRS();

        uint64 expectedValue = uint64(wmul(
            globalIRS.rateAccumulator,
            wpow(uint256(baseRate), (block.timestamp - globalIRS.lastUpdated), WAD)
        ));

        uint64 rateAccumulator = vault.calculateRateAccumulator(globalIRS);

        assertEq(rateAccumulator, expectedValue);
    }

    function test_calculateRateAccumulator_utilizationBasedRate_belowTarget() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 2.1 ether,
            targetUtilizationRatio: uint64(WAD/2),
            minInterestRate: 1000000007056502735, 
            maxInterestRate: 1000000021919499726,
            targetInterestRate: 1000000015353288160,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: WAD,
            liquidationRatio: 1.25 ether 
        });

        vm.warp(block.timestamp + 30 days);

        // bound the baseRate between 0 and maxBaseRate
        uint64 baseRate = type(uint64).max;

        vault.setParameter("baseRate", baseRate);
        InterestRateModel.GlobalIRS memory globalIRS = vault.getGlobalIRS();

        // get the utilization based interest rate
        uint64 interestRate = _calculateUtilizationBasedInterestRate({
            vault: CDPVault_TypeB(address(vault)), 
            globalIRS: globalIRS, 
            targetUtilizationRatio: uint64(WAD/2),
            minInterestRate: 1000000007056502735, 
            maxInterestRate: 1000000021919499726,
            targetInterestRate: 1000000015353288160
        });

        uint64 expectedValue = uint64(wmul(
            globalIRS.rateAccumulator,
            wpow(uint256(interestRate), (block.timestamp - globalIRS.lastUpdated), WAD)
        ));

        uint64 rateAccumulator = vault.calculateRateAccumulator(globalIRS);
        assertEq(rateAccumulator, expectedValue);
    }

    function test_calculateRateAccumulator_utilizationBasedRate_aboveTarget() public {
        CDPVaultWrapper vault = _createVaultWrapper({
            protocolFee: 2.1 ether,
            targetUtilizationRatio: 0.25 ether,
            minInterestRate: 1000000007056502735, 
            maxInterestRate: 1000000021919499726,
            targetInterestRate: 1000000015353288160,
            maxRebate: uint128(WAD),
            rebateRate: 0,
            baseRate: WAD,
            liquidationRatio: 1 ether 
        });

        // bound the baseRate between 0 and maxBaseRate
        uint64 baseRate = type(uint64).max;
        vault.setParameter("baseRate", baseRate);
        
        // setup vault permissions in CDM
        cdm.modifyPermission(address(vault), true);
        cdm.setParameter(address(vault), "debtCeiling", 200 ether);

        // delegate credit to vault
        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

        // create position
        token.mint(address(this), 200 ether);
        token.approve(address(vault), 200 ether);
        vault.deposit(address(this), 200 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 200 ether, 150 ether);

        vm.warp(block.timestamp + 30 days);
        InterestRateModel.GlobalIRS memory globalIRS = vault.getGlobalIRS();

        // get the utilization based interest rate
        uint64 interestRate = _calculateUtilizationBasedInterestRate({
            vault: CDPVault_TypeB(address(vault)), 
            globalIRS: globalIRS, 
            targetUtilizationRatio: 0.25 ether,
            minInterestRate: 1000000007056502735, 
            maxInterestRate: 1000000021919499726,
            targetInterestRate: 1000000015353288160
        });

        uint64 expectedValue = uint64(wmul(
            globalIRS.rateAccumulator,
            wpow(uint256(interestRate), (block.timestamp - globalIRS.lastUpdated), WAD)
        ));

        uint64 rateAccumulator = vault.calculateRateAccumulator(globalIRS);
        assertEq(rateAccumulator, expectedValue);
    }


    function test_claimUndelegatedCredit_simple_delegateFirst() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // obtain additional credit to repay interest
        createCredit(address(this), 100 ether);

        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(this)), 100 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = vault.undelegateCredit(vault.shares(address(this)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(this)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertEq(totalCreditWithheld, 100 ether);

        vm.expectRevert();
        vault.claimUndelegatedCredit(epoch);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * vault.EPOCH_FIX_DELAY());
        uint256 creditAmount = vault.claimUndelegatedCredit(epoch);
        assertEq(creditAmount, 100 ether);
        assertEq(credit(address(this)), 100 ether);
        assertEq(vault.shares(address(this)), 0);
    }

    function test_claimUndelegatedCredit_multiple() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        CreditDelegator delegatorA = new CreditDelegator(cdm);
        createCredit(address(delegatorA), 100 ether);
        delegatorA.delegateCredit(vault, 100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(delegatorA)), 100 ether);

        CreditDelegator delegatorB = new CreditDelegator(cdm);
        createCredit(address(delegatorB), 50 ether);
        delegatorB.delegateCredit(vault, 50 ether);
        assertEq(credit(address(vault)), 150 ether);
        assertEq(vault.shares(address(delegatorB)), 50 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = delegatorA.undelegateCredit(vault, vault.shares(address(delegatorA)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(delegatorA)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertEq(totalCreditWithheld, 100 ether);

        (
            , epoch, claimableAtEpoch, fixableUntilEpoch
        ) = delegatorB.undelegateCredit(vault, vault.shares(address(delegatorB)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(delegatorB)), 50 ether);
        (, totalCreditWithheld, totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 150 ether);
        assertEq(totalCreditWithheld, 150 ether);

        vm.expectRevert();
        vault.claimUndelegatedCredit(epoch);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * vault.EPOCH_FIX_DELAY());
        uint256 creditAmountA = delegatorA.claimUndelegatedCredit(vault, epoch);
        assertEq(creditAmountA, 100 ether);
        assertEq(credit(address(delegatorA)), 100 ether);
        assertEq(vault.shares(address(delegatorA)), 0);
        
        vm.warp(block.timestamp + vault.EPOCH_DURATION() * 4);
        uint256 creditAmountB = delegatorB.claimUndelegatedCredit(vault, epoch);
        assertEq(creditAmountB, 50 ether);
        assertEq(credit(address(delegatorB)), 50 ether);
        assertEq(vault.shares(address(delegatorA)), 0);
    }

    function test_claimUndelegatedCredit_multiple_staleEpoch() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);
        CreditDelegator delegatorA = new CreditDelegator(cdm);
        uint256 startingCredit = 100 ether;

        createCredit(address(delegatorA), startingCredit);
        delegatorA.delegateCredit(vault, startingCredit);
        assertEq(credit(address(vault)), startingCredit);
        assertEq(vault.shares(address(delegatorA)), startingCredit);

        // undelegate half the shares but let the epoch become stale
        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = delegatorA.undelegateCredit(vault, startingCredit / 2, new uint256[](0));

        // pass time so the epoch becomes stale
        vm.warp(block.timestamp + vault.EPOCH_DURATION() * 4);
        uint256[] memory epochs = new uint256[](4);
        for( uint offset = 0; offset < 4; ++offset){
            epochs[offset] = epoch + offset;
        }

        // undelegate again but for the full amount (starting credit)
        // the first undelegate should be unqueued
        (
            , epoch, claimableAtEpoch, fixableUntilEpoch
        ) = delegatorA.undelegateCredit(vault, startingCredit, epochs);

        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(delegatorA)), startingCredit);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, startingCredit);
        assertEq(totalCreditWithheld,startingCredit);
    }

    function test_claimUndelegatedCredit_simple_borrowFirst() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        // obtain additional credit to delegate
        createCredit(address(this), 50 ether);
        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 50 ether); // 50 Credit are filling the 50 Debt in the CDM
        assertEq(vault.shares(address(this)), 100 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = vault.undelegateCredit(vault.shares(address(this)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(this)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,, uint256 estimatedCreditClaimPerShare) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertGe(totalCreditWithheld, 100 ether);
        assertEq(estimatedCreditClaimPerShare, 1 ether); // no interest has accrued yet

        vm.expectRevert();
        vault.claimUndelegatedCredit(epoch);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * vault.EPOCH_FIX_DELAY());
        uint256 creditAmount = vault.claimUndelegatedCredit(epoch);
        assertEq(creditAmount, 100 ether); // does not include the accrued interest
        assertEq(credit(address(this)), 100 ether);
        assertEq(vault.shares(address(this)), 0);
    }

    function test_claimUndelegatedCredit_fixTimeout() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // obtain additional credit to repay interest
        createCredit(address(this), 100 ether);

        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(this)), 100 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = vault.undelegateCredit(vault.shares(address(this)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(this)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertEq(totalCreditWithheld, 100 ether);

        uint256 snapshot = vm.snapshot();

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * (vault.EPOCH_FIX_TIMEOUT()));
        assertEq(vault.claimUndelegatedCredit(epoch), 100 ether);

        vm.revertTo(snapshot);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * (vault.EPOCH_FIX_TIMEOUT() + 1));
        vm.expectRevert(CDPVault_TypeB.CDPVault_TypeB__claimUndelegatedCredit_epochNotFixed.selector);
        vault.claimUndelegatedCredit(epoch);
    }

    function test_claimUndelegatedCredit_noLiquidity() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // obtain additional credit to repay interest
        createCredit(address(this), 100 ether);

        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(this)), 100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = vault.undelegateCredit(vault.shares(address(this)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(this)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertEq(totalCreditWithheld, 50 ether);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * vault.EPOCH_FIX_DELAY());
        uint256 creditAmount = vault.claimUndelegatedCredit(epoch);
        assertEq(creditAmount, 50 ether);
        assertEq(credit(address(this)), 50 ether + 50 ether); // 50 ether undelegated + 50 ether borrowed
        assertEq(vault.shares(address(this)), 50 ether);
    }

    function test_claimUndelegatedCredit_loss() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // obtain additional credit to repay interest
        createCredit(address(this), 100 ether);

        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(this)), 100 ether);

        vm.prank(address(vault));
        cdm.modifyBalance(address(vault), address(0), 50 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = vault.undelegateCredit(vault.shares(address(this)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(this)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertEq(totalCreditWithheld, 50 ether);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * vault.EPOCH_FIX_DELAY());
        uint256 creditAmount = vault.claimUndelegatedCredit(epoch);
        assertEq(creditAmount, 50 ether);
        assertEq(credit(address(this)), 50 ether);
        assertEq(vault.shares(address(this)), 0);
    }

    function test_claimUndelegatedCredit_advancement() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 50 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // obtain additional credit to repay interest
        createCredit(address(this), 100 ether);

        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(this)), 100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        (
            , uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
        ) = vault.undelegateCredit(vault.shares(address(this)), new uint256[](0));
        assertEq(epoch < claimableAtEpoch && claimableAtEpoch < fixableUntilEpoch, true);
        assertEq(vault.sharesQueuedByEpoch(epoch, address(this)), 100 ether);
        (, uint256 totalCreditWithheld, uint256 totalSharesQueued,,) = vault.epochs(epoch);
        assertEq(totalSharesQueued, 100 ether);
        assertEq(totalCreditWithheld, 100 ether);

        vm.warp(block.timestamp + vault.EPOCH_DURATION() * vault.EPOCH_FIX_DELAY());
        uint256 creditAmount = vault.claimUndelegatedCredit(epoch);
        assertEq(creditAmount, 100 ether);
        assertEq(credit(address(this)), 100 ether + 50 ether); // 100 ether undelegated + 50 ether borrowed
        assertEq(vault.shares(address(this)), 0);
    }

    function test_claimFees() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 1.05 ether, 0);

        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);
        assertEq(credit(address(vault)), 100 ether);
        assertEq(vault.shares(address(this)), 100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        vm.warp(block.timestamp + 60 days);

        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 0, -40 ether);

        // fees are sent to the buffer
        uint256 feesClaimed = vault.claimFees();
        (int256 balance, ) = cdm.accounts(address(buffer));

        assertGt(feesClaimed, 0);
        assertEq(feesClaimed, uint256(balance));
    }

    function test_modifyCollateralAndDebt_depositCollateral() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 10 ether, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 0);
    }

    function test_modifyCollateralAndDebt_createDebt() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 10 ether, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 0);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 0, 50 ether);
    }

    function test_modifyCollateralAndDebt_depositCollateralAndDrawDebt() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 80 ether);
    }

    function test_modifyCollateralAndDebt_emptyCall() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);
        address position = address(new PositionOwner(vault));
        vault.modifyCollateralAndDebt(position, address(this), address(this), 0, 0);

    }

    function test_modifyCollateralAndDebt_repayPositionAndWidthdraw() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vm.expectRevert (CDPVault.CDPVault__modifyCollateralAndDebt_notSafe.selector);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 100 ether);
    }

    function test_modifyCollateralAndDebt_revertsOnDebtFloor() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 10 ether, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vm.expectRevert(CDPVault.CDPVault__modifyPosition_debtFloor.selector);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 5 ether);
    }

    function test_modifyCollateralAndDebt_revertsOnMaxUtilizationRatio() public {
        uint256 debtCeiling = 100 ether;
        CDPVaultConstants memory vaultParams = _getDefaultVaultParams();
        vaultParams.maxUtilizationRatio = 0.80 ether;

        CDPVault_TypeBConfig memory vaultParams_TypeB = _getDefaultVaultParams_TypeB();
        vaultParams_TypeB.targetHealthFactor = 1.15 ether;

        CDPVaultConfig memory vaultConfigs = _getDefaultVaultConfigs();
        vaultConfigs.liquidationRatio = 1.15 ether;
        vaultConfigs.globalLiquidationRatio = 1.15 ether;
        
        CDPVault_TypeB vault = createCDPVault_TypeB(
            vaultParams,
            vaultParams_TypeB,
            vaultConfigs,
            debtCeiling              
        );

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vm.expectRevert(CDPVault.CDPVault__modifyCollateralAndDebt_maxUtilizationRatio.selector);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 81 ether);
    }

    function test_modifyCollateralAndDebt_utilizationRatio_scenario() public {
        uint256 debtCeiling = 100 ether;
        CDPVaultConstants memory vaultParams = _getDefaultVaultParams();
        vaultParams.maxUtilizationRatio = 0.80 ether;

        CDPVault_TypeBConfig memory vaultParams_TypeB = _getDefaultVaultParams_TypeB();
        vaultParams_TypeB.targetHealthFactor = 1.15 ether;

        CDPVaultConfig memory vaultConfigs = _getDefaultVaultConfigs();
        vaultConfigs.liquidationRatio = 1.15 ether;
        vaultConfigs.globalLiquidationRatio = 1.15 ether;
        
        CDPVault_TypeB vault = createCDPVault_TypeB(
            vaultParams,
            vaultParams_TypeB,
            vaultConfigs,
            debtCeiling              
        );

        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        assertEq(vault.cash(address(this)), 100 ether);
        address position = address(new PositionOwner(vault));

        vault.modifyCollateralAndDebt(position, address(this), address(this), 100 ether, 40 ether);

        // update the debt ceiling
        cdm.setParameter(address(vault), "debtCeiling", 50 ether);

        // can`t increase debt because of the utilization ratio
        vm.expectRevert(CDPVault.CDPVault__modifyCollateralAndDebt_maxUtilizationRatio.selector);
        vault.modifyCollateralAndDebt(position, address(this), address(this), 0, 5 ether);

        // update the debt ceiling
        cdm.setParameter(address(vault), "debtCeiling", 30 ether);

        // can decrease debt event if max utilization is reached
        vault.modifyCollateralAndDebt(position, address(this), address(this), 0, -10 ether);
    }

    function test_addLimitPriceTick_addMultipleTicks() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
        vm.expectRevert(CDPVault.CDPVault__addLimitPriceTick_limitPriceTickOutOfRange.selector);
        vault.addLimitPriceTick(0, 0);

        vm.expectRevert(CDPVault.CDPVault__addLimitPriceTick_limitPriceTickOutOfRange.selector);
        vault.addLimitPriceTick(100 ether + 1, 0);
    }

    function test_addLimitPriceTick_revertsOnInvalidOrder() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
        vault.addLimitPriceTick(2 ether, 0);

        vm.expectRevert(CDPVault.CDPVault__addLimitPriceTick_invalidPriceTickOrder.selector);
        vault.addLimitPriceTick(2 ether, 1 ether);
    }

    function test_removeLimitPriceTick() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
        vault.addLimitPriceTick(WAD, 0);

        (uint priceTick, bool isActive) = vault.getPriceTick(0);

        assertEq(priceTick, WAD);
        assertTrue(isActive);
    }

    function test_getPriceTick_notFound() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
        vault.addLimitPriceTick(WAD, 0);

        (uint priceTick, bool isActive) = vault.getPriceTick(1);

        assertEq(priceTick, 0);
        assertTrue(isActive == false);
    }

    function test_createLimitOrder() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);

    }

    function test_createLimitOrder_priceTickNotActive() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        // create limit order
        vm.expectRevert(CDPVault.CDPVault__createLimitOrder_limitPriceTickNotActive.selector);
        vault.createLimitOrder(WAD);     
    }

    function test_createLimitOrder_revertsOnLimitOrderFloor() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        vault.setParameter("limitOrderFloor", 20 ether);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 15 ether);
        
        vault.addLimitPriceTick(WAD, 0);

        vm.expectRevert(CDPVault.CDPVault__createLimitOrder_limitOrderFloor.selector);
        vault.createLimitOrder(WAD);     
    }

    function test_createLimitOrder_revertsOnExistingLimitOrder() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
        vault.addLimitPriceTick(WAD, 0);

        vault.createLimitOrder(WAD);     

        // attempt to create the limit order again
        vm.expectRevert(CDPVault.CDPVault__createLimitOrder_limitOrderAlreadyExists.selector);
        vault.createLimitOrder(WAD);     
    }

    function test_getLimitOrder_returnsCorrectID() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        assertEq(
            0,
            vault.getLimitOrder(WAD,0)
        );
    }

    function test_getLimitOrder_multiple() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 200 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, 1.1 ether, BASE_RATE_1_0, 0, 0);

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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_005, 0, 0);

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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 150 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_005, 0, 0);

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
        
        // repay debt
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), -200 ether, -150 ether);
    }

    function test_non_reserve_interest() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_005, 0, 0);

        // delegate 100 credit to CDPVault
        createCredit(address(this), 100 ether);
        vault.delegateCredit(100 ether);

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

        // repay debt
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), -100 ether, -80 ether);
        assertEq(_virtualDebt(vault, address(this)), 0);
        assertGt(credit(address(vault)), 100 ether);
    }

    function test_exchange_simple_reserve() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);
        
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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 0, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

        // delegate 50 credit to CDPVault
        createCredit(address(this), 50 ether);
        vault.delegateCredit(50 ether);
        
        // create position
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(this), 100 ether);
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), 100 ether, 50 ether);

        // create limit order
        vault.addLimitPriceTick(WAD, 0);
        vault.createLimitOrder(WAD);
        assertEq(vault.cash(address(this)), 0);

        // exchange
        assertEq(credit(address(vault)), 0);
        vault.exchange(WAD, 50 ether);
        assertEq(credit(address(this)), 0);
        assertEq(credit(address(vault)), 50 ether);
        assertEq(vault.cash(address(this)), 50 ether);
    }

    function test_exchange_debtFloor() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 10 ether, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 0);

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

        uint256 id = vm.snapshot();
        
        // exchange all the debt (no dust)
        vault.exchange(WAD, 50 ether);
        assertEq(credit(address(this)), 0);
        assertEq(debt(address(vault)), 0);
        assertEq(credit(address(vault)), 0);
        assertEq(vault.cash(address(this)), 50 ether);

        // exchange reverts since debt floor amount had to be left behind
        vm.revertTo(id);
        vm.expectRevert(CDPVault.CDPVault__exchange_notEnoughExchanged.selector);
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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 200 ether, 40 ether, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, 1.1 ether, BASE_RATE_1_0, 0, 0);

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
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 110 ether, 1 ether, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, 1.1 ether, BASE_RATE_1_0, 0, 0);

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

        // exchange
        assertEq(debt(address(vault)), 58 ether);

        vault.exchange(1.01 ether, 50 ether);
        assertEq(credit(address(this)), 8 ether);
        assertEq(debt(address(vault)), 8 ether);
        assertEq(vault.cash(address(this)), wdiv(uint256(50 ether), wmul(uint256(1.01 ether), uint256(0.8 ether))));
        assertEq(credit(address(vault)), 0);

        assertEq(vault.limitOrders(uint160(positionA)), 1.0 ether);
        assertEq(vault.limitOrders(uint160(positionB)), 0);
    }
    
    function test_emergencyMode() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_0, 0, 1 ether);

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
        
        vm.expectRevert(CDPVault.CDPVault__checkEmergencyMode_entered.selector);
        vault.exchange(WAD, 1);

        vault.enterEmergencyMode();
    }

    function test_exchange_triggersEmergencyMode() public {
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);

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
        vm.expectRevert (CDPVault.CDPVault__checkEmergencyMode_entered.selector);
        vault.exchange(WAD, 30 ether);
    }

    function test_calculateNormalDebt() public {
        uint256 initialDebt = 50 ether;
        CDPVault_TypeB vault = createCDPVault_TypeB(token, 100 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 1 ether);

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

}
