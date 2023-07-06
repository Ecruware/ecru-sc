// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {wdiv, min, wmul} from "../../utils/Math.sol";

import {Chainlink3PoolOracle} from "../../oracle/Chainlink3PoolOracle.sol";

import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

contract Chainlink3PoolOracleTest is IntegrationTestBase {
    Chainlink3PoolOracle internal chainlinkOracle;

    uint256 internal staleTime = 1 days;

    function _fetchAndScalePrice(address aggregator) internal view returns (uint256) {
        (, int256 answer, , ,) = AggregatorV3Interface(aggregator).latestRoundData();
        return wdiv(uint256(answer), 10**AggregatorV3Interface(aggregator).decimals());
    }

    function setUp() public override {
        super.setUp();

        Chainlink3PoolOracle implementation = new Chainlink3PoolOracle(
            AggregatorV3Interface(USDC_CHAINLINK_FEED), 
            AggregatorV3Interface(DAI_CHAINLINK_FEED), 
            AggregatorV3Interface(USDT_CHAINLINK_FEED), 
            curve3Pool,
            staleTime
        );

        chainlinkOracle = Chainlink3PoolOracle(address(new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(Chainlink3PoolOracle.initialize.selector, address(this), address(this))
        )));
    }

    function test_deployOracle() public {
        assertTrue(address(chainlinkOracle) != address(0));
    }

    function test_getStatus() public {
        assertTrue(chainlinkOracle.getStatus(address(0)));
    }

    function test_getStatus_returnsFalseOnStaleValue() public {
        vm.warp(block.timestamp + staleTime + 1);
        assertTrue(chainlinkOracle.getStatus(address(0)) == false);
    }
    
    function test_spot(address token) public {
        uint256 usdcPrice = _fetchAndScalePrice(USDC_CHAINLINK_FEED);
        uint256 daiPrice = _fetchAndScalePrice(DAI_CHAINLINK_FEED);
        uint256 usdtPrice = _fetchAndScalePrice(USDT_CHAINLINK_FEED);
        uint256 answer = wmul(curve3Pool.get_virtual_price(), min(usdcPrice, min(daiPrice, usdtPrice)));
        assertEq(chainlinkOracle.spot(token), answer);
    }

    function test_spot_revertsOnStaleValue(address token) public {
        vm.warp(block.timestamp + staleTime + 1);
        
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(chainlinkOracle.aggregator1()))
        );
        chainlinkOracle.spot(token);
    }

    function test_upgradeOracle() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1 );

        Chainlink3PoolOracle implementation = new Chainlink3PoolOracle(
            AggregatorV3Interface(LUSD_CHAINLINK_FEED), 
            AggregatorV3Interface(USDT_CHAINLINK_FEED), 
            AggregatorV3Interface(DAI_CHAINLINK_FEED), 
            curve3Pool,
            newStaleTime
        );
        
        chainlinkOracle.upgradeTo(
            address(implementation)
        );
        
        assertTrue(address(chainlinkOracle.aggregator1()) == LUSD_CHAINLINK_FEED);
        assertTrue(address(chainlinkOracle.aggregator2()) == USDT_CHAINLINK_FEED);
        assertTrue(address(chainlinkOracle.aggregator3()) == DAI_CHAINLINK_FEED);
        
        assertEq(chainlinkOracle.stalePeriod(), newStaleTime);
    }

    function test_upgradeOracle_revertsOnValidState() public {
        // the value returned is valid so the upgrade should revert
        uint256 newStaleTime = staleTime + 1 days;

        address newImplementation = address (new Chainlink3PoolOracle(
            AggregatorV3Interface(LUSD_CHAINLINK_FEED), 
            AggregatorV3Interface(USDT_CHAINLINK_FEED), 
            AggregatorV3Interface(DAI_CHAINLINK_FEED), 
            curve3Pool,
            newStaleTime
        ));

        vm.expectRevert(Chainlink3PoolOracle.Chainlink3PoolOracle__authorizeUpgrade_validStatus.selector);
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
        address newImplementation = address (new Chainlink3PoolOracle(
            AggregatorV3Interface(LUSD_CHAINLINK_FEED), 
            AggregatorV3Interface(USDT_CHAINLINK_FEED), 
            AggregatorV3Interface(DAI_CHAINLINK_FEED), 
            curve3Pool,
            newStaleTime
        ));

        vm.expectRevert();
        chainlinkOracle.upgradeTo(
            newImplementation
        );
        vm.stopPrank();
    }

    function test_upgradeOracle_usesNewFeed(address token) public {
        uint256 newStaleTime = staleTime + 1 days;
        vm.warp(block.timestamp + staleTime + 1 );

        Chainlink3PoolOracle implementation = new Chainlink3PoolOracle(
            AggregatorV3Interface(LUSD_CHAINLINK_FEED), 
            AggregatorV3Interface(DAI_CHAINLINK_FEED), 
            AggregatorV3Interface(USDT_CHAINLINK_FEED), 
            curve3Pool,
            newStaleTime
        );
        
        chainlinkOracle.upgradeTo(
            address(implementation)
        );

        uint256 lusdPrice = _fetchAndScalePrice(LUSD_CHAINLINK_FEED);
        uint256 daiPrice = _fetchAndScalePrice(DAI_CHAINLINK_FEED);
        uint256 usdtPrice = _fetchAndScalePrice(USDT_CHAINLINK_FEED);
        uint256 answer = wmul(curve3Pool.get_virtual_price(), min(lusdPrice, min(daiPrice, usdtPrice)));
        assertEq(chainlinkOracle.spot(token), answer);
    }
}
