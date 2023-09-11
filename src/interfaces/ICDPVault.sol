// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";

import {ICDM} from "./ICDM.sol";
import {IOracle} from "./IOracle.sol";
import {IBuffer} from "./IBuffer.sol";
import {IPause} from "./IPause.sol";
import {IPermission} from "./IPermission.sol";
import {IInterestRateModel} from "./IInterestRateModel.sol";

/// @title ICDPVaultBase
/// @notice Interface for the CDPVault without `paused` to avoid unnecessary overriding of `paused` in CDPVault
interface ICDPVaultBase is IAccessControl, IPause, IPermission {

    function cdm() external view returns (ICDM);
    
    function oracle() external view returns (IOracle);
    
    function buffer() external view returns (IBuffer);
    
    function token() external view returns (IERC20);
    
    function tokenScale() external view returns (uint256);

    function vaultConfig() external view returns (
        uint128 debtFloor, uint64 liquidationRatio, uint64 globalLiquidationRatio
    );

    function protocolFee() external view returns (uint256);

    function totalNormalDebt() external view returns (uint256);
    
    function totalAccruedFees() external view returns (uint256);

    function cash(address owner) external view returns (uint256);

    function positions(address owner) external view returns (uint256 collateral, uint256 normalDebt);

    function activeLimitPriceTicks(uint256 priceTick) external view returns (bool);

    function limitOrders(uint256 limitOrderId) external view returns (uint256);

    function limitOrderFloor() external view returns (uint256);

    function deposit(address to, uint256 amount) external returns (uint256);

    function withdraw(address to, uint256 amount) external returns (uint256);

    function spotPrice() external returns (uint256);

    function modifyCollateralAndDebt(
        address owner,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) external;

    function getPriceTick(uint256 index) external view returns (uint256 priceTick, bool isActive);

    function getLimitOrder(uint256 priceTick, uint256 index) external view returns (uint256 limitOrderId);

    function virtualIRS(address position) external view returns (uint64 rateAccumulator, uint256 positionAccruedRebate, uint256 globalAccruedRebate);

    function calculateRebateFactorForPriceTick(uint256 priceTick) external view returns (uint64);

    function addLimitPriceTick(uint256 limitPriceTick, uint256 nextLimitPriceTick) external;

    function removeLimitPriceTick(uint256 limitPriceTick) external;

    function createLimitOrder(uint256 limitPriceTick) external;

    function cancelLimitOrder() external;

    function exchange(
        uint256 upperLimitPriceTick,
        uint256 creditToExchange
    ) external returns (uint256 creditExchanged, uint256 collateralExchanged);
}

/// @title ICDPVault
/// @notice Interface for the CDPVault
interface ICDPVault is ICDPVaultBase, IInterestRateModel {

    function paused() external view returns (bool);
}
