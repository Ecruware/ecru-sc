// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IYVault is IERC20 {
    function decimals() external view returns (uint256);
    function token() external view returns (address);
    function getPricePerFullShare() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function withdraw() external returns (uint256);
    function withdraw(uint256 amount) external returns (uint256);
    function withdraw(uint256 amount, address recipient, uint256 maxLoss) external returns (uint256);
    function deposit(uint256 amount) external returns (uint256);
}
