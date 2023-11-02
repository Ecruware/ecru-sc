// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {UUPSUpgradeable} from "openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IOracle, MANAGER_ROLE} from "../interfaces/IOracle.sol";

import {IYVault} from "../vendor/IYVault.sol";
import {IYearnLensOracle} from "../vendor/IYearnLensOracle.sol";
import {WAD} from "../utils/Math.sol";


/// @title YearnOracle
/// @notice Oracle for yearn vaults
contract YearnOracle is IOracle, AccessControlUpgradeable, UUPSUpgradeable {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Yearn vault v1 scale factor
    uint256 internal constant yearnV1Scale = 1e18;
    /// @notice Scale factor for WAD conversion
    uint256 internal constant toWADScale = 1e12;

    /// @notice Underlying asset oracle address
    IYearnLensOracle public immutable oracle;
    /// @notice Yearn vault address
    IYVault public immutable vault;
    /// @notice Vault token address
    address public immutable vaultTokenAddress;
    /// @notice Yearn vault type, true for v1 Vaults, false for v2 or v3
    bool public immutable isV1Vault;
    /// @notice Vault token scale factor
    uint256 public immutable vaultTokenScale;

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error YearnOracle__authorizeUpgrade_validStatus();
    error YearnOracle__spot_invalidValue();
    error YearnOracle__isV1Vault_invalidYearnVault();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param oracle_ Yearn underlying asset oracle address
    /// @dev Reverts if `yearnVault_` is not a valid yearn vault or invalid decimals
    constructor(IYearnLensOracle oracle_, IYVault yearnVault_) initializer {
        oracle = oracle_;
        vault = yearnVault_;
        vaultTokenAddress = vault.token();
        isV1Vault = _isV1Vault();
        vaultTokenScale = (isV1Vault) ? yearnV1Scale : 10**(IERC20Metadata(vaultTokenAddress).decimals());
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize method called by the proxy contract
    /// @param admin The address of the admin
    /// @param manager The address of the manager who can authorize upgrades
    function initialize(address admin, address manager) external initializer {
        // init. Access Control
        __AccessControl_init();
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Credit Manager
        _grantRole(MANAGER_ROLE, manager);
    }

    /// @notice Authorizes an upgrade
    /// @param /*implementation*/ The address of the new implementation
    /// @dev reverts if the caller is not a manager or if the status check succeeds
    function _authorizeUpgrade(address /*implementation*/) internal override virtual onlyRole(MANAGER_ROLE){
        if(_getStatus()) revert YearnOracle__authorizeUpgrade_validStatus();
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the latest price for the Yearn Vault [WAD]
    /// @param /*token*/ Token address
    /// @return price Asset price [WAD]
    function spot(address /*token*/) external view virtual override returns (uint256 price) {
        price= _computeSpot();
        if(price == 0) revert YearnOracle__spot_invalidValue();
    }

    /// @notice Returns the status of the oracle
    /// @param /*token*/ Token address, ignored for this oracle
    /// @dev The status is valid if the price is validated
    function getStatus(address /*token*/) public override virtual view returns (bool status){
        return _getStatus();
    }

    /// @notice Computes the latest spot price for the Yearn Vault [WAD]
    /// @return price Asset price [WAD]
    /// @dev returns 0 if the price is not valid or cannot be computed
    function _computeSpot() internal view returns (uint256 price) {
        try oracle.getPriceUsdcRecommended(vaultTokenAddress) returns (uint256 underlyingTokenPrice) {
            uint256 sharePrice = _getPricePerShare();
            price = (underlyingTokenPrice * sharePrice * toWADScale) / vaultTokenScale;
        } catch { }
    }

    /// @notice Returns the status of the oracle
    /// @return status Whether the oracle is valid
    /// @dev The status is valid if the price is validated
    function _getStatus() private view returns (bool status){
        return _computeSpot() != 0;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the share price from a yearn vault based on the type
    /// @return pricePerShare share price of the vault
    /// @dev returns 0 if the share price cannot be fetched
    function _getPricePerShare() private view returns (uint256 pricePerShare) {
        if(isV1Vault){
            try vault.getPricePerFullShare() returns (uint256 pricePerShare_) {
                pricePerShare = pricePerShare_;
            } catch { }    
        } else {
            try vault.pricePerShare() returns (uint256 pricePerShare_) {
                pricePerShare = pricePerShare_;
            } catch { }
        }
    }

    /// @notice Return if the Vault is a V1 Vault or not
    /// @return isV1Vault_ returns `true` if the vault is a V1 vault
    /// @dev Reverts if `yearnVault_` is not a valid yearn vault
    function _isV1Vault() private view returns (bool isV1Vault_) {
        try vault.getPricePerFullShare() returns (uint256 /*pricePerShare*/) {
            isV1Vault_ = true;
        } catch {
            try vault.pricePerShare() returns (uint256 /*pricePerShare*/) {
                // return false as the default value 
            } catch {
                revert YearnOracle__isV1Vault_invalidYearnVault();
            }
        }
    }
}
