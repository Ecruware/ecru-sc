// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICDPVault} from "./ICDPVault.sol";
import {ICDM} from "./ICDM.sol";

interface ICDPVaultUnwinder {

    function AUCTION_START() external view returns (uint256);

    function AUCTION_END() external view returns (uint256);
    
    function AUCTION_DEBT_FLOOR() external view returns (uint256);
    
    function AUCTION_MULTIPLIER() external view returns (uint256);
    
    function AUCTION_DURATION() external view returns (uint256);

    function vault() external view returns (ICDPVault);
    
    function cdm() external view returns (ICDM);
    
    function token() external view returns (IERC20);
    
    function tokenScale() external view returns (uint256);
    
    function createdAt() external view returns (uint256);

    function fixedGlobalRateAccumulator() external view returns (uint256);

    function fixedTotalDebt() external view returns (uint256);
    
    function fixedTotalShares() external view returns (uint256);

    function fixedCollateral() external view returns (uint256);
    
    function fixedCredit() external view returns (uint256);

    function totalDebt() external view returns (uint256);

    function totalShares() external view returns (uint256);

    function repaidNormalDebt(address position) external view returns (uint256);

    function redeemedShares(address delegator) external view returns (uint256);

    function auction() external view returns (uint256, uint256, uint96, uint160);

    function redeemCredit(
        address owner, address receiver, address payer, uint256 subNormalDebt
    ) external returns (uint256 collateralRedeemed);

    function redeemShares(uint256 subShares) external returns (uint256 creditRedeemed);

    function getAuctionStatus()
        external
        view
        returns (bool needsRedo, uint256 price, uint256 cashToSell, uint256 debt);

    function startAuction() external;

    function redoAuction() external;

    function takeCash(
        uint256 cashAmount, uint256 maxPrice, address recipient
    ) external returns (uint256 cashToBuy, uint256 creditToPay);
}
