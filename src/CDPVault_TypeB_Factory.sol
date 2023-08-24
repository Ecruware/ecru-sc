// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBuffer} from "./interfaces/IBuffer.sol";
import {ICDM} from "./interfaces/ICDM.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ICDPVault_FactoryBase} from "./interfaces/ICDPVault_FactoryBase.sol";
import {ICDPVault_TypeB_Factory, CDPVaultConstants, CDPVaultConfig, CDPVault_TypeBConfig} from "./interfaces/ICDPVault_TypeB_Factory.sol";
import {ICDPVault_Deployer} from "./interfaces/ICDPVault_Deployer.sol";

import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";
import {WAD} from "./utils/Math.sol";

import {VAULT_CONFIG_ROLE, TICK_MANAGER_ROLE, VAULT_UNWINDER_ROLE} from "./CDPVault.sol";
import {CDPVault_TypeB} from "./CDPVault_TypeB.sol";
import {CreditWithholder} from "./CreditWithholder.sol";

// Authenticated Roles
bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

contract CDPVault_TypeB_Factory is ICDPVault_FactoryBase, ICDPVault_TypeB_Factory, AccessControl, Pause {

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CDPVaultConstants internal constants;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deployer contract responsible for housing CDPVault_TypeB bytecode
    ICDPVault_Deployer public immutable deployer;
    /// @notice Vault Unwinder Factory contract
    address public immutable unwinderFactory;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CreateVault(address indexed vault, address indexed token, address indexed creator);

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(
        ICDPVault_Deployer deployer_,
        address roleAdmin,
        address deployerAdmin,
        address pauseAdmin,
        address unwinderFactory_
    ) {
        deployer = deployer_;
        _grantRole(DEFAULT_ADMIN_ROLE, roleAdmin);
        _grantRole(DEPLOYER_ROLE, deployerAdmin);
        _grantRole(PAUSER_ROLE, pauseAdmin);
        unwinderFactory = unwinderFactory_;
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function create(
        CDPVaultConstants memory cdpVaultConstants,
        CDPVault_TypeBConfig memory cdpVaultTypeBConfig,
        CDPVaultConfig memory cdpVaultConfig,
        uint256 debtCeiling
    ) external override(ICDPVault_TypeB_Factory) whenNotPaused returns (address) {
        constants = cdpVaultConstants;

        CDPVault_TypeB vault = CDPVault_TypeB(deployer.deploy());
        vault.setUp();
        vault.setUnwinderFactory(unwinderFactory);

        delete constants;

        vault.grantRole(VAULT_CONFIG_ROLE, address(this));

        // set parameters
        vault.setParameter("debtFloor", cdpVaultConfig.debtFloor);
        vault.setParameter("limitOrderFloor", cdpVaultConfig.limitOrderFloor);
        vault.setParameter("liquidationRatio", cdpVaultConfig.liquidationRatio);
        vault.setParameter("globalLiquidationRatio", cdpVaultConfig.globalLiquidationRatio);
        vault.setParameter("baseRate", cdpVaultConfig.baseRate);
        vault.setParameter("liquidationPenalty", cdpVaultTypeBConfig.liquidationPenalty);
        vault.setParameter("liquidationDiscount", cdpVaultTypeBConfig.liquidationDiscount);
        vault.setParameter("targetHealthFactor", cdpVaultTypeBConfig.targetHealthFactor);

        // set roles
        vault.grantRole(VAULT_CONFIG_ROLE, cdpVaultConfig.vaultAdmin);
        vault.grantRole(TICK_MANAGER_ROLE, cdpVaultConfig.tickManager);
        vault.grantRole(VAULT_UNWINDER_ROLE, cdpVaultTypeBConfig.vaultUnwinder);
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

    function getConstants() 
        override(ICDPVault_FactoryBase) external view returns 
    (
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
    

    function creditWithholder() external returns (address) {
        return address(new CreditWithholder(constants.cdm, address(unwinderFactory), msg.sender));
    }
}

contract CDPVault_TypeB_Deployer is ICDPVault_Deployer {

    function deploy() external returns (address vault) {
        vault = address(new CDPVault_TypeB(msg.sender));
    }
}
