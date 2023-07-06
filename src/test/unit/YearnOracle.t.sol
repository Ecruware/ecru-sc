// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TestBase} from "../TestBase.sol";

import {IYearnLensOracle} from "../../vendor/IYearnLensOracle.sol";
import {IYVault} from "../../vendor/IYVault.sol";

import {YearnOracle} from "../../oracle/YearnOracle.sol";

contract YearnOracleTest is TestBase {
    IYearnLensOracle internal spotOracle = IYearnLensOracle(address(0x123));
    IYVault internal mockYearnVault = IYVault(address(0x456));

    YearnOracle internal yearnOracle;

    function setUp() public override {
        super.setUp();

        vm.mockCall(address(mockYearnVault), abi.encodeWithSelector(IYVault.token.selector), abi.encode(address(0x1)));
        vm.mockCall(address(mockYearnVault), abi.encodeWithSelector(IYVault.getPricePerFullShare.selector), abi.encode(1 ether));
        vm.mockCallRevert(address(mockYearnVault), abi.encodeWithSelector(IYVault.pricePerShare.selector), abi.encode(1 ether));
        vm.mockCall(address(mockYearnVault), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
        vm.mockCall(address(0x1), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18)));
        yearnOracle = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(spotOracle, mockYearnVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));
    }

    function test_deployOracle() public {
        assertTrue(address(yearnOracle) != address(0));
    }

    function test_deployOracle_revertsOnInvalidVault() public {
        // redeploy the oracle with an invalid vault
        vm.mockCallRevert(address(mockYearnVault), abi.encodeWithSelector(IYVault.pricePerShare.selector), abi.encode(1 ether));
        vm.mockCallRevert(address(mockYearnVault), abi.encodeWithSelector(IYVault.getPricePerFullShare.selector), abi.encode(1 ether));

        vm.expectRevert(abi.encodeWithSelector(YearnOracle.YearnOracle__isV1Vault_invalidYearnVault.selector));
        new YearnOracle(spotOracle, mockYearnVault);
    }

    function test_oracle() public {
        assertTrue(address(yearnOracle.oracle()) != address(0));
    }

    function test_vaultTokenAddress() public {
        assertTrue(address(yearnOracle.vaultTokenAddress()) != address(0));
    }

    function test_underlyingScale() public {
        assertEq(yearnOracle.vaultTokenScale(), 1e18);
    }

    function test_getStatus() public {
        // set a valid price
        vm.mockCall(address(spotOracle), abi.encodeWithSelector(IYearnLensOracle.getPriceUsdcRecommended.selector, address(0x1)), abi.encode(1e18));
        assertTrue(yearnOracle.getStatus(address(0)));
    }

    function test_getStatus_returnsFalseOnStaleValue() public {
        // set 0 as the price
        vm.mockCall(address(spotOracle), abi.encodeWithSelector(IYearnLensOracle.getPriceUsdcRecommended.selector, address(0x1)), abi.encode(uint256(0)));
        assertTrue(yearnOracle.getStatus(address(0)) == false);
    }

    function test_isV1Vault_false() public {
        assertTrue(yearnOracle.isV1Vault());

        // redeploy the oracle with an v2 vault
        vm.mockCall(address(mockYearnVault), abi.encodeWithSelector(IYVault.pricePerShare.selector), abi.encode(1 ether));
        vm.mockCallRevert(address(mockYearnVault), abi.encodeWithSelector(IYVault.getPricePerFullShare.selector), abi.encode(1 ether));

        // deploy the oracle with a v2 vault
        yearnOracle = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(spotOracle, mockYearnVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        assertTrue(yearnOracle.isV1Vault() == false);

        IYVault vault = yearnOracle.vault();
        vm.expectRevert();
        vault.getPricePerFullShare();
    }

    function test_isV1Vault_true() public {
        assertTrue(yearnOracle.isV1Vault() == true);
        IYVault vault = yearnOracle.vault();
        vm.expectRevert();
        vault.pricePerShare();
    }

    function test_spot_v1() public {
        uint256 expectedSpot = 1e18;
        uint256 usdcPrice = 1e6;
        vm.mockCall(address(spotOracle), abi.encodeWithSelector(IYearnLensOracle.getPriceUsdcRecommended.selector, address(0x1)), abi.encode(usdcPrice));
        uint256 spot = yearnOracle.spot(address(0x1));
        assertEq(spot, expectedSpot);
    }

    function test_spot_v2() public {
        uint256 expectedSpot = 1e18;
        uint256 usdcPrice = 1e6;
        vm.mockCall(address(mockYearnVault), abi.encodeWithSelector(IYVault.pricePerShare.selector), abi.encode(1 ether));
        vm.mockCall(address(mockYearnVault), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));
        vm.mockCallRevert(address(mockYearnVault), abi.encodeWithSelector(IYVault.getPricePerFullShare.selector), abi.encode(1 ether));
        vm.mockCall(address(spotOracle), abi.encodeWithSelector(IYearnLensOracle.getPriceUsdcRecommended.selector, address(0x1)), abi.encode(usdcPrice));

        // deploy the oracle with a v2 vault
        yearnOracle = YearnOracle(address(new ERC1967Proxy(
            address(new YearnOracle(spotOracle, mockYearnVault)),
            abi.encodeWithSelector(YearnOracle.initialize.selector, address(this), address(this))
        )));

        assertEq(yearnOracle.vaultTokenScale(), 1e18);
        assertEq(yearnOracle.isV1Vault(), false);

        uint256 spot = yearnOracle.spot(address(0x1));
        assertEq(spot, expectedSpot);
    }

    function test_spot_revertOnInvalidValue() public {
        uint256 usdcPrice = 0;
        vm.mockCall(address(spotOracle), abi.encodeWithSelector(IYearnLensOracle.getPriceUsdcRecommended.selector, address(0x1)), abi.encode(usdcPrice));

        vm.expectRevert(YearnOracle.YearnOracle__spot_invalidValue.selector);
        yearnOracle.spot(address(0x1));
    }
}
