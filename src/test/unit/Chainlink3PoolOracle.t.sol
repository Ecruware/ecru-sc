// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WAD} from "../../utils/Math.sol";
import {TestBase} from "../TestBase.sol";

import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";
import {ICurvePool} from "../../vendor/ICurvePool.sol";

import {Chainlink3PoolOracle, MANAGER_ROLE} from "../../oracle/Chainlink3PoolOracle.sol";

contract MockAggregator is AggregatorV3Interface{
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint256 public override version;

    function decimals() external override pure returns (uint8) {
        return 8;
    }

    function description() external override pure returns (string memory) {
        return "mock aggregator";
    }

    function getRoundData(uint80 /*roundId*/)
        external
        override
        view
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80 answeredInRound_
    ){
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function latestRoundData() external override view returns (
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ){
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function setRoundValue(int256 value) public {
        answer = value;
    }

    function setRoundId(uint80 roundId_, uint80 answeredInRound_) public {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function setTimestamp(uint256 startedAt_, uint256 updatedAt_) public {
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function setVersion(uint256 version_) public {
        version = version_;
    }
}

contract Chainlink3PoolOracleTest is TestBase {

    MockAggregator internal aggregator1;
    MockAggregator internal aggregator2;
    MockAggregator internal aggregator3;
    Chainlink3PoolOracle internal chainlinkOracle;
    ICurvePool internal mockCurvePool = ICurvePool(address(0x321));

    uint256 internal staleTime = 1 days;
    uint256 internal aggregatorScale = 10 ** 8;
    int256 internal mockPrice1 = 1e8;
    int256 internal mockPrice2 = 2e8;
    int256 internal mockPrice3 = 1e8 + 1000 wei;

    function _createMockAggregators(int256 price1, int256 price2, int256 price3) private returns(
        MockAggregator aggregator1_, 
        MockAggregator aggregator2_, 
        MockAggregator aggregator3_
    ) {
        aggregator1_ = new MockAggregator();
        aggregator1_.setRoundValue(price1);
        aggregator1_.setRoundId(1, 1);
        aggregator1_.setVersion(1);
        aggregator1_.setTimestamp(block.timestamp, block.timestamp);

        aggregator2_ = new MockAggregator();
        aggregator2_.setRoundValue(price2);
        aggregator2_.setRoundId(1, 1);
        aggregator2_.setVersion(1);
        aggregator2_.setTimestamp(block.timestamp, block.timestamp);

        aggregator3_ = new MockAggregator();
        aggregator3_.setRoundValue(price3);
        aggregator3_.setRoundId(1, 1);
        aggregator3_.setVersion(1);
        aggregator3_.setTimestamp(block.timestamp, block.timestamp);
    }

    function setUp() public override {
        super.setUp();

        (aggregator1, aggregator2, aggregator3) = _createMockAggregators(mockPrice1, mockPrice2, mockPrice3);

        vm.mockCall(
            address(mockCurvePool),
            abi.encodeWithSelector(ICurvePool.get_virtual_price.selector),
            abi.encode(WAD)
        );

        chainlinkOracle = Chainlink3PoolOracle(address(new ERC1967Proxy(
            address(new Chainlink3PoolOracle(aggregator1, aggregator2, aggregator3, mockCurvePool, staleTime)),
            abi.encodeWithSelector(Chainlink3PoolOracle.initialize.selector, address(this), address(this))
        )));
    }

    function test_deployOracle() public {
        assertTrue(address(chainlinkOracle) != address(0));
    }

    function test_initialize_accounts(address admin, address manager) public {
        chainlinkOracle = Chainlink3PoolOracle(address(new ERC1967Proxy(
            address(new Chainlink3PoolOracle(aggregator1, aggregator2, aggregator3, mockCurvePool, staleTime)),
            abi.encodeWithSelector(Chainlink3PoolOracle.initialize.selector, address(admin), address(manager))
        )));

        assertTrue(chainlinkOracle.hasRole(MANAGER_ROLE, manager));

        assertTrue(chainlinkOracle.hasRole(chainlinkOracle.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_spot() public {
        uint256 expectedSpot = 1 ether;
        assertTrue(chainlinkOracle.spot(address(0x1)) == expectedSpot);
    }

    function test_spot_revertsOnStaleRound() public {
        vm.warp(block.timestamp + staleTime + 1);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator1))
        );
        chainlinkOracle.spot(address(0x1));
    }

    function test_spot_revertsOnInvalidValue() public {
        aggregator1.setRoundValue(0);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator1))
        );
        chainlinkOracle.spot(address(0x1));
        // set to a valid value
        aggregator1.setRoundValue(int256(WAD));

        aggregator2.setRoundValue(0);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator2))
        );
        chainlinkOracle.spot(address(0x1));
        
        //set to a valid value
        aggregator2.setRoundValue(int256(WAD));

        aggregator3.setRoundValue(0);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator3))
        );
        chainlinkOracle.spot(address(0x1));
    }

    function test_spot_revertsOnInvalidRound() public {
        aggregator1.setRoundId(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator1))
        );
        chainlinkOracle.spot(address(0x1));
        // set to a valid round
        aggregator1.setRoundId(1, 1);

        aggregator2.setRoundId(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator2))
        );
        chainlinkOracle.spot(address(0x1));
        // set to a valid round
        aggregator2.setRoundId(1, 1);

        aggregator3.setRoundId(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Chainlink3PoolOracle.Chainlink3PoolOracle__getPrice_invalidValue.selector, 
            address(aggregator3))
        );
        chainlinkOracle.spot(address(0x1));
    }
}
