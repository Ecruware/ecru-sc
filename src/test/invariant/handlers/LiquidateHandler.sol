// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InvariantTestBase} from "../InvariantTestBase.sol";
import {BaseHandler, GhostVariableStorage} from "./BaseHandler.sol";

import {ICDPVaultBase} from "../../../interfaces/ICDPVault.sol";

import {CDM} from "../../../CDM.sol";
import {CDPVault_TypeAWrapper} from "../CDPVault_TypeAWrapper.sol";
import {WAD, wdiv} from "../../../utils/Math.sol";

contract LiquidateHandler is BaseHandler {
    uint256 internal constant COLLATERAL_PER_POSITION = 1_000 ether;
    
    uint256 public immutable creditReserve = 100_000_000_000 ether;
    uint256 public immutable collateralReserve = 100_000_000_000 ether;
    
    uint256 public immutable maxCreateUserAmount = 10;

    uint256 public immutable maxHealthFactor = 2 ether;

    CDM public cdm;
    CDPVault_TypeAWrapper public vault;
    IERC20 public token;

    uint64 internal liquidationRatio;
    uint64 internal targetHealthFactor;

    function liquidationPrice(ICDPVaultBase vault_) internal returns (uint256) {
        return wdiv(vault_.spotPrice(), uint256(liquidationRatio));
    }

    constructor(
        CDPVault_TypeAWrapper vault_, 
        InvariantTestBase testContract_, 
        GhostVariableStorage ghostStorage_,
        uint64 positionLiquidationRatio_,
        uint64 targetHealthFactor_
    ) BaseHandler ("LiquidateHandler", testContract_, ghostStorage_) {
        vault = vault_;
        cdm = CDM(address(vault_.cdm()));
        token = vault.token();
        liquidationRatio = positionLiquidationRatio_;
        targetHealthFactor = targetHealthFactor_;
    }

    function getTargetSelectors() public pure virtual override returns (bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](3);
        names = new string[](3);
        selectors[0] = this.createPosition.selector;
        names[0] = "createPosition";

        selectors[1] = this.liquidateRandom.selector;
        names[1] = "liquidateRandom";

        selectors[2] = this.liquidateAll.selector;
        names[2] = "liquidateAll";
    }

    function createPosition(uint256 healthFactor) public useCurrentTimestamp onlyNonActor("users", msg.sender) {
        trackCallStart(msg.sig);

        // register sender as a user
        address user = msg.sender;
        addActor("users", msg.sender);

        // bound the health factor and calculate collateral and debt
        healthFactor = bound(healthFactor, liquidationRatio, maxHealthFactor);
        uint256 collateral = COLLATERAL_PER_POSITION;
        uint256 debt = wdiv(collateral, healthFactor);
        vault.modifyPermission(user, true);

        // create the position
        vm.prank(user);
        vault.modifyCollateralAndDebt({
            owner:user, 
            collateralizer: address(this), 
            creditor: msg.sender, 
            deltaCollateral: int256(collateral),
            deltaNormalDebt: int256(debt)
        });

        trackCallEnd(msg.sig);
    }

    function liquidateRandom(uint256 randomSeed, uint256 liquidationHealthFactor, bool fullLiquidation) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        address user = getRandomActor("users", randomSeed);
        if(user == address(0)) return;

        liquidationHealthFactor = bound(liquidationHealthFactor, 0, liquidationRatio-1);
        uint256 newSpotPrice = liquidationPrice(vault);
        testContract.setOraclePrice(newSpotPrice);

        address[] memory owners = new address[](1);
        owners[0] = user;
        uint256[] memory repayAmounts = new uint256[](1);
        if(fullLiquidation){
            repayAmounts[0] = type(uint256).max;
        } else {
            // todo compute a random partial amount to be liquidated
            repayAmounts[0] = type(uint256).max;
        }
        
        vault.liquidatePositions(owners, repayAmounts);

        testContract.setOraclePrice(WAD);

        trackCallEnd(msg.sig);
    }

    function liquidateAll() public useCurrentTimestamp() {
        trackCallStart(msg.sig);

        trackCallEnd(msg.sig);
    }

    /// ======== Helper Functions ======== ///

    function _liquidatePosition(address position, uint256 liquidationHealthFactor, bool isFullLiquidation) private {
        liquidationHealthFactor = bound(liquidationHealthFactor, 0, liquidationRatio - 1);
        uint256 newSpotPrice = liquidationPrice(vault);
        testContract.setOraclePrice(newSpotPrice);

        address[] memory owners = new address[](1);
        owners[0] = position;
        uint256[] memory repayAmounts = new uint256[](1);
        if(isFullLiquidation){
            repayAmounts[0] = type(uint256).max;
        } else {
            // todo compute a random partial amount to be liquidated
            repayAmounts[0] = type(uint256).max;
        }
        
        vault.liquidatePositions(owners, repayAmounts);

        testContract.setOraclePrice(WAD);
    }
}