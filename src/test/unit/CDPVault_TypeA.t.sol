// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {WAD, toInt256, wmul, wdiv} from "../../utils/Math.sol";
import {CDM} from "../../CDM.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";
import {Buffer} from "../../Buffer.sol";

contract CDPVault_TypeATest is TestBase {

    function setUp() public override {
        super.setUp();
        oracle.updateSpot(address(token), WAD);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _virtualDebt(CDPVault_TypeA vault, address position) internal view returns (uint256) {
        (, uint256 normalDebt) = vault.positions(position);
        (uint64 rateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(position);
        return wmul(rateAccumulator, normalDebt) - accruedRebate;
    }

    function _depositCash(CDPVault_TypeA vault, uint256 amount) internal {
        token.mint(address(this), amount);
        uint256 cashBefore = vault.cash(address(this));
        token.approve(address(vault), amount);
        vault.deposit(address(this), amount);
        assertEq(vault.cash(address(this)), cashBefore + amount);
    }

    function _modifyCollateralAndDebt(CDPVault_TypeA vault, int256 collateral, int256 normalDebt) internal {
        uint256 vaultDebtBefore = debt(address(vault));
        uint256 vaultCreditBefore = credit(address(vault));
        (uint256 collateralBefore, uint256 normalDebtBefore) = vault.positions(address(this));
        uint256 debtBefore = _virtualDebt(vault, address(this));
        uint256 creditBefore = credit(address(this));
        
        vault.modifyCollateralAndDebt(address(this), address(this), address(this), collateral, normalDebt);
        
        {
        (uint256 collateralAfter, uint256 normalDebtAfter) = vault.positions(address(this));
        assertEq(toInt256(collateralAfter), toInt256(collateralBefore) + collateral);
        assertEq(toInt256(normalDebtAfter), toInt256(normalDebtBefore) + normalDebt);
        }
        
        uint256 debtAfter = _virtualDebt(vault, address(this));
        int256 deltaDebt = toInt256(debtAfter) - toInt256(debtBefore);
        {
        uint256 creditAfter = credit(address(this));
        assertEq(toInt256(creditAfter), toInt256(creditBefore) + deltaDebt);
        }
        
        uint256 vaultDebtAfter = debt(address(vault));
        uint256 vaultCreditAfter = credit(address(vault));
        assertEq(toInt256(vaultCreditBefore + vaultDebtAfter), toInt256(vaultCreditAfter + vaultDebtBefore) + deltaDebt);
    }

    function _updateSpot(uint256 price) internal {
        oracle.updateSpot(address(token), price);
    }

    function _liquidate(CDPVault_TypeA vault, address owner, uint256 amount) internal {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256 tokenBefore = token.balanceOf(address(this));
        vault.liquidatePositions(owners, amounts);
        uint256 tokenAfter = token.balanceOf(address(this));
        assertLt(tokenBefore - tokenAfter, amount);
    }

    function _collateralizationRatio(CDPVault_TypeA vault) internal returns (uint256) {
        (uint256 collateral,) = vault.positions(address(this));
        if (collateral == 0) return type(uint256).max;
        return wdiv(wmul(collateral, vault.spotPrice()), _virtualDebt(vault, address(this)));
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_liquidatePositions_revertOnSafePosition() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        address[] memory owners = new address[](1);
        owners[0] = address(this);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 40 ether;

        vm.expectRevert(CDPVault_TypeA.CDPVault__liquidatePosition_notUnsafe.selector);
        vault.liquidatePositions(owners, amounts);
    }

    function test_liquidatePositions_revertOnInvalidSpotPrice() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        address[] memory owners = new address[](1);
        owners[0] = address(this);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 40 ether;

        _updateSpot(0);

        vm.expectRevert(CDPVault_TypeA.CDPVault__liquidatePosition_notUnsafe.selector);
        vault.liquidatePositions(owners, amounts);
    }

    function test_liquidatePositions_revertsOnInvalidArguments() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        address[] memory owners = new address[](2);
        owners[0] = address(this);
        owners[1] = address(this);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 40 ether;

        vm.expectRevert(CDPVault_TypeA.CDPVault__liquidatePositions_argLengthMismatch.selector);
        vault.liquidatePositions(owners, amounts);
    }

    /*//////////////////////////////////////////////////////////////
             SCENARIO: PARTIAL LIQUIDATION OF RESERVE VAULT
    //////////////////////////////////////////////////////////////*/
    
    // Case 1a: Fraction of maxDebtToRecover is repaid (position doesn't get to target)
    function test_reserve_liquidate_partial_1a() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);
        // liquidate position
        _updateSpot(0.80 ether);
        _liquidate(vault, address(this), 40 ether);

        assertEq(debt(address(vault)), 40 ether); // debt - repayAmount
        assertEq(vault.cash(address(this)), 50 ether);
        assertEq(credit(address(this)), 40 ether); // creditBefore - repayAmount
        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 50 ether);
        assertEq(normalDebt, 40 ether);
        assertEq(_collateralizationRatio(vault), 1 ether);
    }

    // Case 1b: Same as Case 1a but multiple liquidation calls
    function test_reserve_liquidate_partial_1b() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);
        // liquidate position
        _updateSpot(0.90 ether);
        _liquidate(vault, address(this), 10 ether); // 48 ether
        _liquidate(vault, address(this), 30 ether); // 38 ether

        assertLt(_collateralizationRatio(vault), wmul(uint256(1.25 ether), uint256(1.05 ether))); // == 125%
    }

    // Case 1c: Same as Case 1a but liquidationDiscount is applied
    function test_reserve_liquidate_partial_1c() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 0.95 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.90 ether);
        _liquidate(vault, address(this), 40 ether);

        assertEq(debt(address(vault)), 40 ether);

        assertApproxEqAbs(vault.cash(address(this)), 46.783 ether, 0.001 ether); // 40 / (0.9 * 0.95)
        assertEq(credit(address(this)), 40 ether); // creditBefore - repayAmount

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 100 ether - vault.cash(address(this))); // position.collateral - cash == 53.216
        assertEq(normalDebt, 40 ether);
    }

    // Case 1d: Same as Case 1a but liquidationPenalty is applied
    function test_reserve_liquidate_partial_1d() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 0.95 ether, 1 ether, 1.05 ether,0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.90 ether);
        _liquidate(vault, address(this), 40 ether);

        assertEq(debt(address(vault)), 40 ether);

        assertApproxEqAbs(vault.cash(address(this)), 44.4444 ether, 0.001 ether); // (40) / (0.9) or (40 * 0.95) / (0.9) ?
        assertEq(credit(address(this)), 40 ether); // creditBefore - repayAmount

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 100 ether - vault.cash(address(this))); // position.collateral - cash
        assertEq(normalDebt, 42 ether); // position.normalDebt - (repayAmount * penalty)
    }

    // Case 2: Entire maxDebtToRecover is repaid (position gets to target collateralizationRatio)
    function test_reserve_liquidate_partial_2() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);
        // liquidate position
        _updateSpot(0.99 ether);
        _liquidate(vault, address(this), 40 ether); // 19.2 ether

        assertEq(_collateralizationRatio(vault), wmul(uint256(1.25 ether), uint256(1.05 ether))); // == 131.25%
    }

    /*//////////////////////////////////////////////////////////////
              SCENARIO: FULL LIQUIDATION OF RESERVE VAULT
    //////////////////////////////////////////////////////////////*/

    // Case 1a: Entire debt is repaid and no bad debt has accrued (no fee - self liquidation) 
    function test_reserve_liquidate_full_1a() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.80 ether);
        _liquidate(vault, address(this), 80 ether);

        assertEq(debt(address(vault)), 0 ether);

        assertEq(vault.cash(address(this)), 100 ether);
        assertEq(credit(address(this)), 0); // creditBefore - (collateral * price)

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    // Case 2: Entire debt is repaid and bad debt has accrued, which is bailed out by the Buffer - no penalty
    function test_reserve_liquidate_full_2() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.1 ether);
        _liquidate(vault, address(this), 70 ether); // 10 ether

        assertEq(debt(address(vault)), 0); // debt + (position.debt - repayAmount) - bailOut
        assertEq(debt(address(buffer)), 70 ether); // position.debt - repayAmount

        assertEq(vault.cash(address(this)), 100 ether); // repayAmount / price or position.collateral
        assertEq(credit(address(this)), 70 ether); // creditBefore - (collateral * price)

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    // Case 2b: Entire debt is repaid and bad debt has accrued, which is bailed out by the Buffer - debt ceiling
    function test_reserve_liquidate_full_2b() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        cdm.setParameter(address(buffer), "debtCeiling", 60 ether);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.1 ether);
        _liquidate(vault, address(this), 70 ether); // 10 ether

        assertEq(debt(address(vault)), 10 ether); // debt + (position.debt - repayAmount) - bailOut
        assertEq(debt(address(buffer)), 60 ether); // position.debt - repayAmount

        assertEq(vault.cash(address(this)), 100 ether); // repayAmount / price or position.collateral
        assertEq(credit(address(this)), 70 ether); // creditBefore - (collateral * price)

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    // Case 2c: Entire debt is repaid and bad debt has accrued, which is bailed out by the Buffer - global debt ceiling
    function test_reserve_liquidate_full_2c() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        cdm.setParameter("globalDebtCeiling", 130 ether);

        // liquidate position
        _updateSpot(0.1 ether);
        _liquidate(vault, address(this), 70 ether); // 10 ether

        assertEq(debt(address(vault)), 10 ether); // debt + (position.debt - repayAmount) - bailOut
        assertEq(debt(address(buffer)), 60 ether); // position.debt - repayAmount

        assertEq(vault.cash(address(this)), 100 ether); // repayAmount / price or position.collateral
        assertEq(credit(address(this)), 70 ether); // creditBefore - (collateral * price)

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    // Case 3: Entire debt is repaid and accrued bad debt is bailed out by the Buffer - with penalty
    function test_reserve_liquidate_full_3() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 0, 1.25 ether, 0.95 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.395 ether);
        _liquidate(vault, address(this), 40 ether); // 39.5 ether
        
        assertEq(debt(address(vault)), 0); // debt + (position.debt - repayAmount) - bailOut
        assertEq(debt(address(buffer)), 42.475 ether); // position.debt - (repayAmount * penalty)

        assertEq(vault.cash(address(this)), 100 ether); // repayAmount / price or position.collateral
        assertEq(credit(address(this)), 40.5 ether); // creditBefore - repayAmount

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    // Case 4: Entire debt is repaid and debt floor is not met, user pays more than specified
    function test_reserve_liquidate_full_4() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 150 ether, 10 ether, 1.5 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);

        // create position
        _depositCash(vault, 15 ether);
        _modifyCollateralAndDebt(vault, 15 ether, 10 ether);

        // liquidate position
        _updateSpot(1.0 ether - 1);
        createCredit(address(this), 5 ether);
        _liquidate(vault, address(this), 10 ether - 1); // 15 ether * price

        assertEq(debt(address(vault)), 10 ether);
        assertEq(debt(address(buffer)), 0);

        assertEq(vault.cash(address(this)), 0);
        assertEq(credit(address(this)), 15 ether);

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 15 ether);
        assertEq(normalDebt, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
            SCENARIO: FULL LIQUIDATION OF NON-RESERVE VAULT
    //////////////////////////////////////////////////////////////*/

    function test_non_reserve_liquidate_full() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 0, 0, 1.25 ether, 1 ether, 1 ether, 1.05 ether, 0, WAD, WAD, 0, 0);
        buffer.revokeRole(keccak256("BAIL_OUT_QUALIFIER_ROLE"), address(vault));

        // delegate 150 credit to CDPVault_TypeA
        createCredit(address(this), 150 ether);
        vault.delegateCredit(150 ether);

        // create position
        _depositCash(vault, 100 ether);
        _modifyCollateralAndDebt(vault, 100 ether, 80 ether);

        // liquidate position
        _updateSpot(0.1 ether);
        _liquidate(vault, address(this), 70 ether);

        assertEq(vault.cash(address(this)), 100 ether);
        assertEq(credit(address(this)), 70 ether); // creditBefore - (collateral * price)

        (uint256 collateral, uint256 normalDebt) = vault.positions(address(this));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }
}
