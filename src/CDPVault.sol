// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBuffer} from "./interfaces/IBuffer.sol";
import {ICDM} from "./interfaces/ICDM.sol";
import {ICDPVaultBase} from "./interfaces/ICDPVault.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ICDPVault_FactoryBase} from "./interfaces/ICDPVault_FactoryBase.sol";

import {WAD, toInt256, toUint64, max, min, add, sub, wmul, wdiv, wmulUp} from "./utils/Math.sol";
import {DoubleLinkedList} from "./utils/DoubleLinkedList.sol";
import {Permission} from "./utils/Permission.sol";
import {Pause} from "./utils/Pause.sol";

import {getCredit, getDebt, getCreditLine} from "./CDM.sol";
import {InterestRateModel} from "./InterestRateModel.sol";

// Authenticated Roles
bytes32 constant VAULT_CONFIG_ROLE = keccak256("VAULT_CONFIG_ROLE");
bytes32 constant TICK_MANAGER_ROLE = keccak256("TICK_MANAGER_ROLE");
bytes32 constant VAULT_UNWINDER_ROLE = keccak256("VAULT_UNWINDER_ROLE");

/// @notice Calculates the actual debt from a normalized debt amount
/// @param normalDebt Normalized debt (either of a position or the total normalized debt)
/// @param rateAccumulator Global rate accumulator
/// @param accruedRebate Accrued rebate
/// @return debt Actual debt [wad]
function calculateDebt(
    uint256 normalDebt,
    uint64 rateAccumulator,
    uint256 accruedRebate
) pure returns (uint256 debt) {
    debt = wmul(normalDebt, rateAccumulator) - accruedRebate;
}

/// @notice Calculates the normalized debt from an actual debt amount
/// @param debt Actual debt (either of a position or the total debt)
/// @param rateAccumulator Global rate accumulator
/// @param accruedRebate Accrued rebate
/// @return normalDebt Normalized debt [wad]
function calculateNormalDebt(
    uint256 debt,
    uint64 rateAccumulator,
    uint256 accruedRebate
) pure returns (uint256 normalDebt) {
    normalDebt = wdiv(debt + accruedRebate, rateAccumulator);

    // account for rounding errors due to division
    if (calculateDebt(normalDebt, rateAccumulator, accruedRebate) < debt) {
        unchecked { ++normalDebt; }
    }
}

/// @title CDPVault
/// @notice Base logic of a CDP-style vault for depositing collateral and drawing credit against it
abstract contract CDPVault is AccessControl, Pause, Permission, InterestRateModel, ICDPVaultBase {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using DoubleLinkedList for DoubleLinkedList.List;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // CDPVault Parameters
    /// @notice CDM (Credit and Debt Manager)
    ICDM public immutable cdm;
    /// @notice Oracle of the collateral token
    IOracle public immutable oracle;
    /// @notice Global surplus and debt Buffer
    IBuffer public immutable buffer;
    /// @notice collateral token
    IERC20 public immutable token;
    /// @notice Collateral token's decimals scale (10 ** decimals)
    uint256 public immutable tokenScale;
    /// @notice Portion of interest that goes to the protocol [wad]
    uint256 public immutable protocolFee;

    /// @notice Utilization Rate Parameters
    /// @dev The utilizationParams field contains packed utilization rate parameters.
    /// - targetUtilizationRatio: Targeted utilization ratio [0-1) [wad] [uint64]
    /// - maxUtilizationRatio: Maximum utilization ratio [0-1] [wad] [uint64]
    /// - minInterestRate: Minimum allowed interest rate [wad] [uint40]
    /// - maxInterestRate: Maximum allowed interest rate [wad] [uint40]
    /// - targetInterestRate: Targeted interest rate [wad] [uint40]
    ///
    /// Interest rate fields are packed as uint40 values to fit within the utilizationParams field.
    /// Each interest rate field represents an annual per-second value between [1, RATE_CEILING]
    /// as declared in the InterestRateModel. To accommodate this range, an offset of 1 is applied
    /// when packing the fields. When unpacking, the offset needs to be reversed to obtain the original values.
    uint256 internal immutable utilizationParams;

    /// @notice Rebate Parameters
    /// @dev Contains the following parameters evenly packed into a uint256:
    ///   - rebateRate:  Price tick to rebate factor conversion bias [wad]
    ///   - maxRebate:   Max. allowed rebate factor (> 1.0) [wad]
    uint256 internal immutable rebateParams;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct VaultConfig {
        /// @notice Min. amount of debt that has to be generated by a position [wad]
        uint128 debtFloor;
        /// @notice Collateralization ratio below which a position can be liquidated [wad]
        uint64 liquidationRatio;
        /// @notice Collateralization ratio below which the vault enters the emergency mode [wad]
        uint64 globalLiquidationRatio;
    }
    /// @notice CDPVault configuration
    VaultConfig public vaultConfig;

    // CDPVault Accounting
    /// @notice Sum of backed normalized debt over all positions [wad]
    uint256 public totalNormalDebt;
    /// @notice Total current amount of accrued protocol fees [wad]
    uint256 public totalAccruedFees;

    // Cash Accounting
    /// @notice Map specifying the cash balances a user has [wad]
    mapping(address owner => uint256 balance) public cash;

    // Position Accounting
    struct Position {
        uint256 collateral; // [wad]
        uint256 normalDebt; // [wad]
    }
    /// @notice Map of user positions
    mapping(address owner => Position) public positions;

    // Redemptions
    /// @notice Map specifying if a given price tick is active [wad]
    mapping(uint256 priceTick => bool isActive) public activeLimitPriceTicks;
    /// @notice Sorted linked list of active price ticks (from head to tail <> lowest to highest) [wad]
    DoubleLinkedList.List internal _limitPriceTicks;
    /// @notice Map of each price ticks limit order queue, sorted by FIFO (from head to tail <> oldest to newest) [wad]
    mapping(uint256 priceTick => DoubleLinkedList.List queue) internal _limitOrderQueue;
    /// @notice Map of limit order makers
    mapping(uint256 limitOrderId => uint256 priceTick) public limitOrders;
    /// @notice Minimum principal amount of a limit order [wad]
    uint256 public limitOrderFloor;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event ModifyPosition(
        address indexed position,
        int256 deltaCollateral,
        int256 deltaNormalDebt,
        uint256 totalNormalDebt
    );
    event ModifyCollateralAndDebt(
        address indexed position,
        address indexed collateralizer,
        address indexed creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    );
    event AddLimitPriceTick(uint256 indexed limitPriceTick);
    event RemoveLimitPriceTick(uint256 indexed limitPriceTick);
    event CreateLimitOrder(uint256 indexed limitPriceTick, address indexed maker);
    event CancelLimitOrder(uint256 indexed limitPriceTick, address indexed maker);
    event ExecuteLimitOrder(
        uint256 indexed limitPriceTick,
        uint256 indexed limitOrderId,
        uint256 collateralRedeemed,
        uint256 creditExchanged
    );
    event Exchange(address indexed redeemer, uint256 creditExchanged, uint256 collateralRedeemed);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVault__checkEmergencyMode_entered();
    error CDPVault__modifyPosition_debtFloor();
    error CDPVault__modifyCollateralAndDebt_notSafe();
    error CDPVault__modifyCollateralAndDebt_noPermission();
    error CDPVault__modifyCollateralAndDebt_maxUtilizationRatio();
    error CDPVault__addLimitPriceTick_limitPriceTickOutOfRange();
    error CDPVault__addLimitPriceTick_invalidPriceTickOrder();
    error CDPVault__createLimitOrder_limitPriceTickNotActive();
    error CDPVault__createLimitOrder_limitOrderFloor();
    error CDPVault__createLimitOrder_limitOrderAlreadyExists();
    error CDPVault__cancelLimitOrder_limitOrderDoesNotExist();
    error CDPVault__exchange_notEnoughExchanged();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address factory) {
        (
            cdm,
            oracle,
            buffer,
            token,
            tokenScale,
            protocolFee,
            utilizationParams,
            rebateParams
        ) = ICDPVault_FactoryBase(factory).getConstants();
    }

    function setUp() public virtual {
        GlobalIRS memory globalIRS = getGlobalIRS();
        if (globalIRS.lastUpdated != 0) revert();

        // Access Control Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // initialize globalIRS
        globalIRS.lastUpdated = uint64(block.timestamp);
        globalIRS.rateAccumulator = uint64(WAD);
        _setGlobalIRS(globalIRS);
    }

    /*//////////////////////////////////////////////////////////////
                             EMERGENCY MODE
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks whether global collateralization ratio is below the emergency threshold
    function _enteredEmergencyMode(
        uint64 globalLiquidationRatio,
        uint256 spotPrice_,
        uint256 totalNormalDebt_,
        uint64 rateAccumulator,
        uint256 globalAccruedRebate
    ) internal view returns (bool) {
        uint256 totalDebt = calculateDebt(totalNormalDebt_, rateAccumulator, globalAccruedRebate);
        if (
            totalDebt != 0 && wdiv((token.balanceOf(address(this)) * spotPrice_ / tokenScale), totalDebt)
                < uint256(globalLiquidationRatio)
        ) return true;
        return false;
    }

    /// @notice Checks whether global collateralization ratio is below the emergency threshold
    /// @dev If global collateralization ratio is below the emergency threshold it will revert
    function _checkEmergencyMode(
        uint64 globalLiquidationRatio,
        uint256 spotPrice_,
        uint256 totalNormalDebt_,
        uint64 rateAccumulator,
        uint256 globalAccruedRebate
    ) internal view {
        if (_enteredEmergencyMode(
            globalLiquidationRatio, spotPrice_, totalNormalDebt_, rateAccumulator, globalAccruedRebate
        )) revert CDPVault__checkEmergencyMode_entered();
    }

    /// @notice Triggers the emergency mode by pausing the vault if global collateralization ratio is below
    /// the emergency threshold
    /// @dev This method will revert if the vault has already been paused
    function enterEmergencyMode() external whenNotPaused {
        (uint64 rateAccumulator,, uint256 globalAccruedRebate) = virtualIRS(address(0));
        if (_enteredEmergencyMode(
            vaultConfig.globalLiquidationRatio, spotPrice(), totalNormalDebt, rateAccumulator, globalAccruedRebate
        )) _pause();
    }

    /*//////////////////////////////////////////////////////////////
                      CASH BALANCE ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits collateral tokens into this contract and increases a users cash balance
    /// @dev The caller needs to approve this contract to transfer tokens on their behalf
    /// @param to Address of the user to attribute the cash to
    /// @param amount Amount of tokens to deposit [tokenScale]
    /// @return cashAmount Amount of cash deposited [wad]
    function deposit(address to, uint256 amount) external whenNotPaused returns (uint256 cashAmount) {
        token.safeTransferFrom(msg.sender, address(this), amount);
        cashAmount = wdiv(amount, tokenScale);
        cash[to] += cashAmount;
    }

    /// @notice Withdraws collateral tokens from this contract and decreases a users cash balance
    /// @param to Address of the user to withdraw tokens to
    /// @param amount Amount of tokens to withdraw [wad]
    /// @return tokenAmount Amount of tokens withdrawn [tokenScale]
    function withdraw(address to, uint256 amount) external whenNotPaused returns (uint256 tokenAmount) {
        cash[msg.sender] -= amount;
        tokenAmount = wmul(amount, tokenScale);
        token.safeTransfer(to, tokenAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTEREST COLLECTION
    //////////////////////////////////////////////////////////////*/

    function _calculateUtilizationRatio(
        GlobalIRS memory globalIRS, uint256 totalNormalDebt_
    ) internal view returns (uint256 utilizationRatio) {
        uint256 totalDebt_ = calculateDebt(totalNormalDebt_, globalIRS.rateAccumulator, globalIRS.globalAccruedRebate);
        utilizationRatio = (totalDebt_ == 0)
            ? 0 : wdiv(totalDebt_, totalDebt_ + cdm.creditLine(address(this)) - totalAccruedFees);
    }

    /// @notice Calculates the global rate accumulator based on the current global interest rate state
    function _calculateRateAccumulator(
        GlobalIRS memory globalIRS, uint256 totalNormalDebt_
    ) internal view returns (uint64) {
        uint64 interestRate;
        if(globalIRS.baseRate < 0){
            // unpack the utilizationParams
            uint256 targetUtilizationRatio = uint64(utilizationParams);
            uint256 maxUtilizationRatio = uint64(utilizationParams >> 64);
            uint256 minInterestRate = uint40(utilizationParams >> 128);
            uint256 maxInterestRate = uint40(utilizationParams >> 168);
            uint256 targetInterestRate = uint40(utilizationParams >> 208);
            // add 1 to the rates since they are encoded as percentages
            unchecked {
                minInterestRate += WAD;
                targetInterestRate += WAD;
                maxInterestRate += WAD;
            }

            // derive interest rate from utilization
            uint256 utilizationRatio = _calculateUtilizationRatio(globalIRS, totalNormalDebt_);
            if(utilizationRatio > maxUtilizationRatio) utilizationRatio = maxUtilizationRatio;

            // if utilization is below the optimal utilization ratio,
            // the interest rate is scaled linearly between the minimum and target base rate
            if (utilizationRatio <= targetUtilizationRatio){
                interestRate = uint64(minInterestRate + wmul(
                    wdiv(targetInterestRate - minInterestRate, targetUtilizationRatio),
                    utilizationRatio
                ));
            // if utilization is above the optimal utilization ratio,
            // the interest rate is scaled linearly between the target and maximum base rate
            } else {
                interestRate = uint64(targetInterestRate + wmul(
                    wdiv(maxInterestRate - targetInterestRate, WAD - targetUtilizationRatio), 
                    utilizationRatio - targetUtilizationRatio
                ));
            }
        } else {
            interestRate = uint64(globalIRS.baseRate);
        }
        return super._calculateRateAccumulator(globalIRS, interestRate);
    }

    /// @notice Account for the accrued protocol fees
    function _collectFees(uint256 accruedInterest) internal whenNotPaused returns (uint256) {
        return totalAccruedFees += wmul(accruedInterest, protocolFee);
    }

    /// @notice Returns the current global rate accumulator, global accrued rebate and the accrued rebate of a position
    /// @param position Address of the position to return the accrued rebate for
    /// @return rateAccumulator Current global rate accumulator [wad]
    /// @return accruedRebate The accrued rebate of a position [wad]
    /// @return globalAccruedRebate The global accrued rebate [wad]
    function virtualIRS(address position) public view override returns (
        uint64 rateAccumulator, uint256 accruedRebate, uint256 globalAccruedRebate
    ) {
        GlobalIRS memory globalIRS = getGlobalIRS();
        uint256 totalNormalDebt_ = totalNormalDebt;
        rateAccumulator = _calculateRateAccumulator(globalIRS, totalNormalDebt_);
        (globalIRS, ) = _calculateGlobalIRS(globalIRS, rateAccumulator, totalNormalDebt_, 0, 0, 0, 0, 0);
        globalAccruedRebate = globalIRS.globalAccruedRebate;
        if (position != address(0)){
            accruedRebate = _calculateAccruedRebate(
                getPositionIRS(position), rateAccumulator, positions[position].normalDebt
            );
        }
    }

    /// @notice Sends accrued protocol fees to the Buffer
    function claimFees() external returns (uint256 feesClaimed) {
        feesClaimed = totalAccruedFees;
        totalAccruedFees = 0;
        cdm.modifyBalance(address(this), address(buffer), feesClaimed);
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current spot price of the collateral token
    /// @return _ Current spot price of the collateral token [wad]
    function spotPrice() public view returns (uint256) {
        return oracle.spot(address(token));
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal helper method which bundles the following chores:
    ///   1. update the position's limit order
    ///   2. store the position's new interest rate state
    ///   3. calculate the new global interest rate state
    /// This method is called by `_updateLimitOrderAndIRS`,`_executeLimitOrder` and `_liquidatePosition`
    /// @dev If `initialRebateFactor` is not set, it will indicate no change to the position's rebate factor
    function _updateLimitOrderAndPositionIRSAndCalculateGlobalIRS(
        address owner,
        GlobalIRS memory globalIRS,
        PositionIRS memory positionIRS,
        uint256 totalNormalDebtBefore,
        uint256 normalDebtBefore,
        int256 deltaNormalDebt,
        uint128 claimedRebate,
        uint64 initialRebateFactor
    ) internal returns (GlobalIRS memory globalIRS_, uint256 accruedInterest) {
        uint64 rebateFactorBefore = positionIRS.rebateFactor;
        
        // update the position's rebate factor based on the new limit order amount
        positionIRS.rebateFactor = _checkLimitOrder(
            _deriveLimitOrderId(owner),
            limitOrders[_deriveLimitOrderId(owner)],
            add(normalDebtBefore, deltaNormalDebt),
            (initialRebateFactor == 0) ? positionIRS.rebateFactor : initialRebateFactor
        );

        // update the position's interest rate state
        _setPositionIRS(owner, positionIRS);

        // update the cached global interest rate state
        (globalIRS_, accruedInterest) = _calculateGlobalIRS(
            globalIRS,
            positionIRS.snapshotRateAccumulator,
            totalNormalDebtBefore,
            normalDebtBefore,
            deltaNormalDebt,
            rebateFactorBefore,
            positionIRS.rebateFactor,
            claimedRebate
        );
    }

    /// @notice Internal helper method which bundles the following chores:
    ///   1. check if the vault entered emergency mode
    ///   2. store the new global interest rate state
    ///   3. collect any protocol fees
    /// This method is called by `_updateLimitOrderAndIRS`, `_calculateAssetsAndLiabilities`,`exchange`
    /// and `liquidatePositions`
    function _checkForEmergencyModeAndStoreGlobalIRSAndCollectFees(
        GlobalIRS memory globalIRS,
        uint256 fees,
        uint256 totalNormalDebt_,
        uint256 spotPrice_,
        uint64 globalLiquidationRatio
    ) internal returns (uint256) {
        // vault should not be in emergency mode
        _checkEmergencyMode(
            globalLiquidationRatio,
            spotPrice_,
            totalNormalDebt_,
            globalIRS.rateAccumulator,
            globalIRS.globalAccruedRebate
        );

        // store interest rate states
        _setGlobalIRS(globalIRS);

        // collect the protocol fee of the accrued interest
        return _collectFees(fees);
    }

    /// @notice Internal helper method which bundles the following chores:
    ///   1. calculate the position's new interest rate state
    ///   2. update the position's limit order
    ///   3. store the position's new interest rate state
    ///   4. calculate the new global interest rate state
    ///   5. check if the vault entered emergency mode
    ///   6. store the new global interest rate state
    ///   7. collect any protocol fees
    /// This method is called by `modifyCollateralAndDebt`, `createLimitOrder` and `cancelLimitOrder`
    function _updateLimitOrderAndIRS(
        address owner,
        uint256 normalDebtBefore,
        uint256 totalNormalDebtBefore,
        int256 deltaNormalDebt,
        uint256 spotPrice_,
        uint64 globalLiquidationRatio,
        uint64 initialRebateFactor
    ) internal returns (
        GlobalIRS memory globalIRS, PositionIRS memory positionIRS, uint128 claimedRebate
    ) {
        globalIRS = getGlobalIRS();
        positionIRS = getPositionIRS(owner);

        // calculate the position's new interest rate state by calculating the new rate accumulator, 
        // and the updated accrued rebate by deducting the current rebate claim (if delta normal debt is negative)
        {
        uint64 rateAccumulator = _calculateRateAccumulator(globalIRS, totalNormalDebtBefore);        
        positionIRS.accruedRebate = _calculateAccruedRebate(positionIRS, rateAccumulator, normalDebtBefore);
        positionIRS.snapshotRateAccumulator = rateAccumulator;
        }
        (claimedRebate, positionIRS.accruedRebate) = _calculateRebateClaim(
            (deltaNormalDebt < 0) ? uint256(-deltaNormalDebt) : 0, normalDebtBefore, positionIRS.accruedRebate
        );

        uint256 accruedInterest;
        (globalIRS, accruedInterest) = _updateLimitOrderAndPositionIRSAndCalculateGlobalIRS(
            owner,
            globalIRS,
            positionIRS,
            totalNormalDebtBefore,
            normalDebtBefore,
            deltaNormalDebt,
            claimedRebate,
            initialRebateFactor
        );

        _checkForEmergencyModeAndStoreGlobalIRSAndCollectFees(
            globalIRS, accruedInterest, add(totalNormalDebtBefore, deltaNormalDebt), spotPrice_, globalLiquidationRatio
        );
    }

    /// @notice Updates a position's collateral and normalized debt balances
    /// @dev This is the only method which is allowed to modify a position's collateral and normalized debt balances
    function _modifyPosition(
        address owner,
        Position memory position,
        PositionIRS memory positionIRS,
        int256 deltaCollateral,
        int256 deltaNormalDebt,
        uint256 totalNormalDebt_
    ) internal returns (Position memory) {
        // update collateral and normalized debt amounts by the deltas
        position.collateral = add(position.collateral, deltaCollateral);
        position.normalDebt = add(position.normalDebt, deltaNormalDebt);

        // position either has no debt or more debt than the debt floor
        if (position.normalDebt != 0 
            && calculateDebt(position.normalDebt, positionIRS.snapshotRateAccumulator, positionIRS.accruedRebate)
                < uint256(vaultConfig.debtFloor)
        ) revert CDPVault__modifyPosition_debtFloor();

        // store the position's balances
        positions[owner] = position;

        emit ModifyPosition(owner, deltaCollateral, deltaNormalDebt, add(totalNormalDebt_, deltaNormalDebt));
    
        return position;
    }

    /// @notice Returns true if the collateral value is equal or greater than the debt
    function _isCollateralized(
        uint256 debt, uint256 collateral, uint256 spotPrice_, uint256 liquidationRatio
    ) internal pure returns (bool) {
        return (collateral * spotPrice_ / liquidationRatio >= debt);
    }

    /// @notice Modifies a Position's collateral and debt balances
    /// @dev Checks that the global debt ceiling and the vault's debt ceiling have not been exceeded via the CDM,
    /// - that the Position is still safe after the modification,
    /// - that the msg.sender has the permission of the owner to decrease the collateral-to-debt ratio,
    /// - that the msg.sender has the permission of the collateralizer to put up new collateral,
    /// - that the msg.sender has the permission of the creditor to settle debt with their credit,
    /// - that that the vault debt floor is exceeded
    /// - that the vault minimum collateralization ratio is met, otherwise it will transition into emergency mode
    /// @param owner Address of the owner of the position
    /// @param collateralizer Address of who puts up or receives the collateral delta
    /// @param creditor Address of who provides or receives the credit delta for the debt delta
    /// @param deltaCollateral Amount of collateral to put up (+) or to remove (-) from the position [wad]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// to settle (-) on this position [wad]
    function modifyCollateralAndDebt(
        address owner,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) external {
        if (
            // position is either more safe than before or msg.sender has the permission from the owner
            (deltaNormalDebt > 0 || deltaCollateral < 0) && !hasPermission(owner, msg.sender)
            // msg.sender has the permission of the collateralizer to collateralize the position using their cash
            || (deltaCollateral > 0 && !hasPermission(collateralizer, msg.sender))
            // msg.sender has the permission of the creditor to use their credit to repay the debt
            || (deltaNormalDebt < 0 && !hasPermission(creditor, msg.sender))
        ) revert CDPVault__modifyCollateralAndDebt_noPermission();

        Position memory position = positions[owner];
        VaultConfig memory vaultConfig_ = vaultConfig;
        uint256 totalNormalDebt_ = totalNormalDebt;
        uint256 spotPrice_ = spotPrice();

        // update the global and position interest rate states and the position's corresponding limit order
        (GlobalIRS memory globalIRS, PositionIRS memory positionIRS, uint128 claimedRebate) = _updateLimitOrderAndIRS(
            owner,
            position.normalDebt,
            totalNormalDebt_,
            deltaNormalDebt,
            spotPrice_,
            vaultConfig_.globalLiquidationRatio,
            0
        );

        // update the position's balances,
        position = _modifyPosition(owner, position, positionIRS, deltaCollateral, deltaNormalDebt, totalNormalDebt_);

        // position is either less risky than before or it is safe
        if (
            (deltaNormalDebt > 0 || deltaCollateral < 0) && !_isCollateralized(
                calculateDebt(position.normalDebt, positionIRS.snapshotRateAccumulator, positionIRS.accruedRebate),
                position.collateral,
                spotPrice_,
                vaultConfig_.liquidationRatio
            )
        ) revert CDPVault__modifyCollateralAndDebt_notSafe();

        // store updated collateral and normalized debt amounts
        cash[collateralizer] = sub(cash[collateralizer], deltaCollateral);
        totalNormalDebt_ = add(totalNormalDebt_, deltaNormalDebt); 
        totalNormalDebt = totalNormalDebt_;

        // update debt and credit balances in the CDM
        // pay the claimedRebate to the creditor (claimedRebate is zero if deltaNormalDebt >= 0 and positive else)
        int256 deltaDebt = wmul(globalIRS.rateAccumulator, deltaNormalDebt) + int256(uint256(claimedRebate));
        if (deltaDebt > 0) {
            cdm.modifyBalance(address(this), creditor, uint256(deltaDebt));
        } else if (deltaDebt < 0) {
            cdm.modifyBalance(creditor, address(this), uint256(-deltaDebt));
        }

        // check max utilization ratio
        if(deltaNormalDebt > 0) {
            uint256 utilizationRatio = _calculateUtilizationRatio(globalIRS, totalNormalDebt_);
            uint256 maxUtilizationRatio = uint64(utilizationParams >> 64);
            if(utilizationRatio > maxUtilizationRatio) {
                revert CDPVault__modifyCollateralAndDebt_maxUtilizationRatio();
            }
        } 

        emit ModifyCollateralAndDebt(owner, collateralizer, creditor, deltaCollateral, deltaNormalDebt);
    }

    /*//////////////////////////////////////////////////////////////
                               REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a price tick at an index in the price tick linked list (sorted from lowest to highest)
    /// @param index Index of the price tick in the linked list
    /// @return priceTick Price tick [wad]
    /// @return isActive Whether the price tick is active
    function getPriceTick(uint256 index) external view returns (uint256 priceTick, bool isActive) {
        priceTick = _limitPriceTicks.getHead();
        for (uint256 i; i != index; ) {
            priceTick = _limitPriceTicks.getNext(priceTick);
            unchecked { ++i; }
        }
        isActive = activeLimitPriceTicks[priceTick];
    }

    /// @notice Returns a limit order id at an index in the limit order linked list (sorted from oldest to newest)
    /// @param priceTick Price tick of the limit order
    /// @param index Index of the limit order in the linked list
    /// @return limitOrderId Limit order id
    function getLimitOrder(uint256 priceTick, uint256 index) external view returns (uint256 limitOrderId) {
        limitOrderId = _limitOrderQueue[priceTick].getTail();
        for (uint256 i; i != index; ) {
            limitOrderId = _limitOrderQueue[priceTick].getPrev(limitOrderId);
            unchecked { ++i; }
        }
    }

    /// @notice Calculates the rebate factor for a given price tick
    /// @param priceTick Price tick from which to derive the rebate factor from [wad]
    /// @return _ Rebate factor [wad]
    function calculateRebateFactorForPriceTick(uint256 priceTick) public view returns (uint64) {
        if (priceTick < WAD) return 0;
        uint256 rebateRate = uint128(rebateParams);
        uint256 maxRebate = uint128(rebateParams >> 128);
        return toUint64(wdiv(WAD, maxRebate + wmul(rebateRate, priceTick - WAD)));
    }

    /// @notice Derive the limit order id from the maker address
    /// @param maker Address of the maker of the limit order
    /// @return orderId Limit order id
    function _deriveLimitOrderId(address maker) internal pure returns (uint256 orderId) {
        assembly("memory-safe") {
            orderId := maker
        }
    }

    /// @notice Adds a new price tick to the limit price tick linked list
    /// @dev Requires caller to have 'TICK_MANAGER_ROLE' role
    /// @param limitPriceTick The limit price tick to add [wad]
    /// @param nextLimitPriceTick The next (higher) limit price tick (0 if there's no higher price tick) [wad]
    function addLimitPriceTick(
        uint256 limitPriceTick,
        uint256 nextLimitPriceTick
    ) external whenNotPaused onlyRole(TICK_MANAGER_ROLE) {
        if (limitPriceTick < 1.0 ether || 100 ether < limitPriceTick)
            revert CDPVault__addLimitPriceTick_limitPriceTickOutOfRange();

        // verify order of price ticks
        uint256 lowestLimitPriceTick = _limitPriceTicks.getHead();
        if (
            // no existing price ticks, nextLimitPriceTick must be 0
            (lowestLimitPriceTick == 0 && nextLimitPriceTick != 0)
            // limitPriceTick and lowestLimitPriceTick must be less or equal to the nextLimitPriceTick
            || (nextLimitPriceTick != 0
                && ((limitPriceTick > nextLimitPriceTick) || (lowestLimitPriceTick > nextLimitPriceTick))
            ) 
            // limitPriceTick must be greater or equal to the nextLimitPriceTick's previous price tick
            || limitPriceTick < _limitPriceTicks.getPrev(nextLimitPriceTick)
        ) revert CDPVault__addLimitPriceTick_invalidPriceTickOrder();

        _limitPriceTicks.insert(limitPriceTick, nextLimitPriceTick);
        activeLimitPriceTicks[limitPriceTick] = true;

        emit AddLimitPriceTick(limitPriceTick); 
    }

    /// @notice Removes limit price tick
    /// @dev Requires caller to have 'TICK_MANAGER_ROLE' role
    /// @param limitPriceTick limit price tick to remove [wad]
    function removeLimitPriceTick(uint256 limitPriceTick) external whenNotPaused onlyRole(TICK_MANAGER_ROLE) {
        activeLimitPriceTicks[limitPriceTick] = false;
        _limitPriceTicks.remove(limitPriceTick);
        emit RemoveLimitPriceTick(limitPriceTick); 
    }

    /// @notice Creates a new limit order for a given position (user).
    /// The price tick represents a fee on the current oracle price of the collateral asset
    /// for which it can be redeemed for Stablecoin
    /// @param limitPriceTick Limit price tick of the limit order (between 1.0 and 100) [wad]
    function createLimitOrder(uint256 limitPriceTick) public {
        if (!activeLimitPriceTicks[limitPriceTick])
            revert CDPVault__createLimitOrder_limitPriceTickNotActive();
        
        uint256 normalDebt = positions[msg.sender].normalDebt;
        if (limitOrderFloor > normalDebt)
            revert CDPVault__createLimitOrder_limitOrderFloor();
        
        uint256 limitOrderId = _deriveLimitOrderId(msg.sender);
        if (limitOrders[limitOrderId] != 0)
            revert CDPVault__createLimitOrder_limitOrderAlreadyExists();

        // store the limit order (safe because price tick has to be between 1.0 and 100)
        limitOrders[limitOrderId] = limitPriceTick;
        
        // insert at the end of the queue (head of the linked list)
        _limitOrderQueue[limitPriceTick].insert(limitOrderId, _limitOrderQueue[limitPriceTick].getHead());

        // update the position's rebate factor
        _updateLimitOrderAndIRS(
            msg.sender,
            normalDebt,
            totalNormalDebt,
            0,
            spotPrice(),
            vaultConfig.globalLiquidationRatio,
            calculateRebateFactorForPriceTick(limitPriceTick)
        );

        emit CreateLimitOrder(limitPriceTick, msg.sender);
    }

    /// @notice Cancels an existing limit order for a given position (user)
    function cancelLimitOrder() public {
        uint256 limitOrderId = _deriveLimitOrderId(msg.sender);
        uint256 priceTick = limitOrders[limitOrderId];
        if (priceTick == 0) revert CDPVault__cancelLimitOrder_limitOrderDoesNotExist();
        _limitOrderQueue[priceTick].remove(limitOrderId);
        delete limitOrders[limitOrderId];

        // reset the position's rebate factor
        _updateLimitOrderAndIRS(
            msg.sender,
            positions[msg.sender].normalDebt,
            totalNormalDebt,
            0,
            spotPrice(),
            vaultConfig.globalLiquidationRatio,
            0
        );

        emit CancelLimitOrder(priceTick, msg.sender);
    }

    /// @notice Check that the limit order is above the limit order floor, otherwise remove it and
    /// return the updated rebate factor
    function _checkLimitOrder(
        address owner, uint256 normalDebt, uint64 currentRebateFactor
    ) internal returns (uint64 rebateFactor) {
        uint256 limitOrderId = _deriveLimitOrderId(owner);
        return _checkLimitOrder(limitOrderId, limitOrders[limitOrderId], normalDebt, currentRebateFactor);
    }

    /// @notice Check that the limit order is above the limit order floor, otherwise remove it and
    /// return the updated rebate factor
    function _checkLimitOrder(
        uint256 limitOrderId, uint256 priceTick, uint256 normalDebt, uint64 currentRebateFactor
    ) internal returns (uint64 rebateFactor) {
        rebateFactor = currentRebateFactor;
        if (priceTick != 0 && limitOrderFloor > normalDebt) {
            _limitOrderQueue[priceTick].remove(limitOrderId);
            delete limitOrders[limitOrderId];
            rebateFactor = 0;
        }
    }

    // avoid stack-too-deep in `exchange`
    struct ExchangeCache {
        // cached state variables to be evaluated after processing all positions
        GlobalIRS globalIRS;
        uint256 totalNormalDebt;
        uint256 collateralExchanged;
        uint256 creditExchanged;
        uint256 accruedInterest;
        // cache storage variables
        uint256 debtFloor;
        // cached local variables (to avoid stack-too-deep in `_settleDebtAndReleaseCollateral`)
        uint256 settlementRate;
        uint256 settlementPenalty;
        uint256 maxCreditToExchange;
        uint256 accruedBadDebt;
    }

    /// @notice Returns the position's interest rate state with the updated accrued rebate amount
    function _getUpdatedPositionIRS(
        address owner, uint256 normalDebt, uint64 rateAccumulator
    ) internal view returns (PositionIRS memory positionIRS) {
        positionIRS = getPositionIRS(owner);
        positionIRS.accruedRebate = _calculateAccruedRebate(positionIRS, rateAccumulator, normalDebt);
        positionIRS.snapshotRateAccumulator = rateAccumulator;
    }

    /// @notice Executes an exchange of credit and collateral by settling position debt
    function _settleDebtAndReleaseCollateral(
        ExchangeCache memory cache, Position memory position, PositionIRS memory positionIRS, address owner
    ) internal returns (ExchangeCache memory) {
        // limit the amount of credit to exchange by position debt to be settled
        uint256 creditToExchange;
        uint256 collateralToExchange;
        uint256 deltaNormalDebt;
        uint128 claimedRebate;
        {
        uint256 debt = calculateDebt(
            position.normalDebt, positionIRS.snapshotRateAccumulator, positionIRS.accruedRebate
        );
        uint256 maxDebtToSettle = wmul(cache.maxCreditToExchange, cache.settlementPenalty);
        maxDebtToSettle = 
            // max. debt that can be settled using this limit order (min(debtValue, collateralValue))
            min(
                // if the position's new debt is below the debt floor but not 0,
                // then limit the amount of debt that can be settled such that at least the debt floor amount is left
                (debt > maxDebtToSettle && debt - maxDebtToSettle < cache.debtFloor)
                    ? wdiv(debt - cache.debtFloor, cache.settlementPenalty) : wdiv(debt, cache.settlementPenalty),
                wmulUp(position.collateral, cache.settlementRate)
        );

        // min(credit left to exchange, max credit to exchange)
        creditToExchange = min(cache.maxCreditToExchange, maxDebtToSettle);

        // calculate normalized debt we are able to settle
        uint256 deltaDebt = wmul(creditToExchange, cache.settlementPenalty); 
        (claimedRebate, positionIRS.accruedRebate) = _calculateRebateClaim(deltaDebt, debt, positionIRS.accruedRebate);
        deltaNormalDebt = calculateNormalDebt(deltaDebt, positionIRS.snapshotRateAccumulator, claimedRebate);

        // calculate and bound the amount of collateral to exchange
        collateralToExchange = wdiv(creditToExchange, cache.settlementRate);
        if (collateralToExchange > position.collateral) collateralToExchange = position.collateral;

        // account for accrued bad debt (if any)        
        if (
            collateralToExchange == position.collateral && 
            position.normalDebt > deltaNormalDebt
        ){
            cache.accruedBadDebt += debt - deltaDebt;
            deltaNormalDebt = position.normalDebt;
        }
        }

        // reorder stack
        uint256 totalNormalDebt_ = cache.totalNormalDebt;

        // update the limit order (removed if below limit order floor), and update the interest rate states
        uint256 accruedInterest;
        (cache.globalIRS, accruedInterest) = _updateLimitOrderAndPositionIRSAndCalculateGlobalIRS(
            owner,
            cache.globalIRS,
            positionIRS,
            totalNormalDebt_,
            position.normalDebt,
            -toInt256(deltaNormalDebt),
            claimedRebate,
            0
        );

        // repay the position's debt balance and release the bought collateral amount
        _modifyPosition(
            owner,
            position,
            positionIRS,
            -toInt256(collateralToExchange),
            -toInt256(deltaNormalDebt),
            totalNormalDebt_
        );

        // update the total normalized debt, total exchanged credit, released collateral and accrued interest amounts 
        cache.totalNormalDebt -= deltaNormalDebt;
        cache.collateralExchanged += collateralToExchange;
        cache.creditExchanged += creditToExchange;
        cache.accruedInterest += accruedInterest;

        return cache;
    }

    /// @notice Exchange credit for collateral
    /// @param upperLimitPriceTick Upper limit price tick (> 1.0) [wad]
    /// @param creditToExchange Amount of credit to exchange for collateral [wad]
    /// @return creditExchanged Amount of credit exchanged [wad]
    /// @return collateralExchanged Amount of collateral exchanged [wad]
    function _exchange(
        uint256 upperLimitPriceTick,
        uint256 creditToExchange
    ) internal returns (uint256 creditExchanged, uint256 collateralExchanged) {
        GlobalIRS memory globalIRS = getGlobalIRS();
        VaultConfig memory vaultConfig_ = vaultConfig;
        uint256 spotPrice_ = spotPrice();

        ExchangeCache memory cache;
        cache.globalIRS = globalIRS;
        cache.totalNormalDebt = totalNormalDebt;
        cache.debtFloor = vaultConfig_.debtFloor;
        cache.settlementPenalty = WAD;

        uint64 rateAccumulator = _calculateRateAccumulator(globalIRS, cache.totalNormalDebt);

        // get the lowest price tick (head to of the linked list)
        uint256 limitPriceTick = _limitPriceTicks.getHead();
        // get the oldest limit order from the current price tick queue (tail of the linked list)
        uint256 limitOrderId = _limitOrderQueue[limitPriceTick].getTail();

        while (cache.creditExchanged < creditToExchange) {
            // break if no price ticks are available or the upper limit price tick is reached
            if (limitPriceTick == 0 || limitPriceTick > upperLimitPriceTick) break;
            // find the next active price tick which has open limit orders
            if (!activeLimitPriceTicks[limitPriceTick] || limitOrderId == 0) {
                // get the next (higher) price tick
                limitPriceTick = _limitPriceTicks.getNext(limitPriceTick);
                // get the oldest limit order from the current price tick queue (tail of the linked list)
                limitOrderId = _limitOrderQueue[limitPriceTick].getTail();
                continue;
            }
            // get the next oldest limit order from the queue, break if we tried executing this limit order already
            uint256 nextLimitOrderId = _limitOrderQueue[limitPriceTick].getPrev(limitOrderId);
            if (nextLimitOrderId == limitOrderId) break;

            // try executing the limit order
            address owner = address(uint160(limitOrderId));
            Position memory position = positions[owner];
            PositionIRS memory positionIRS = _getUpdatedPositionIRS(owner, position.normalDebt, rateAccumulator);
            cache.settlementRate = wmul(spotPrice_, limitPriceTick);
            cache.maxCreditToExchange = creditToExchange - cache.creditExchanged;

            // only allow execution of limit orders corresponding to safe positions
            if (_isCollateralized(
                calculateDebt(position.normalDebt, positionIRS.snapshotRateAccumulator, positionIRS.accruedRebate),
                position.collateral,
                spotPrice_,
                vaultConfig_.liquidationRatio
            )) {
                cache = _settleDebtAndReleaseCollateral(cache, position, positionIRS, owner);
            }

            limitOrderId = nextLimitOrderId;
        }

        // check if the vault entered emergency mode, store the new cached global interest rate state and collect fees
        _checkForEmergencyModeAndStoreGlobalIRSAndCollectFees(
            cache.globalIRS,
            cache.accruedInterest,
            cache.totalNormalDebt,
            spotPrice_,
            vaultConfig_.globalLiquidationRatio
        );
        
        // store the new cached total normalized debt
        totalNormalDebt = cache.totalNormalDebt;

        // revert if not enough credit was exchanged
        if (creditToExchange != cache.creditExchanged) revert CDPVault__exchange_notEnoughExchanged();

        return (cache.creditExchanged, cache.collateralExchanged);
    }

    /// @notice Preview exchanging credit for collateral
    /// @param upperLimitPriceTick Upper limit price tick (> 1.0) [wad]
    /// @param creditToExchange Amount of credit to exchange for collateral [wad]
    /// @return creditExchanged Amount of credit exchanged [wad]
    /// @return collateralExchanged Amount of collateral exchanged [wad]
    function exchangePreview(
        uint256 upperLimitPriceTick,
        uint256 creditToExchange
    ) external returns (uint256 creditExchanged, uint256 collateralExchanged) {
        if (msg.sender != address(0)) revert();
        return _exchange(upperLimitPriceTick, creditToExchange);
    }

    /// @notice Exchange credit for collateral
    /// @param upperLimitPriceTick Upper limit price tick (> 1.0) [wad]
    /// @param creditToExchange Amount of credit to exchange for collateral [wad]
    /// @return creditExchanged Amount of credit exchanged [wad]
    /// @return collateralExchanged Amount of collateral exchanged [wad]
    function exchange(
        uint256 upperLimitPriceTick,
        uint256 creditToExchange
    ) external returns (uint256 creditExchanged, uint256 collateralExchanged) {
        (creditExchanged, collateralExchanged) = _exchange(upperLimitPriceTick, creditToExchange);

        // update the taker's credit and cash balances
        if (creditExchanged > 0) cdm.modifyBalance(msg.sender, address(this), creditExchanged);
        if (collateralExchanged > 0) cash[msg.sender] += collateralExchanged;

        emit Exchange(msg.sender, creditExchanged, collateralExchanged);

        return (creditExchanged, collateralExchanged);
    }
}
