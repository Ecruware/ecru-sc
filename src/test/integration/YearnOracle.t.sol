// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {IYVault} from "../../vendor/IYVault.sol";
import {IYearnLensOracle} from "../../vendor/IYearnLensOracle.sol";

import {YearnOracle} from "../../oracle/YearnOracle.sol";

interface IYearnNativeOracle {
    function getPriceYearnVault(address vault) external view returns (uint256);
}

contract YearnOracleTest is IntegrationTestBase {
    IYearnLensOracle internal yearnLensOracle = IYearnLensOracle(address(0x83d95e0D5f402511dB06817Aff3f9eA88224B030));

    IYearnNativeOracle internal nativeOracle = IYearnNativeOracle(address(0x38477F2159638956d33E18951d98238a53b9aa3C));

    IYVault internal usdcYVault = IYVault(address(0xa354F35829Ae975e850e23e9615b11Da1B3dC4DE));
    IYVault internal daiYVault = IYVault(address(0xdA816459F1AB5631232FE5e97a05BBBb94970c95));
    IYVault internal curve3CryptoYVault = IYVault(address(0x8078198Fc424986ae89Ce4a910Fc109587b6aBF3));
    IYVault internal curveSTGUsdcYVault = IYVault(address(0x341bb10D8f5947f3066502DC8125d9b8949FD3D6));

    YearnOracle[4] internal oracles;

    function setUp() public override {
        super.setUp();

        oracles[0] = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(yearnLensOracle, usdcYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        oracles[1] = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(yearnLensOracle, daiYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        oracles[2] = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(yearnLensOracle, curve3CryptoYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        oracles[3] = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(yearnLensOracle, curveSTGUsdcYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));
    }

    function getForkBlockNumber() internal override pure returns (uint256){
        return 17243298; // May-12-2023 09:39:35 AM +UTC
    }

    function test_deployOracle() public {
        for (uint256 i=0; i<oracles.length; i++) {
            YearnOracle oracle = oracles[i];
            assertTrue(address(oracle) != address(0));
            assertTrue(oracle.isV1Vault() == false);
        }
    }

    function test_lensOracle() public {
        for (uint256 i=0; i<oracles.length; i++) {
            uint256 underlyingTokenPrice = yearnLensOracle.getPriceUsdcRecommended(oracles[i].vaultTokenAddress());
            assertTrue(underlyingTokenPrice > 0);
        }
    }

    function test_isV1Vault() public {
        for (uint256 i=0; i<oracles.length; i++) {
            assertTrue(oracles[i].isV1Vault() == false);
        }
    }

    function test_spot(address token) public {
        for (uint256 i=0; i<oracles.length; i++) {
            YearnOracle yearnOracle = oracles[i];
            // fetch and scale the price from the yearn native oracle
            uint256 expectedPrice = nativeOracle.getPriceYearnVault(address(yearnOracle.vault())) * 1e12;
            uint256 spotPrice = yearnOracle.spot(token);

            spotPrice = spotPrice / 1e12 * 1e12;
            
            assertEq(spotPrice, expectedPrice);
        }
    }

    function test_upgradeOracle() public {
        // use a contract with deployed code that is not actually a lens oracle
        address oldLensOracle = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address newLensOracle = address(0x124);
        YearnOracle oracle = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(IYearnLensOracle(oldLensOracle), usdcYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        oracle.upgradeTo(
            address(new YearnOracle(IYearnLensOracle(newLensOracle), usdcYVault))
        );

        assertEq(address(oracle.oracle()), newLensOracle);
    }

    function test_upgradeOracle_revertsOnValidState() public {
        // use a contract with deployed code that is not actually a lens oracle
        address newLensOracle = address(0x124);
        YearnOracle oracle = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(IYearnLensOracle(yearnLensOracle), usdcYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));
        
        address newImplementation = address(new YearnOracle(IYearnLensOracle(newLensOracle), usdcYVault));
        vm.expectRevert(YearnOracle.YearnOracle__authorizeUpgrade_validStatus.selector);
        oracle.upgradeTo(newImplementation);
    }

    function test_upgradeOracle_revertsOnUnauthorized() public {
        // use a contract with deployed code that is not actually a lens oracle
        address oldLensOracle = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address newLensOracle = address(0x124);
        YearnOracle oracle = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(IYearnLensOracle(oldLensOracle), usdcYVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        // make the call as a random address
        vm.startPrank(address(0x12345));
        address newImplementation = address(new YearnOracle(IYearnLensOracle(newLensOracle), usdcYVault));

        vm.expectRevert();
        oracle.upgradeTo(newImplementation);
    }
}
