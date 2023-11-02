// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UUPSUpgradeable} from "openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {AggregatorV3Interface} from "../vendor/AggregatorV3Interface.sol";

import {wdiv} from "../utils/Math.sol";
import {IOracle, MANAGER_ROLE} from "../interfaces/IOracle.sol";

/// @title ChainlinkOracle
/// @notice Lightweight oracle that uses Chainlink as a data source
/// The oracle is upgradable if the current implementation does not return a valid price
contract ChainlinkOracle is IOracle, AccessControlUpgradeable, UUPSUpgradeable {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Chainlink aggregator address
    AggregatorV3Interface public immutable aggregator;
    /// @notice Stable period in seconds
    uint256 public immutable stalePeriod;
    /// @notice Aggregator decimal to WAD conversion scale
    uint256 public immutable aggregatorScale;

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ChainlinkOracle__spot_invalidValue();
    error ChainlinkOracle__authorizeUpgrade_validStatus();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param aggregator_ Chainlink aggregator address
    /// @param stalePeriod_ Stable period in seconds
    constructor(AggregatorV3Interface aggregator_, uint256 stalePeriod_) initializer {
        aggregator = aggregator_;
        stalePeriod = stalePeriod_;
        aggregatorScale = 10 ** uint256(aggregator.decimals());
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
        if(_getStatus()) revert ChainlinkOracle__authorizeUpgrade_validStatus();
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the status of the oracle
    /// @param /*token*/ Token address, ignored for this oracle
    /// @dev The status is valid if the price is validated and not stale
    function getStatus(address /*token*/) public override virtual view returns (bool status){
        return _getStatus();
    }

    /// @notice Returns the latest price for the asset from Chainlink [WAD]
    /// @param /*token*/ Token address
    /// @return price Asset price [WAD]
    /// @dev reverts if the price is invalid
    function spot(address /* token */) external view virtual override returns (uint256 price) {
        bool isValid;
        (isValid, price) = _fetchAndValidate();
        if (!isValid) revert ChainlinkOracle__spot_invalidValue();
    }

    /// @notice Fetches and validates the latest price from Chainlink
    /// @return isValid Whether the price is valid based on the value range and staleness
    /// @return price Asset price [WAD]
    function _fetchAndValidate() internal view returns (bool isValid, uint256 price) {
        try AggregatorV3Interface(aggregator).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 /*startedAt*/, uint256 updatedAt, uint80 answeredInRound
        ) {
            isValid = (answer > 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= stalePeriod);
            return (isValid, wdiv(uint256(answer), aggregatorScale));
        } catch {
            // return the default values (false, 0) on failure
        }
    }

    /// @notice Returns the status of the oracle
    /// @return status Whether the oracle is valid
    /// @dev The status is valid if the price is validated and not stale
    function _getStatus() private view returns (bool status){
        (status,) = _fetchAndValidate();
    }

}
