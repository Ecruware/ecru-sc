// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {WAD, wmul, wdiv} from "../../utils/Math.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";
import {IVault} from "../../vendor/IBalancerVault.sol";
import {AuraVault} from "../../vendor/AuraVault.sol";

interface IBalancerComposableStablePool{
    function getActualSupply() external returns (uint256);
}

contract AuraVaultTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    bytes32 wstETH_WETH_PoolId = 0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2;
    ERC20 wstETH_WETH_BPT = ERC20(address(0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD));
    address BAL = 0xba100000625a3754423978a60c9317c58a424e3D;

    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    ERC4626 constant auraRewardsPool = ERC4626(0x2a14dB8D09dB0542f6A371c0cB308A768227D67D);

    AuraVault auraVault;

    function setUp() public override {
        super.setUp();

        auraVault = new AuraVault({
            rewardPool_: address(auraRewardsPool),
            asset_ : address(wstETH_WETH_BPT),
            feed_: address(oracle),
            maxClaimerIncentive_: 100,
            maxLockerIncentive_: 100,
            stalePeriod_: 1 days,
            tokenName_:  "Aura Vault",
            tokenSymbol_: "auraVault"
        });

        uint256 balancerTokenRate = _getBalancerTokenRateInUSD();
        oracle.updateSpot(address(wstETH_WETH_BPT), balancerTokenRate);
        oracle.updateSpot(address(auraVault), balancerTokenRate);
        oracle.updateSpot(address(stablecoin), _getStablecoinRateInUSD());

        vm.label(BALANCER_VAULT, "balancer");
        vm.label(wstETH, "wstETH");
        vm.label(address(wstETH_WETH_BPT), "wstETH-WETH-BPT");
        vm.label(BAL, "BAL");
        vm.label(address(auraVault), "auraVault");
        vm.label(address(auraRewardsPool), "auraRewardsPool");
    }

    function test_deploy() public {
        assertNotEq(address(auraVault), address(0));
    }

    function test_deposit() public {
        uint256 amount = 1000 ether;
        
        assertEq(auraVault.balanceOf(address(this)), 0);
        assertEq(auraVault.totalSupply(), 0);
        assertEq(auraVault.totalAssets(), 0);
        
        address user = address(0x1234);
        deal(address(wstETH_WETH_BPT), address(this), amount);
        wstETH_WETH_BPT.safeApprove(address(auraVault), amount);
        auraVault.deposit(amount, user);

        assertEq(auraVault.balanceOf(address(this)), 0);
        assertEq(auraVault.balanceOf(address(user)), amount);
        assertEq(auraVault.totalSupply(), amount);
        assertEq(auraVault.totalAssets(), amount);
    }

    function test_mint() public {
        uint256 amount = 1000 ether;
        
        assertEq(auraVault.balanceOf(address(this)), 0);
        assertEq(auraVault.totalSupply(), 0);
        assertEq(auraVault.totalAssets(), 0);
        
        address user = address(0x1234);
        deal(address(wstETH_WETH_BPT), address(this), amount);
        wstETH_WETH_BPT.safeApprove(address(auraVault), amount);
        auraVault.mint(amount, user);

        assertEq(auraVault.balanceOf(address(this)), 0);
        assertEq(auraVault.balanceOf(address(user)), amount);
        assertEq(auraVault.totalSupply(), amount);
        assertEq(auraVault.totalAssets(), amount);
    }

    function test_withdraw() public {
        uint256 assets = 1000 ether;
        address user = address(0x1234);
        deal(address(wstETH_WETH_BPT), address(this), assets);
        wstETH_WETH_BPT.safeApprove(address(auraVault), assets);
        uint256 shares = auraVault.deposit(assets, user);

        assertEq(wstETH_WETH_BPT.balanceOf(address(user)), 0);
        assertEq(auraVault.balanceOf(address(user)), shares);
        vm.prank(user);
        auraVault.withdraw(assets, user, user);
        assertEq(wstETH_WETH_BPT.balanceOf(address(user)), assets);
        assertEq(auraVault.balanceOf(address(user)), 0);
    }

    function test_redeem() public {
        uint256 assets = 1000 ether;
        address user = address(0x1234);
        deal(address(wstETH_WETH_BPT), address(this), assets);
        wstETH_WETH_BPT.safeApprove(address(auraVault), assets);
        uint256 shares = auraVault.deposit(assets, user);

        assertEq(wstETH_WETH_BPT.balanceOf(address(user)), 0);
        assertEq(auraVault.balanceOf(address(user)), shares);
        vm.prank(user);
        auraVault.redeem(shares, user, user);
        assertEq(wstETH_WETH_BPT.balanceOf(address(user)), assets);
        assertEq(auraVault.balanceOf(address(user)), 0);
    }

    /// @dev Helper function that returns the lp token rate in USD
    function _getBalancerTokenRateInUSD() internal returns (uint256 price) {
        (, uint256[] memory balances, ) = IVault(BALANCER_VAULT).getPoolTokens(wstETH_WETH_PoolId);
        uint256 tokenWSTETHSupply = wmul(balances[0], _getWstETHRateInUSD());
        uint256 tokenWETHSupply = wmul(balances[2], _getWETHRateInUSD());
        uint256 totalSupply = IBalancerComposableStablePool(address(wstETH_WETH_BPT)).getActualSupply();

        return wdiv(tokenWSTETHSupply + tokenWETHSupply, totalSupply);
    }

    function getForkBlockNumber() internal virtual override(IntegrationTestBase) pure returns (uint256){
        return 0; //Sep-18-2023 04:06:35 PM +UTC    
    }
}