// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

/// @notice Copied from:
/// https://github.com/yearn/yearn-lens/blob/68096999c0fd369ced2527f9475afddc52459805/contracts/Oracle/Calculations/YearnVaults.sol#L55
/// at commit a67d8fa
interface IYearnLensOracle {
    function getPriceUsdcRecommended(address tokenAddress)
        external
        view
        returns (uint256);
}
