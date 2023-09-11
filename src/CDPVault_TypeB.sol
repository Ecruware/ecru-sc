// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVaultBase} from "./interfaces/ICDPVault.sol";
import {ICDPVault_TypeB, ICDPVault_TypeBBase} from "./interfaces/ICDPVault_TypeB.sol";
import {ICDPVault_TypeB_Factory} from "./interfaces/ICDPVault_TypeB_Factory.sol";

import {WAD, max, min, wmul, wdiv, toInt256} from "./utils/Math.sol";

import {CDPVault_TypeA, VAULT_CONFIG_ROLE, calculateDebt} from "./CDPVault_TypeA.sol";
import {getCredit, getDebt, getCreditLine} from "./CDM.sol";

/// @title CDPVault_TypeB
/// @notice A CDP-style vault for depositing collateral and drawing credit against it.
/// TypeA vaults are liquidated permissionlessly by selling as much collateral of an unsafe position until it meets
/// a targeted collateralization ratio again. Any shortfall from liquidation not being able to be recovered
/// by selling the available collateral is covered by the global Buffer or the Credit Delegators.
contract CDPVault_TypeB is CDPVault_TypeA, ICDPVault_TypeBBase {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Epoch Constants
    /// @notice Number of seconds in an epoch [seconds]
    uint256 public constant EPOCH_DURATION = 3 days;
    /// @notice Number of epochs that have to pass until an epoch claim can be fixed
    uint256 public constant EPOCH_FIX_DELAY = 1;
    /// @notice Number of epochs for which an epoch claim can be fixed
    uint256 public constant EPOCH_FIX_TIMEOUT = 3;

    // Credit Delegation Parameters
    /// @notice Withholder for amounts of credit to be undelegated (claims that are fixed or are about to be fixed)
    address public immutable creditWithholder;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Credit Delegation Accounting
    /// @notice Total number of shares currently issued to delegators [wad]
    uint256 public totalShares;
    /// @notice Number of shares currently issued to a delegator [wad]
    mapping(address owner => uint256 balance) public shares;
    /// @notice Total credit claimable by undelegating delegators in all fixed epochs [wad]
    uint256 public totalCreditClaimable;

    struct Epoch {
        /// @notice Total credit claimable by 'undelegating' delegators (set when claim is fixed) [wad]
        uint256 totalCreditClaimable;
        /// @notice Total credit withheld from the vault's credit balance (until claim is fixed) [wad]
        uint256 totalCreditWithheld;
        /// @notice Total number of shares that have been queued for undelegation for this epoch [wad]
        uint256 totalSharesQueued;
        /// @notice Fixed claim ratio for this epoch (< 1.0, if available credit was less than estimated claim) [wad]
        uint128 claimRatio;
        /// @notice Snapshotted estimated credit claim per share for a specific epoch [wad]
        uint128 estimatedCreditClaimPerShare;
    }
    /// @notice Map of epochs
    mapping (uint256 epoch => Epoch epochData) public epochs;
    /// @notice Number of shares that have been queued for undelegation for a specific epoch by a delegator [wad]
    mapping(uint256 epoch => mapping(address delegator => uint256 sharesQueued)) public sharesQueuedByEpoch;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DelegateCredit(address indexed delegator, uint256 creditDelegated, uint256 sharesIssued);
    event UndelegateCredit(
        address indexed delegator,
        uint256 shareAmount,
        uint256 estimatedClaim,
        uint256 indexed epoch,
        uint256 claimableAtEpoch
    );
    event ClaimUndelegatedCredit(address indexed delegator, uint256 sharesRedeemed, uint256 creditClaimed);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVault_TypeB__setUp_Deactivated();
    error CDPVault_TypeB__calculateAssetsAndLiabilities_insufficientAssets();
    error CDPVault_TypeB__delegateCredit_creditAmountTooSmall();
    error CDPVault_TypeB__claimUndelegatedCredit_epochNotClaimable();
    error CDPVault_TypeB__claimUndelegatedCredit_epochNotFixed();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address factory) CDPVault_TypeA(factory) {
        creditWithholder = ICDPVault_TypeB_Factory(factory).creditWithholder();
    }

    /// @notice Setup permissions for the Unwinder Factory
    /// @param unwinderFactory Address of the Unwinder Factory
    function setUnwinderFactory(address unwinderFactory) onlyRole(DEFAULT_ADMIN_ROLE) public virtual {
        // approve CDPVaultUnwinderFactory to transfer all the tokens and credit out of this contract
        token.safeApprove(unwinderFactory, type(uint256).max);
        cdm.modifyPermission(unwinderFactory, true);
    }

    /*//////////////////////////////////////////////////////////////
                           CREDIT DELEGATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the current epoch based on the block.timestamp and the duration of an epoch
    /// @return currentEpoch Current epoch
    function getCurrentEpoch() public view returns (uint256 currentEpoch) {
        unchecked { currentEpoch = (block.timestamp - (block.timestamp % EPOCH_DURATION)) / EPOCH_DURATION; }
    }

    /// @notice Calculates the amount of assets (credit + outstanding debt incl. interest)
    /// and liabilities (debt + protocol fee) this vault has
    function _calculateAssetsAndLiabilities(uint256 totalNonFixedCreditWithheld) internal returns (
        uint256 assets, uint256 liabilities, uint256 credit, uint256 creditLine
    ) {
        (int256 balance, uint256 debtCeiling) = cdm.accounts(address(this));
        credit = getCredit(balance);
        creditLine = getCreditLine(balance, debtCeiling);

        // update the global rate accumulator
        GlobalIRS memory globalIRS = getGlobalIRS();
        uint256 totalNormalDebt_ = totalNormalDebt;

        uint256 accruedInterest;
        (globalIRS, accruedInterest) = _calculateGlobalIRS(
            globalIRS, _calculateRateAccumulator(globalIRS, totalNormalDebt_), totalNormalDebt_, 0, 0, 0, 0, 0
        );

        uint256 totalAccruedFees_ = _checkForEmergencyModeAndStoreGlobalIRSAndCollectFees(
            globalIRS, accruedInterest, totalNormalDebt_, spotPrice(), vaultConfig.globalLiquidationRatio
        );

        // liquid credit reserves + total amount of credit we expect to be returned by borrowers
        assets = credit + totalNonFixedCreditWithheld + calculateDebt(
            totalNormalDebt_, globalIRS.rateAccumulator, globalIRS.globalAccruedRebate
        );
        // amount of credit used, extended to the vault by the CDM
        // + amount of accrued fees that belongs to the protocol (not the delegators)
        liabilities = getDebt(balance) + totalAccruedFees_;
        // check if vault is insolvent (more liabilities than assets) 
        if (assets < liabilities) revert CDPVault_TypeB__calculateAssetsAndLiabilities_insufficientAssets();
    }

    /// @notice Fixes credit claims for epochs within the epoch fix timeout that have passed the epoch fix delay
    ///   1. sum up shares queued and credit withheld in all non stale, non fixed epochs
    ///   2. transfer the credit withheld from stale epochs back to the vault
    ///   3. determine the total assets, liabilities and the liquid credit and calculate the withdrawable credit ratio
    ///      from that
    ///   4. fix the credit claims for all non state, non fixed epochs
    ///   5. rebalance any delta between the withheld amounts (based on prev. estimates)
    ///      and the fixed credit amounts between the withholder and the vault
    /// @param epochWithinEpochFixTimeout Epoch within the epoch fix timeout to return the cached params for (nullable)
    /// @return assets Assets belonging to delegators [wad]
    /// @return liabilities Liabilities belonging to the delegators [wad]
    /// @return creditLine Credit line as per CDM of the vault [wad]
    /// @return totalShares_ Total amount of currently issued shares [wad]
    /// @return epochWithinEpochFixTimeoutCache_ Cached values for `epochWithinEpochFixedTimeout` (nullable)
    function _fixUndelegationClaims(uint256 epochWithinEpochFixTimeout) internal returns (
        uint256 assets,
        uint256 liabilities,
        uint256 creditLine,
        uint256 totalShares_,
        Epoch memory epochWithinEpochFixTimeoutCache_
    ) {
        uint256 currentEpoch = getCurrentEpoch();
        // sum of all shares queued in all non stale, non fixed epochs
        uint256 totalSharesQueued;
        // sum of credit withheld for all non stale, non fixed epochs (:= credit estimates)
        uint256 totalNonStaleNonFixedCreditWithheld;
        Epoch[] memory epochsCache;
        unchecked { epochsCache = new Epoch[](EPOCH_FIX_TIMEOUT + 1); }

        // sum all shares queued and credit withheld for each epoch within the epoch fix timeout and sum up
        // the estimated credit claim per share for all fixable epochs
        uint256 totalEstimatedCreditClaimPerShare;
        for (uint256 i; i <= EPOCH_FIX_TIMEOUT; ) {
            // from the oldest epoch to the current epoch
            uint256 epoch;
            unchecked { epoch = currentEpoch - EPOCH_FIX_TIMEOUT + i; }
            Epoch memory epochCache = epochs[epoch];
            epochsCache[i] = epochCache;
            // fixable epochs (within the epoch fix timeout, passed fix delay, claimRatio == 0, totalSharesQueued != 0)
            if (epochCache.totalSharesQueued != 0
                && epochCache.claimRatio == 0
                && epoch + EPOCH_FIX_DELAY <= currentEpoch
            ) {
                totalEstimatedCreditClaimPerShare = (totalSharesQueued == 0)
                    ? epochCache.estimatedCreditClaimPerShare
                    : min(totalEstimatedCreditClaimPerShare, epochCache.estimatedCreditClaimPerShare);
                totalSharesQueued += epochCache.totalSharesQueued;
            }
            unchecked { ++i; }
            // sum up all the withheld credit for non stale, non fixed epochs
            if (epochCache.claimRatio == 0 && epochCache.totalSharesQueued != 0)
                // if totalSharesQueued == 0 and claimRatio == 0, then totalCreditWithheld == 0 as well
                totalNonStaleNonFixedCreditWithheld += epochCache.totalCreditWithheld;
        }

        // transfer withheld credit from stale epochs back to the vault
        uint256 totalCreditClaimable_ = totalCreditClaimable;
        {
        (int256 balance,) = cdm.accounts(creditWithholder);
        uint256 staleWithheldCredit = getCredit(balance) - totalNonStaleNonFixedCreditWithheld - totalCreditClaimable_;
        if (staleWithheldCredit > 0) cdm.modifyBalance(creditWithholder, address(this), staleWithheldCredit);
        }

        // calc. ratio between liquid credit and total credit claim for all fixable epochs
        uint256 claimRatio;
        uint256 totalCreditClaim;
        totalShares_ = totalShares;
        // withheld stale, non fixed credit has already been transferred back to the vault
        (assets, liabilities,, creditLine) = _calculateAssetsAndLiabilities(totalNonStaleNonFixedCreditWithheld);
        if (totalShares_ != 0) 
            totalCreditClaim = (assets - liabilities) * totalSharesQueued / totalShares_;
        if (totalCreditClaim != 0) {
            // take the minimum from the snapshotted estimated claim and the current claim to forfeit
            // any interest that would have accrued from the epoch start date until when it was fixed
            totalCreditClaim = min(totalCreditClaim, wmul(totalEstimatedCreditClaimPerShare, totalSharesQueued));
            // creditLine does not include the withheld credit
            uint256 withdrawableCredit = creditLine + totalNonStaleNonFixedCreditWithheld;
            // limit ratio if totalCreditClaim is less than withdrawableCredit (between 0 and 1.0)
            claimRatio = wdiv(withdrawableCredit, max(totalCreditClaim, withdrawableCredit));
            // adjust the total credit claimable by the claim ratio
            totalCreditClaim = wmul(totalCreditClaim, claimRatio);
        }

        // fix the total claimable amount of credit for all epochs in the current period
        int256 creditDelta;
        for (uint256 i; i <= EPOCH_FIX_TIMEOUT; ) {
            // from oldest epoch to the current epoch
            uint256 epoch;
            unchecked { epoch = currentEpoch - EPOCH_FIX_TIMEOUT + i; }
            Epoch memory epochCache = epochsCache[i];
            // fixable epochs (within the epoch fix timeout, passed fix delay, claimRatio == 0, totalSharesQueued != 0)
            if (epochCache.totalSharesQueued != 0
                && epochCache.claimRatio == 0
                && epoch + EPOCH_FIX_DELAY <= currentEpoch
            ) {
                // adjust the claim of the epoch by the calculated claim ratio
                epochCache = Epoch({
                    // epoch won't be fixable if totalSharesQueued == 0
                    totalCreditClaimable: totalCreditClaim * epochCache.totalSharesQueued / totalSharesQueued,
                    totalCreditWithheld: epochCache.totalCreditWithheld,
                    totalSharesQueued: wmul(epochCache.totalSharesQueued, claimRatio),
                    claimRatio: uint128(claimRatio),
                    estimatedCreditClaimPerShare: 0 // reset the estimated claim per share
                });

                totalCreditClaimable_ += epochCache.totalCreditClaimable;
                totalShares_ -= epochCache.totalSharesQueued;
            
                // offset the delta between the fixed credit claim and the initial withheld credit for that epoch
                creditDelta += toInt256(epochCache.totalCreditClaimable) - toInt256(epochCache.totalCreditWithheld);
                epochCache.totalCreditWithheld = 0; // reset the withheld credit

                // store the cached values
                epochsCache[i] = epochCache;
                epochs[epoch] = epochCache;
            }
            unchecked { ++i; }
        }

        // store the adjusted values
        totalCreditClaimable = totalCreditClaimable_;
        totalShares = totalShares_;

        // rebalance the credit between the credit withholder and the vault according to creditDelta
        // withheld amount based on estimate is less than the claim - transfer delta to the withholder
        if (creditDelta > 0) cdm.modifyBalance(address(this), creditWithholder, uint256(creditDelta));
        // withheld amount based on the estimate is greater than the claim - transfer delta back to the vault
        if (creditDelta < 0) cdm.modifyBalance(creditWithholder, address(this), uint256(-creditDelta));

        // cache the requested epoch's values
        uint256 requestedEpoch = currentEpoch - epochWithinEpochFixTimeout;
        if (EPOCH_FIX_TIMEOUT >= requestedEpoch) {
            unchecked { epochWithinEpochFixTimeoutCache_ = epochsCache[EPOCH_FIX_TIMEOUT - requestedEpoch]; }
        }
    }

    /// @notice Delegates credit to this contract
    /// @dev The caller needs to permit this contract to transfer credit on their behalf
    /// @param creditAmount Amount of credit to delegate [wad]
    /// @return sharesAmount Amount of shares issued [wad]
    function delegateCredit(uint256 creditAmount) external returns (uint256 sharesAmount) {
        if (creditAmount < WAD) revert CDPVault_TypeB__delegateCredit_creditAmountTooSmall();

        // fix all claims for all non stale epochs
        (
            uint256 assets, uint256 liabilities,, uint256 totalShares_,
        ) = _fixUndelegationClaims(getCurrentEpoch());

        // compute the amount of shares to issue to the delegator
        sharesAmount = (totalShares_ == 0 || assets - liabilities == 0)
            ? creditAmount : totalShares_ * creditAmount / (assets - liabilities);
        unchecked { shares[msg.sender] += sharesAmount; }
        totalShares = totalShares_ + sharesAmount;
        cdm.modifyBalance(msg.sender, address(this), creditAmount);

        emit DelegateCredit(msg.sender, creditAmount, sharesAmount);
    }

    /// @notice Signals (initiates) the undelegation of credit from this vault
    /// @dev Transfer an estimated amount of credit to be undelegated to the credit withholder contract
    /// @param shareAmount Amount of shares to redeem [wad]
    /// @param prevQueuedEpochs Array of stale epochs for which shares were queued
    /// @return estimatedClaim Estimated amount of withdrawable credit, if no bad debt is accrued [wad]
    /// @return currentEpoch Epoch at which the undelegation was initiated
    /// @return claimableAtEpoch Epoch at which the undelegated credit can be claimed by the delegator
    /// @return fixableUntilEpoch Epoch at which the credit claim of the epoch has to be fixed by
    function undelegateCredit(uint256 shareAmount, uint256[] memory prevQueuedEpochs) external returns (
        uint256 estimatedClaim, uint256 currentEpoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
    ) {
        currentEpoch = getCurrentEpoch();

        // fix all claims for all non stale epochs
        (
            uint256 assets, uint256 liabilities, uint256 creditLine, uint256 totalShares_, Epoch memory epochCache
        ) = _fixUndelegationClaims(currentEpoch);

        // remove any shares queued by the delegator from stale epochs
        uint256 unqueuedShares;
        for (uint256 i; i < prevQueuedEpochs.length; ) {
            uint256 prevQueuedEpoch = prevQueuedEpochs[i];
            unchecked {
                ++i;
                // only allow stale epochs (are older than epoch fix timeout, claimRatio == 0, totalSharesQueued != 0)
                if (prevQueuedEpoch == 0
                    || prevQueuedEpoch >= currentEpoch - EPOCH_FIX_TIMEOUT
                    || epochs[prevQueuedEpoch].claimRatio != 0
                    || epochs[prevQueuedEpoch].totalSharesQueued == 0
                ) continue;
            }
            uint256 sharesQueuedByEpoch_ = sharesQueuedByEpoch[prevQueuedEpoch][msg.sender];
            unqueuedShares += sharesQueuedByEpoch_;
            delete sharesQueuedByEpoch[prevQueuedEpoch][msg.sender];
            epochs[prevQueuedEpoch].totalSharesQueued -= sharesQueuedByEpoch_;
        }
        
        // withhold (up to) the estimated credit claim from the vault to ensure that the utilization ratio is updated
        // under the assumption of the current assets and liabilities (credit, debt)
        // undelegateCredit assumes that there are shares issued to delegators (totalShares_ != 0))
        estimatedClaim = (assets - liabilities) * shareAmount / totalShares_;
        // (advancement is given to the credit withholder contract if the debt ceiling allows for it)
        {
        uint256 withhold = (estimatedClaim > creditLine) ? creditLine : estimatedClaim;
        cdm.modifyBalance(address(this), creditWithholder, withhold);
        epochCache.totalCreditWithheld += withhold;
        }

        // store the min. estimated credit per share claim for all undelegators of the current epoch
        epochCache.estimatedCreditClaimPerShare = (epochCache.totalSharesQueued == 0)
            ? uint128(wdiv(estimatedClaim, shareAmount))
            : uint128(min(epochCache.estimatedCreditClaimPerShare, wdiv(estimatedClaim, shareAmount)));

         // add shares to the queue
        epochCache.totalSharesQueued += shareAmount;
        epochs[currentEpoch] = epochCache;
        sharesQueuedByEpoch[currentEpoch][msg.sender] += shareAmount;
        shares[msg.sender] = shares[msg.sender] + unqueuedShares - shareAmount;

        unchecked {
            (claimableAtEpoch, fixableUntilEpoch) = (currentEpoch + EPOCH_FIX_DELAY, currentEpoch + EPOCH_FIX_TIMEOUT);
        }

        emit UndelegateCredit(msg.sender, shareAmount, estimatedClaim, currentEpoch, claimableAtEpoch);
    }

    /// @notice Claims the undelegated amount of credit. If the claim has not been fixed within the timeout then the
    /// resulting credit claim will be 0 (it will not revert).
    /// @dev The undelegated amount of credit can be claimed after the epoch fix delay has passed
    /// @param claimForEpoch Epoch at which the undelegation was initiated
    /// @return creditAmount Amount of credit undelegated [wad]
    function claimUndelegatedCredit(uint256 claimForEpoch) external returns (uint256 creditAmount) {
        uint256 currentEpoch = getCurrentEpoch();
        unchecked {
            if (currentEpoch < claimForEpoch + EPOCH_FIX_DELAY)
                revert CDPVault_TypeB__claimUndelegatedCredit_epochNotClaimable();
        }

        // fix all claims for all non stale epochs
        (,,,, Epoch memory epochCache) = _fixUndelegationClaims(claimForEpoch);

        // if epochCache does not contain claimForEpoch, load from storage
        if (epochCache.totalSharesQueued == 0 && epochCache.claimRatio == 0 && epochCache.totalCreditWithheld == 0)
            epochCache = epochs[claimForEpoch];
        
        // if epoch is not fixed, then revert
        if (epochCache.totalSharesQueued != 0 && epochCache.claimRatio == 0)
            revert CDPVault_TypeB__claimUndelegatedCredit_epochNotFixed();

        // update shares by the claim ratio
        uint256 shareAmount = sharesQueuedByEpoch[claimForEpoch][msg.sender];
        uint256 adjShareAmount = wmul(shareAmount, epochCache.claimRatio);
        // remove the shares from the queue
        delete sharesQueuedByEpoch[claimForEpoch][msg.sender];
        // refund shares that couldn't be satisfied with the credit claim (amount is at most equal to the shareAmount)
        // totalShares was already updated in _fixUndelegationClaims
        shares[msg.sender] += shareAmount - adjShareAmount;
        shareAmount = adjShareAmount;

        // calculate the claimable amount of credit to undelegate for the delegator and transfer it to them
        // claimUndelegatedCredit assumes that shares are queued for the epoch (epochCache.totalSharesQueued != 0)
        creditAmount = epochCache.totalCreditClaimable * shareAmount / epochCache.totalSharesQueued;
        cdm.modifyBalance(creditWithholder, msg.sender, creditAmount);

        // subtract claimed shares from the total shares queued by epoch
        epochCache.totalSharesQueued -= shareAmount;
        epochCache.totalCreditClaimable -= creditAmount;
        epochs[claimForEpoch] = epochCache;
        totalCreditClaimable -= creditAmount;
        
        emit ClaimUndelegatedCredit(msg.sender, shareAmount, creditAmount);
    }
}
