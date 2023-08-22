// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBuffer} from "./interfaces/IBuffer.sol";
import {ICDM} from "./interfaces/ICDM.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ICDPVault_TypeA_Factory, CDPVaultConstants, CDPVaultConfig, CDPVault_TypeAConfig} from "./interfaces/ICDPVault_TypeA_Factory.sol";
import {ICDPVault_TypeA_Deployer} from "./interfaces/ICDPVault_TypeA_Deployer.sol";

import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";
import {WAD} from "./utils/Math.sol";

import {VAULT_CONFIG_ROLE, TICK_MANAGER_ROLE, VAULT_UNWINDER_ROLE} from "./CDPVault.sol";
import {CDPVault_TypeA} from "./CDPVault_TypeA.sol";
import {CreditWithholder} from "./CreditWithholder.sol";

// Authenticated Roles
bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

contract CDPVault_TypeA_Factory is ICDPVault_TypeA_Factory, AccessControl, Pause {

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CDPVaultConstants internal constants;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deployer contract responsible for housing CDPVault_TypeA bytecode
    ICDPVault_TypeA_Deployer public immutable deployer;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CreateVault(address indexed vault, address indexed token, address indexed creator);

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(
        ICDPVault_TypeA_Deployer deployer_,
        address roleAdmin,
        address deployerAdmin,
        address pauseAdmin
    ) {
        deployer = deployer_;
        _grantRole(DEFAULT_ADMIN_ROLE, roleAdmin);
        _grantRole(DEPLOYER_ROLE, deployerAdmin);
        _grantRole(PAUSER_ROLE, pauseAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function create(
        CDPVaultConstants memory cdpVaultConstants,
        CDPVault_TypeAConfig memory cdpVaultTypeAConfig,
        CDPVaultConfig memory cdpVaultConfig,
        uint256 debtCeiling
    ) external whenNotPaused returns (address) {
        constants = cdpVaultConstants;

        CDPVault_TypeA vault = CDPVault_TypeA(deployer.deploy());
        vault.setUp();

        delete constants;

        vault.grantRole(VAULT_CONFIG_ROLE, address(this));

        // set parameters
        vault.setParameter("debtFloor", cdpVaultConfig.debtFloor);
        vault.setParameter("limitOrderFloor", cdpVaultConfig.limitOrderFloor);
        vault.setParameter("liquidationRatio", cdpVaultConfig.liquidationRatio);
        vault.setParameter("globalLiquidationRatio", cdpVaultConfig.globalLiquidationRatio);
        vault.setParameter("baseRate", cdpVaultConfig.baseRate);
        vault.setParameter("liquidationPenalty", cdpVaultTypeAConfig.liquidationPenalty);
        vault.setParameter("liquidationDiscount", cdpVaultTypeAConfig.liquidationDiscount);
        vault.setParameter("targetHealthFactor", cdpVaultTypeAConfig.targetHealthFactor);

        // set roles
        vault.grantRole(VAULT_CONFIG_ROLE, cdpVaultConfig.vaultAdmin);
        vault.grantRole(TICK_MANAGER_ROLE, cdpVaultConfig.tickManager);
        vault.grantRole(PAUSER_ROLE, cdpVaultConfig.pauseAdmin);
        vault.grantRole(DEFAULT_ADMIN_ROLE, cdpVaultConfig.roleAdmin);

        // revoke factory roles
        vault.revokeRole(VAULT_CONFIG_ROLE, address(this));
        vault.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        // reverts if debtCeiling is set and msg.sender does not have the DEPLOYER_ROLE
        if (debtCeiling > 0) {
            _checkRole(DEPLOYER_ROLE);
            cdpVaultConstants.cdm.setParameter(address(vault), "debtCeiling", debtCeiling);
        }

        emit CreateVault(address(vault), address(cdpVaultConstants.token), msg.sender);

        return address(vault);
    }

    function getConstants() external view returns (
        ICDM cdm,
        IOracle oracle,
        IBuffer buffer,
        IERC20 token,
        uint256 tokenScale,
        uint256 protocolFee,
        uint256 utilizationParams,
        uint256 rebateParams
    ) {
        cdm = constants.cdm;
        oracle = constants.oracle;
        buffer = constants.buffer;
        token = constants.token;
        tokenScale = constants.tokenScale;
        protocolFee = constants.protocolFee;
        utilizationParams =
            uint256(constants.targetUtilizationRatio)
            | (uint256(constants.maxUtilizationRatio) << 64)
            | (uint256(constants.minInterestRate - WAD) << 128)
            | (uint256(constants.maxInterestRate - WAD) << 168)
            | (uint256(constants.targetInterestRate - WAD) << 208);
        rebateParams = uint256(constants.rebateRate) | (uint256(constants.maxRebate) << 128);
    }
}

contract CDPVault_TypeA_Deployer is ICDPVault_TypeA_Deployer {

    function deploy() external returns (address vault) {
        vault = address(new CDPVault_TypeA(msg.sender));
    }
}
