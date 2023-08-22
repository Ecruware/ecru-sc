// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "openzeppelin/contracts/utils/Strings.sol";

import {CDPVaultConstants, CDPVaultConfig, CDPVault_TypeAConfig} from "../../interfaces/ICDPVault_TypeA_Factory.sol";

import {CDM, ACCOUNT_CONFIG_ROLE} from "../../CDM.sol";
import {Buffer} from "../../Buffer.sol";
import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";
import {CDPVault_TypeA_Factory, CDPVault_TypeA_Deployer, DEPLOYER_ROLE} from "../../CDPVault_TypeA_Factory.sol";
import {CDPVaultUnwinderFactory} from "../../CDPVaultUnwinder.sol";
import {WAD} from "../../utils/Math.sol";

contract CDPVault_TypeA_FactoryTest is TestBase {

    CDPVault_TypeA_Factory factory;
    CDPVault_TypeA_Deployer deployer;
    CDPVaultUnwinderFactory unwinderFactory;

    // roles
    address factoryRoleAdmin = makeAddr("factoryRoleAdmin");
    address deployerAdmin = makeAddr("deployer");
    address pauserAdmin = makeAddr("pauser");

    // cdpvault params
    address roleAdmin = makeAddr("roleAdmin");
    address vaultAdmin = makeAddr("vaultAdmin");
    address tickManager = makeAddr("tickManager");
    address pauseAdmin = makeAddr("pauseAdmin");
    address vaultUnwinder = makeAddr("vaultUnwinder");

    uint64 protocolFee = 1;
    uint64 liquidationPenalty = 1.0 ether;
    uint64 liquidationDiscount = 1.05 ether;
    uint64 targetHealthFactor = 1.05 ether;
    uint256 baseRate = WAD;
    uint128 rebateRate = uint128(25 * WAD);
    uint128 maxRebate = uint128(WAD);
    uint256 tokenScale;

    // utilization rate params
    uint64 targetUtilizationRatio = uint64(WAD/2);
    uint64 maxUtilizationRatio = uint64(WAD);
    uint64 minInterestRate = uint64(1000000007056502735);
    uint64 maxInterestRate = uint64(1000000021919499726);
    uint64 targetInterestRate = uint64(1000000015353288160);

    // vault config
    uint128 debtFloor = 100 ether;
    uint256 limitOrderFloor = 100 ether;
    uint64 liquidationRatio = 1.25 ether;
    uint64 globalLiquidationRatio = 1.25 ether;

    function setUp() public override {
        super.setUp();
        unwinderFactory = new CDPVaultUnwinderFactory();
        deployer = new CDPVault_TypeA_Deployer();
        factory = new CDPVault_TypeA_Factory(
            deployer,
            factoryRoleAdmin,
            deployerAdmin,
            pauserAdmin
        );
        tokenScale = 10**IERC20Metadata(token).decimals();

        cdm.grantRole(ACCOUNT_CONFIG_ROLE, address(factory));
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _checkParams(CDPVault_TypeA vault) internal {
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(address(vault.cdm()), address(cdm));
        assertEq(address(vault.buffer()), address(buffer));
        assertEq(address(vault.token()), address(token));

        assertEq(vault.protocolFee(), protocolFee);

        assertEq(vault.limitOrderFloor(), limitOrderFloor);

        // config
        {   
            (uint128 _debtFloor, uint64 _liquidationRatio, uint64 _globalLiquidationRatio) = vault.vaultConfig();
            assertEq(_debtFloor, debtFloor);
            assertEq(_liquidationRatio, liquidationRatio);
            assertEq(_globalLiquidationRatio, globalLiquidationRatio);
        }

        // liquidation config
        {
            (
                uint64 _liquidationPenalty,
                uint64 _liquidationDiscount,
                uint64 _targetHealthFactor
            ) = vault.liquidationConfig();
            assertEq(_liquidationPenalty, liquidationPenalty);
            assertEq(_liquidationDiscount, liquidationDiscount);
            assertEq(_targetHealthFactor, targetHealthFactor);
        }

        // base rate
        InterestRateModel.GlobalIRS memory irs = vault.getGlobalIRS();
        assertEq(irs.baseRate, int256(baseRate));

        // roles
        assertTrue(vault.hasRole(0x00, roleAdmin));
        assertTrue(vault.hasRole(keccak256("VAULT_CONFIG_ROLE"), vaultAdmin));
        assertTrue(vault.hasRole(keccak256("TICK_MANAGER_ROLE"), tickManager));
        assertTrue(vault.hasRole(keccak256("PAUSER_ROLE"), pauseAdmin));
        assertTrue(vault.hasRole(keccak256("VAULT_UNWINDER_ROLE"), vaultUnwinder));
    }

    function _getOnlyRoleRevertMsg(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_create_reserve_vault() public {
        vm.startPrank(deployerAdmin);
        CDPVault_TypeA vault = CDPVault_TypeA(
            factory.create(
                CDPVaultConstants({
                    cdm: cdm,
                    oracle: oracle,
                    buffer: buffer,
                    token: token,
                    tokenScale: tokenScale,
                    protocolFee: protocolFee,
                    targetUtilizationRatio: targetUtilizationRatio,
                    maxUtilizationRatio: maxUtilizationRatio,
                    minInterestRate: minInterestRate,
                    maxInterestRate: maxInterestRate,
                    targetInterestRate: targetInterestRate,
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
                    limitOrderFloor: limitOrderFloor,
                    liquidationRatio: liquidationRatio,
                    globalLiquidationRatio: globalLiquidationRatio,
                    baseRate: baseRate,
                    roleAdmin: roleAdmin,
                    vaultAdmin: vaultAdmin,
                    tickManager: tickManager,
                    pauseAdmin: pauseAdmin
                }),
                100 ether
            )
        );
        vm.stopPrank();

        (uint256 rateAccumulator,,) = vault.virtualIRS(address(0));
        assertEq(rateAccumulator, WAD);

        vm.warp(block.timestamp + 365 days);
        (rateAccumulator,,) = vault.virtualIRS(address(0));
        assertEq(rateAccumulator, WAD);

        _checkParams(vault);
    }

    function test_fail_create_invalid_role() public {
        vm.expectRevert(_getOnlyRoleRevertMsg(address(this), keccak256("DEPLOYER_ROLE")));
        factory.create(
            CDPVaultConstants({
                cdm: cdm,
                oracle: oracle,
                buffer: buffer,
                token: token,
                tokenScale: tokenScale,
                protocolFee: protocolFee,
                targetUtilizationRatio: targetUtilizationRatio,
                maxUtilizationRatio: maxUtilizationRatio,
                minInterestRate: minInterestRate,
                maxInterestRate: maxInterestRate,
                targetInterestRate: targetInterestRate,
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
                limitOrderFloor: limitOrderFloor,
                liquidationRatio: liquidationRatio,
                globalLiquidationRatio: globalLiquidationRatio,
                baseRate: baseRate,
                roleAdmin: roleAdmin,
                vaultAdmin: vaultAdmin,
                tickManager: tickManager,
                pauseAdmin: pauseAdmin
            }),
            100 ether
        );
    }

    function test_create_non_reserve() public {
        CDPVault_TypeA vault = CDPVault_TypeA(
            factory.create(
                CDPVaultConstants({
                    cdm: cdm,
                    oracle: oracle,
                    buffer: buffer,
                    token: token,
                    tokenScale: tokenScale,
                    protocolFee: protocolFee,
                    targetUtilizationRatio: targetUtilizationRatio,
                    maxUtilizationRatio: maxUtilizationRatio,
                    minInterestRate: minInterestRate,
                    maxInterestRate: maxInterestRate,
                    targetInterestRate: targetInterestRate,
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
                    limitOrderFloor: limitOrderFloor,
                    liquidationRatio: liquidationRatio,
                    globalLiquidationRatio: globalLiquidationRatio,
                    baseRate: baseRate,
                    roleAdmin: roleAdmin,
                    vaultAdmin: vaultAdmin,
                    tickManager: tickManager,
                    pauseAdmin: pauseAdmin
                }),
                0
            )
        );

        _checkParams(vault);
    }
}