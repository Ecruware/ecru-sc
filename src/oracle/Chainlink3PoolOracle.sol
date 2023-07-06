// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UUPSUpgradeable} from "openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IOracle} from "../interfaces/IOracle.sol";

import {AggregatorV3Interface} from "../vendor/AggregatorV3Interface.sol";
import {ICurvePool} from "../vendor/ICurvePool.sol";

import {wmul, wdiv, min} from "../utils/Math.sol";

// Authenticated Roles
bytes32 constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

/// @title Chainlink3PoolOracle
contract Chainlink3PoolOracle is IOracle, AccessControlUpgradeable, UUPSUpgradeable {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Curve pool address
    ICurvePool public immutable curvePool;
    /// @notice Chainlink aggregator1 address
    AggregatorV3Interface public immutable aggregator1;
    /// @notice Chainlink aggregator2 address
    AggregatorV3Interface public immutable aggregator2;
    /// @notice Chainlink aggregator3 address
    AggregatorV3Interface public immutable aggregator3;
    /// @notice Aggregator1 decimal to WAD conversion scale
    uint256 public immutable aggregatorScale1;
    /// @notice Aggregator2 decimal to WAD conversion scale
    uint256 public immutable aggregatorScale2;
    /// @notice Aggregator3 decimal to WAD conversion scale
    uint256 public immutable aggregatorScale3;
    /// @notice Stable period in seconds
    uint256 public immutable stalePeriod;

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Chainlink3PoolOracle__getPrice_invalidValue(address aggregator);
    error Chainlink3PoolOracle__authorizeUpgrade_validStatus();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        AggregatorV3Interface aggregator1_,
        AggregatorV3Interface aggregator2_,
        AggregatorV3Interface aggregator3_,
        ICurvePool curvePool_,
        uint256 stalePeriod_
    ) initializer {
        aggregator1 = aggregator1_;
        aggregator2 = aggregator2_;
        aggregator3 = aggregator3_;
        stalePeriod = stalePeriod_;
        curvePool = curvePool_;
        aggregatorScale1 = 10 ** uint256(aggregator1.decimals());
        aggregatorScale2 = 10 ** uint256(aggregator2.decimals());
        aggregatorScale3 = 10 ** uint256(aggregator3.decimals());
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize method called by the proxy contract
    /// @param admin The address of the admin
    /// @param manager The address of the manager who can authorize upgrades
    function initialize(address admin, address manager) external initializer {
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Credit Manager
        _grantRole(MANAGER_ROLE, manager);
    }

    /// @notice Authorizes an upgrade
    /// @param /*implementation*/ The address of the new implementation
    /// @dev reverts if the caller is not a manager or if the status check succeeds
    function _authorizeUpgrade(address /*implementation*/) internal override virtual onlyRole(MANAGER_ROLE){
        if (_getStatus()) revert Chainlink3PoolOracle__authorizeUpgrade_validStatus();
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the status of the oracle
    /// @param /*token*/ Token address, ignored for this oracle
    /// @return status Whether the oracle is valid
    /// @dev The status is valid if all prices are validated and not stale
    function getStatus(address /*token*/) public override virtual view returns (bool status){
        return _getStatus();
    }

    /// @notice Returns the latest price by retrieving and computing the minimum of the three Chainlink oracles [WAD]
    /// @param /*token*/ Token address
    /// @return price Asset price [WAD]
    /// @dev reverts if any price is invalid
    function spot(address /* token */) external view override returns (uint256 price) {
        bool isValid;
        uint256  minSpotPrice;
        
        // fetch and validate first price
        (isValid, minSpotPrice) = _fetchAndValidate(aggregator1, aggregatorScale1);
        if(!isValid) revert Chainlink3PoolOracle__getPrice_invalidValue(address(aggregator1));

        // fetch and validate the second price and compute the minimum
        uint256 feedPrice;
        (isValid, feedPrice) = _fetchAndValidate(aggregator2, aggregatorScale2);
        if(!isValid) revert Chainlink3PoolOracle__getPrice_invalidValue(address(aggregator2));
        minSpotPrice = min(minSpotPrice, feedPrice);

        // fetch and validate the last price and compute the minimum
        (isValid, feedPrice) = _fetchAndValidate(aggregator3, aggregatorScale3);
        if(!isValid) revert Chainlink3PoolOracle__getPrice_invalidValue(address(aggregator3));
        minSpotPrice = min(minSpotPrice, feedPrice);

        // compute the final price
        price = wmul(minSpotPrice, curvePool.get_virtual_price()); 
    }

    /// @notice Returns the latest price for the asset from Chainlink [WAD]
    /// @param aggregator Chainlink aggregator address
    /// @param aggregatorScale Aggregator decimal to WAD conversion scale
    /// @return isValid Whether the price is valid based on the value range and staleness
    /// @return price Asset price [WAD]
    function _fetchAndValidate(AggregatorV3Interface aggregator, uint256 aggregatorScale) internal view returns (bool isValid, uint256 price) {
        try AggregatorV3Interface(aggregator).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 /*startedAt*/, uint256 updatedAt, uint80 answeredInRound
        ) {
            isValid = (answer > 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= stalePeriod);
            price = wdiv(uint256(answer), aggregatorScale);
        } catch {
            // on error will return (isValid = false, price = 0)
        }
    }

    /// @notice Returns the status of the oracle
    /// @return status Whether the oracle is valid
    /// @dev The status is valid if all prices are validated and not stale
    function _getStatus() private view returns (bool status){
        (bool isValid1,) = _fetchAndValidate(aggregator1, aggregatorScale1);
        (bool isValid2,) = _fetchAndValidate(aggregator2, aggregatorScale2);
        (bool isValid3,) = _fetchAndValidate(aggregator3, aggregatorScale3);
        return isValid1 && isValid2 && isValid3;
    }

}
