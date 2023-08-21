// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ProxyAdmin} from "openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20PresetMinterPauser} from "openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICDM} from "../interfaces/ICDM.sol";
import {ICDPVault, ICDPVaultBase} from "../interfaces/ICDPVault.sol";
import {IFlashlender} from "../interfaces/IFlashlender.sol";
import {CDPVaultConstants, CDPVaultConfig, CDPVault_TypeAConfig} from "../interfaces/ICDPVault_TypeA_Factory.sol";

import {Stablecoin, MINTER_AND_BURNER_ROLE} from "../Stablecoin.sol";
import {CDM, getCredit, getDebt, getCreditLine, ACCOUNT_CONFIG_ROLE} from "../CDM.sol";
import {Minter} from "../Minter.sol";
import {Flashlender} from "../Flashlender.sol";
import {Buffer, BAIL_OUT_QUALIFIER_ROLE} from "../Buffer.sol";
import {CDPVault_TypeA} from "../CDPVault_TypeA.sol";
import {CDPVaultUnwinderFactory} from "../CDPVaultUnwinder.sol";
import {CDPVault_TypeA_Factory, CDPVault_TypeA_Deployer} from "../CDPVault_TypeA_Factory.sol";

import {MockOracle} from "./MockOracle.sol";

import {WAD, wdiv} from "../utils/Math.sol";
import {CDM} from "../CDM.sol";

contract CreditCreator {
    constructor(ICDM cdm) {
        cdm.modifyPermission(msg.sender, true);
    }
}

contract TestBase is Test {

    CDM internal cdm;
    Stablecoin internal stablecoin;
    Minter internal minter;
    Buffer internal buffer;

    CDPVaultUnwinderFactory internal cdpVaultUnwinderFactory;
    CDPVault_TypeA_Factory internal cdpVaultFactory;


    ProxyAdmin internal bufferProxyAdmin;

    IFlashlender internal flashlender;

    ERC20PresetMinterPauser internal token;
    MockOracle internal oracle;

    uint256[] internal timestamps;
    uint256 public currentTimestamp;

    uint256 internal constant initialGlobalDebtCeiling = 100_000_000_000 ether;

    CreditCreator private creditCreator;

    struct CDPAccessParams {
        address roleAdmin;
        address vaultAdmin;
        address tickManager;
        address pauseAdmin;
        address vaultUnwinder;
    }

    modifier useCurrentTimestamp() virtual {
        vm.warp(currentTimestamp);
        _;
    }

    function createAccounts() internal virtual {}

    function createAssets() internal virtual {
        token = new ERC20PresetMinterPauser("TestToken", "TST");
    }

    function createOracles() internal virtual {
        oracle = new MockOracle();
        setOraclePrice(WAD);
    }

    function createCore() internal virtual {
        cdm = new CDM(address(this), address(this), address(this));
        setGlobalDebtCeiling(initialGlobalDebtCeiling);
        stablecoin = new Stablecoin();
        minter = new Minter(cdm, stablecoin, address(this), address(this));
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(minter));
        flashlender = new Flashlender(minter, 0);
        cdm.setParameter(address(flashlender), "debtCeiling", uint256(type(int256).max));
        bufferProxyAdmin = new ProxyAdmin();
        buffer = Buffer(address(new TransparentUpgradeableProxy(
            address(new Buffer(cdm)),
            address(bufferProxyAdmin),
            abi.encodeWithSelector(Buffer.initialize.selector, address(this), address(this))
        )));
        cdm.setParameter(address(buffer), "debtCeiling", initialGlobalDebtCeiling);

        // create an unbound credit line to use for testing        
        creditCreator = new CreditCreator(cdm);
        cdm.setParameter(address(creditCreator), "debtCeiling", uint256(type(int256).max));
    }

    function createFactories() internal virtual {
        cdpVaultUnwinderFactory = new CDPVaultUnwinderFactory();
        cdpVaultFactory = new CDPVault_TypeA_Factory(
            new CDPVault_TypeA_Deployer(),
            address(cdpVaultUnwinderFactory),
            address(this),
            address(this),
            address(this)
        );
        cdm.grantRole(ACCOUNT_CONFIG_ROLE, address(cdpVaultFactory));
    }

    // includes protocolFee
    function createCDPVault_TypeA(
        IERC20 token_,
        uint256 debtCeiling,
        uint128 debtFloor,
        uint64 liquidationRatio,
        uint64 liquidationPenalty,
        uint64 liquidationDiscount,
        uint64 targetHealthFactor,
        uint256 rebateRate,
        uint256 maxRebate,
        uint256 baseRate,
        uint256 protocolFee,
        uint64 globalLiquidationRatio
    ) internal returns (CDPVault_TypeA) {
        return createCDPVault_TypeA(
            CDPVaultConstants({
                cdm: cdm,
                oracle: oracle,
                buffer: buffer,
                token: token_,
                tokenScale: 10**IERC20Metadata(address(token_)).decimals(),
                protocolFee: protocolFee,
                targetUtilizationRatio: 0,
                maxUtilizationRatio: uint64(WAD),
                minInterestRate: uint64(WAD),
                maxInterestRate: uint64(1000000021919499726),
                targetInterestRate: uint64(1000000015353288160),
                rebateRate: uint128(rebateRate),
                maxRebate: uint128(maxRebate)
            }),
            CDPVault_TypeAConfig({
                liquidationPenalty: liquidationPenalty,
                liquidationDiscount: liquidationDiscount,
                targetHealthFactor: targetHealthFactor
            }),
            CDPVaultConfig({
                debtFloor: debtFloor,
                limitOrderFloor: WAD,
                liquidationRatio: liquidationRatio,
                globalLiquidationRatio: globalLiquidationRatio,
                baseRate: baseRate,
                roleAdmin: address(this),
                vaultAdmin: address(this),
                tickManager: address(this),
                vaultUnwinder: address(this),
                pauseAdmin: address(this)
            }),
            debtCeiling
        );
    }

    function createCDPVault_TypeA(
        CDPVaultConstants memory params,
        CDPVault_TypeAConfig memory paramsTypeA,
        CDPVaultConfig memory configs,
        uint256 debtCeiling
    ) internal returns (CDPVault_TypeA vault) {
        vault = CDPVault_TypeA(
            cdpVaultFactory.create(
                params,
                paramsTypeA,
                configs,
                debtCeiling
            )
        );

        cdm.modifyPermission(address(vault), true);
        buffer.grantRole(BAIL_OUT_QUALIFIER_ROLE, address(vault));

        (int256 balance, uint256 debtCeiling_) = cdm.accounts(address(vault));
        assertEq(balance, 0);
        assertEq(debtCeiling_, debtCeiling);

        vm.label({account: address(vault), newLabel: "CDPVault_TypeA"});
    }

    function labelContracts() internal virtual {
        vm.label({account: address(cdm), newLabel: "CDM"});
        vm.label({account: address(stablecoin), newLabel: "Stablecoin"});
        vm.label({account: address(minter), newLabel: "Minter"});
        vm.label({account: address(flashlender), newLabel: "Flashlender"});
        vm.label({account: address(buffer), newLabel: "Buffer"});
        vm.label({account: address(cdpVaultUnwinderFactory), newLabel: "CDPVaultUnwinderFactory"});
        vm.label({account: address(token), newLabel: "CollateralToken"});
        vm.label({account: address(oracle), newLabel: "Oracle"});
    }

    function setCurrentTimestamp(uint256 currentTimestamp_) public {
        timestamps.push(currentTimestamp_);
        currentTimestamp = currentTimestamp_;
    }

    function setGlobalDebtCeiling(uint256 _globalDebtCeiling) public {
        cdm.setParameter("globalDebtCeiling", _globalDebtCeiling);
    }

    function setOraclePrice(uint256 price) public {
        oracle.updateSpot(address(token), price);
    }

    function createCredit(address to, uint256 amount) public {
        cdm.modifyBalance(address(creditCreator), to, amount);
    }

    function credit(address account) internal view returns (uint256) {
        (int256 balance,) = cdm.accounts(account);
        return getCredit(balance);
    }

    function debt(address account) internal view returns (uint256) {
        (int256 balance,) = cdm.accounts(account);
        return getDebt(balance);
    }

    function creditLine(address account) internal view returns (uint256) {
        (int256 balance, uint256 debtCeiling) = cdm.accounts(account);
        return getCreditLine(balance, debtCeiling);
    }

    function liquidationPrice(ICDPVaultBase vault_) internal returns (uint256) {
        (, uint64 liquidationRatio_,) = vault_.vaultConfig();
        return wdiv(vault_.spotPrice(), uint256(liquidationRatio_));
    }

    function logLimitOrders(ICDPVault vault) internal view {
        for (uint256 i = 0; i < 100; i++) {
            (uint256 priceTick, bool isActive) = vault.getPriceTick(i);
            if (priceTick == 0) break; 
            console.log("%s: %d (%s)", "Price Tick", priceTick, (isActive) ? "Active" : "Inactive");
            for (uint256 j = 0; j < 100; j++) {
                uint256 limitOrderId = vault.getLimitOrder(priceTick, j);
                if (limitOrderId == 0) break;
                console.log("  %s: %s", "LimitOrderId", address(uint160(limitOrderId)));
            }
        }
    }

    function _getDefaultVaultParams() internal view returns (CDPVaultConstants memory) {
        return CDPVaultConstants({
            cdm: cdm,
            oracle: oracle,
            buffer: buffer,
            token: token,
            tokenScale: 10**IERC20Metadata(address(token)).decimals(),
            protocolFee: 0,
            targetUtilizationRatio: 0,
            maxUtilizationRatio: uint64(WAD),
            minInterestRate: uint64(WAD),
            maxInterestRate: uint64(1000000021919499726),
            targetInterestRate: uint64(1000000015353288160),
            rebateRate: 0,
            maxRebate: uint128(WAD)
        });
    }

    function _getDefaultVaultParams_TypeA() internal pure returns (CDPVault_TypeAConfig memory) {
        return CDPVault_TypeAConfig({
            liquidationPenalty: uint64(WAD),
            liquidationDiscount: uint64(WAD),
            targetHealthFactor: 1.25 ether
        });
    }

    function _getDefaultVaultConfigs() internal view returns (CDPVaultConfig memory) {
        return CDPVaultConfig({
            debtFloor: 0,
            limitOrderFloor: WAD,
            liquidationRatio: 1.25 ether,
            globalLiquidationRatio: 1.25 ether,
            baseRate: WAD,
            roleAdmin: address(this),
            vaultAdmin: address(this),
            tickManager: address(this),
            vaultUnwinder: address(this),
            pauseAdmin: address(this)
        });
    }

    function setUp() public virtual {
        setCurrentTimestamp(block.timestamp);

        createAccounts();
        createAssets();
        createOracles();
        createCore();
        createFactories();
        labelContracts();
    }

    function getContracts() public view returns (address[] memory contracts) {
        contracts = new address[](7);
        contracts[0] = address(cdm);
        contracts[1] = address(stablecoin);
        contracts[2] = address(minter);
        contracts[3] = address(buffer);
        contracts[4] = address(cdpVaultUnwinderFactory);
        contracts[5] = address(flashlender);
        contracts[6] = address(token);
    }
}
