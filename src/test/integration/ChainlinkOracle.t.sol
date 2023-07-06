// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

import {wdiv} from "../../utils/Math.sol";

import {ChainlinkOracle} from "../../oracle/ChainlinkOracle.sol";

contract ChainlinkOracleTest is IntegrationTestBase {
    ChainlinkOracle internal chainlinkOracle;

    uint256 internal staleTime = 1 days;

    function setUp() public override {
        super.setUp();

        chainlinkOracle = ChainlinkOracle(address(new ERC1967Proxy(
            address(new ChainlinkOracle(AggregatorV3Interface(USDC_CHAINLINK_FEED), staleTime)),
            abi.encodeWithSelector(ChainlinkOracle.initialize.selector, address(this), address(this))
        )));
    }

    function test_deployOracle() public {
        assertTrue(address(chainlinkOracle) != address(0));
    }
    
    function test_spot(address token) public {
        (, int256 answer, , ,) = AggregatorV3Interface(USDC_CHAINLINK_FEED).latestRoundData();
        uint256 scaledAnswer = wdiv(uint256(answer), 10**AggregatorV3Interface(USDC_CHAINLINK_FEED).decimals());
        assertEq(chainlinkOracle.spot(token), scaledAnswer);
    }

    function test_getStatus() public {
        assertTrue(chainlinkOracle.getStatus(address(0)));
    }

    function test_getStatus_returnsFalseOnStaleValue() public {
        vm.warp(block.timestamp + staleTime + 1);
        assertTrue(chainlinkOracle.getStatus(address(0)) == false);
    }

    function test_spot_revertsOnStaleValue(address token) public {
        vm.warp(block.timestamp + staleTime + 1);
        
        vm.expectRevert(ChainlinkOracle.ChainlinkOracle__spot_invalidValue.selector);
        chainlinkOracle.spot(token);
    }

    function test_upgradeOracle() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1 );
        chainlinkOracle.upgradeTo(
            address(new ChainlinkOracle(AggregatorV3Interface(USDT_CHAINLINK_FEED), newStaleTime))
        );

        assertTrue(address(chainlinkOracle.aggregator()) == USDT_CHAINLINK_FEED);
        assertEq(chainlinkOracle.stalePeriod(), newStaleTime);
    }

    function test_upgradeOracle_revertsOnValidState() public {
        // the value returned is valid so the upgrade should revert
        uint256 newStaleTime = staleTime + 1 days;

        address newImplementation = address(new ChainlinkOracle(AggregatorV3Interface(USDT_CHAINLINK_FEED), newStaleTime));
        vm.expectRevert(ChainlinkOracle.ChainlinkOracle__authorizeUpgrade_validStatus.selector);
        chainlinkOracle.upgradeTo(
            newImplementation
        );
    }

    function test_upgradeOracle_revertsOnUnauthorized() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1 );

        // attempt to upgrade from an unauthorized address
        vm.startPrank(address(0x123123));
        address newImplementation = address(new ChainlinkOracle(AggregatorV3Interface(USDT_CHAINLINK_FEED), newStaleTime));

        vm.expectRevert();
        chainlinkOracle.upgradeTo(
            newImplementation
        );
        vm.stopPrank();
    }

    function test_upgradeOracle_usesNewFeed(address token) public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1 );
        chainlinkOracle.upgradeTo(
            address(new ChainlinkOracle(AggregatorV3Interface(USDT_CHAINLINK_FEED), newStaleTime))
        );

        (, int256 answer, , ,) = AggregatorV3Interface(USDT_CHAINLINK_FEED).latestRoundData();
        uint256 scaledAnswer = wdiv(uint256(answer), 10**AggregatorV3Interface(USDT_CHAINLINK_FEED).decimals());
        assertEq(chainlinkOracle.spot(token), scaledAnswer);
    }
}
