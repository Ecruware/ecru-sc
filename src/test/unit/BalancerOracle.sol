// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TestBase} from "../TestBase.sol";

import {ChainlinkOracle, MANAGER_ROLE} from "../../oracle/ChainlinkOracle.sol";
import {BalancerOracle} from "../../oracle/BalancerOracle.sol";
import {IWeightedPool} from "../../vendor/IWeightedPool.sol";
import {IVault} from "../../vendor/IBalancerVault.sol";

contract BalancerOracleTest is TestBase {
    BalancerOracle internal balancerOracle;

    uint256 internal staleTime = 1 days;
    uint256 internal aggregatorScale = 10 ** 8;
    int256 internal mockPrice = 1e8;

    address pool;
    bytes32 poolId;

    address token0;
    address token1;
    address token2;

    address balancerVault;
    address chainlinkOracle;
    uint256 internal updateWaitWindow = 1 hours;
    uint256 internal stalePeriod = 1 days;

    function setUp() public override {
        super.setUp();

        pool = vm.addr(uint256(keccak256("pool")));
        token0 = vm.addr(uint256(keccak256("token0")));
        token1 = vm.addr(uint256(keccak256("token1")));
        token2 = vm.addr(uint256(keccak256("token2")));

        poolId = keccak256("poolId");
        balancerVault = vm.addr(uint256(keccak256("balancerVault")));
        chainlinkOracle = vm.addr(uint256(keccak256("chainlinkOracle")));

        vm.mockCall(
            pool, 
            abi.encodeWithSelector(IWeightedPool.getPoolId.selector),
            abi.encode(poolId)
        );

        address[] memory tokens = new address[](3);
        tokens[0] = token0; tokens[1] = token1; tokens[2] = token2;
        uint256[] memory balances = new uint256[](3);
        
        vm.mockCall(
            balancerVault, 
            abi.encodeWithSelector(IVault.getPoolTokens.selector, poolId),
            abi.encode(tokens, balances, 0)
        );

        balancerOracle = BalancerOracle(address(new ERC1967Proxy(
            address(new BalancerOracle(balancerVault, chainlinkOracle, pool, updateWaitWindow, stalePeriod)),
            abi.encodeWithSelector(BalancerOracle.initialize.selector, address(this), address(this))
        )));
    }

    function test_deployOracle() public {
        assertTrue(address(oracle) != address(0));
    }

    function test_initialize_accounts(address admin, address manager) public {
        balancerOracle = BalancerOracle(address(new ERC1967Proxy(
            address(new BalancerOracle(balancerVault, chainlinkOracle, pool, updateWaitWindow, stalePeriod)),
            abi.encodeWithSelector(ChainlinkOracle.initialize.selector, address(this), address(this))
        )));

        assertTrue(balancerOracle.hasRole(MANAGER_ROLE, manager));

        assertTrue(balancerOracle.hasRole(balancerOracle.DEFAULT_ADMIN_ROLE(), admin));
    }
}
