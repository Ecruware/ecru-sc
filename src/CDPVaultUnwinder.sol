// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVaultUnwinderFactory} from "./interfaces/ICDPVaultUnwinderFactory.sol";
import {ICDPVaultUnwinder} from "./interfaces/ICDPVaultUnwinder.sol";
import {ICDPVault} from "./interfaces/ICDPVault.sol";
import {ICDM} from "./interfaces/ICDM.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import {min, wmul, wdiv} from "./utils/Math.sol";

import {getCredit} from "./CDM.sol";

/// @title CDPVaultUnwinderFactory
/// @notice Factory for deploying CDPVaultUnwinders
contract CDPVaultUnwinderFactory is ICDPVaultUnwinderFactory {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(ICDPVault vault => ICDPVaultUnwinder unwinder) public unwinders;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DeployVaultUnwinder(address indexed vault, address unwinder);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVaultUnwinderFactory__deployVaultUnwinder__alreadyDeployed();
    error CDPVaultUnwinderFactory__deployVaultUnwinder_notUnwindable();

    /*//////////////////////////////////////////////////////////////
                            DEPLOY UNWINDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates the unwinding of a vault by deploying a CDPVaultUnwinder and transferring all the collateral,
    /// and credit from the vault to the unwinder
    /// @dev the CDPVaultUnwinderFactory has to have the VAULT_UNWIND_ROLE of the vault to unwind
    function deployVaultUnwinder(ICDPVault vault) external returns (ICDPVaultUnwinder unwinder) {
        if (unwinders[vault] != ICDPVaultUnwinder(address(0)))
            revert CDPVaultUnwinderFactory__deployVaultUnwinder__alreadyDeployed();

        bool paused = vault.paused();
        if (!paused || (paused && vault.pausedAt() + 14 days > block.timestamp))
            revert CDPVaultUnwinderFactory__deployVaultUnwinder_notUnwindable();
        
        // create unwinder
        IERC20 token = vault.token();
        ICDM cdm = vault.cdm();
        unwinder = new CDPVaultUnwinder(ICDPVault(vault), token, cdm);
        unwinders[vault] = unwinder;

        // transfer collateral and credit to unwinder
        token.safeTransferFrom(address(vault), address(unwinder), token.balanceOf(address(vault)));
        (int256 balance,) = cdm.accounts(address(vault));
        if (balance > 0) cdm.modifyBalance(address(vault), address(unwinder), uint256(balance));
        address creditWithholder = vault.creditWithholder();
        (int256 creditWithholderBalance,) = cdm.accounts(creditWithholder);
        cdm.modifyBalance(address(creditWithholder), address(unwinder), getCredit(creditWithholderBalance));

        emit DeployVaultUnwinder(address(vault), address(unwinder));
    }
}

/// @title CDPVaultUnwinder
/// @notice Handles the unwinding of collateral and credit for a failed vault
contract CDPVaultUnwinder is ICDPVaultUnwinder {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Auction Config
    uint256 public constant AUCTION_START = 2 weeks;
    uint256 public constant AUCTION_END = 4 weeks;
    uint256 public constant AUCTION_DEBT_FLOOR = 100e18;
    uint256 public constant AUCTION_MULTIPLIER = 110e16;
    uint256 public constant AUCTION_DURATION = 1.5 days;

    /// @notice The vault to unwind
    ICDPVault public immutable vault;
    /// @notice The CDM used by the vault
    ICDM public immutable cdm;
    /// @notice The token of the vault
    IERC20 public immutable token;
    /// @notice The precision scale of the token
    uint256 public immutable tokenScale;
    /// @notice Timestamp at which the unwinder was created
    uint256 public immutable createdAt;
    
    /// @notice Cached value of the vault's global rate accumulator [wad]
    uint256 public immutable fixedGlobalRateAccumulator;
    /// @notice Total amount of credit the borrowers can repay [wad]
    uint256 public immutable fixedTotalDebt;
    /// @notice Total amount of shares currently in the circulation at the start of the unwinding [wad]
    uint256 public immutable fixedTotalShares;
    
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total amount of cash the borrowers can claim [wad]
    uint256 public fixedCollateral;
    /// @notice Total amount of credit the delegators can redeem [wad]
    uint256 public fixedCredit;
    /// @notice Current total debt balance [wad]
    uint256 public totalDebt;
    /// @notice Current total shares in circulation [wad]
    uint256 public totalShares;

    /// @notice The repaid amount of normalized debt of each borrowers (position) [wad]
    mapping(address position => uint256 repaidNormalDebt) public repaidNormalDebt;
    /// @notice The redeemed amount of shares of each delegator [wad]
    mapping(address delegator => uint256 redeemedShares) public redeemedShares;

    // Auction State
    struct Auction {
        // Credit to raise [wad]
        uint256 debt;
        // Cash to sell [wad]
        uint256 cash;
        // Auction start time
        uint96 startsAt;
        // Starting price [wad]
        uint160 startPrice;
    }
    /// @notice The current auction state
    Auction public auction;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SettleDebt(address indexed owner, uint256 amount, uint256 totalDebt);
    event RedeemCredit(
        address indexed owner,
        address indexed receiver,
        address indexed payer,
        uint256 subNormalDebt,
        uint256 collateralRedeemed
    );
    event StartAuction(uint256 debt, uint256 cash, uint256 startsAt, uint256 startPrice);
    event RedoAuction(uint256 debt, uint256 cash, uint256 startsAt, uint256 startPrice);
    event TakeCash(
        address indexed recipient,
        uint256 cashToBuy,
        uint256 creditToPay,
        uint256 debt,
        uint256 cash,
        uint256 price);
    event RedeemShares(address indexed delegator, uint256 subShares, uint256 creditRedeemed);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVaultUnwinder__redeemCredit_noCollateral();
    error CDPVaultUnwinder__redeemCredit_notWithinPeriod();
    error CDPVaultUnwinder__redeemCredit_noPermission();
    error CDPVaultUnwinder__redeemCredit_repaid();
    error CDPVaultUnwinder__redeemShares_notWithinPeriod();
    error CDPVaultUnwinder__redeemShares_redeemed();
    error CDPVaultUnwinder__redeemShares_noCredit();
    error CDPVaultUnwinder__startAuction_notWithinPeriod();
    error CDPVaultUnwinder__startAuction_noCash();
    error CDPVaultUnwinder__startAuction_alreadyStarted();
    error CDPVaultUnwinder__takeCash_noPartialPurchase();
    error CDPVaultUnwinder__takeCash_tooExpensive();
    error CDPVaultUnwinder__takeCash_needsReset();
    error CDPVaultUnwinder__takeCash_notRunning();
    error CDPVaultUnwinder__redoAuction_cannotReset();
    error CDPVaultUnwinder__redoAuction_notRunning();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(ICDPVault vault_, IERC20 token_, ICDM cdm_) {
        createdAt = block.timestamp;
        vault = vault_;
        cdm = cdm_;
        token = token_;
        uint256 tokenScale_ = vault_.tokenScale();
        tokenScale = tokenScale_;
        
        // cache the global rate accumulator and the total shares
        (,, uint256 fixedGlobalRateAccumulator_, , uint256 globalAccruedRebate) = vault_.getGlobalIRS();
        fixedGlobalRateAccumulator = fixedGlobalRateAccumulator_;
        fixedTotalShares = vault_.totalShares();

        // determine the borrowers claims
        uint256 totalDebt_ = wmul(vault.totalNormalDebt(), fixedGlobalRateAccumulator) - globalAccruedRebate;
        totalDebt = totalDebt_;
        fixedTotalDebt = totalDebt_;
    }

    function _settleDebt(uint256 amount) internal {
        // settle any debt in the vault first before attributing any credit to the unwinder
        (int256 balance,) = cdm.accounts(address(vault));
        if (balance < 0) {
            uint256 vaultDebt = uint256(-balance);
            if (amount > vaultDebt) {
                uint256 surplusCredit = amount - vaultDebt;
                cdm.modifyBalance(msg.sender, address(vault), vaultDebt);
                cdm.modifyBalance(msg.sender, address(this), surplusCredit);
            } else {
                cdm.modifyBalance(msg.sender, address(vault), amount);
            }
        } else {
            cdm.modifyBalance(msg.sender, address(this), amount);
        }

        totalDebt -= amount;

        emit SettleDebt(msg.sender, amount, totalDebt);
    }

    /*//////////////////////////////////////////////////////////////
                          BORROWER CLAIM PHASE
    //////////////////////////////////////////////////////////////*/

    // 1. Borrowers can close their position: debt / totalDebt * totalCollateral
    function redeemCredit(
        address owner, address receiver, address payer, uint256 subNormalDebt
    ) external returns (uint256 collateralRedeemed) {
        if (block.timestamp >= createdAt + AUCTION_START)
            revert CDPVaultUnwinder__redeemCredit_notWithinPeriod();
        
        if (fixedCollateral == 0) {
            uint256 fixedCollateral_ = wdiv(token.balanceOf(address(this)), tokenScale);
            if (fixedCollateral_ == 0) revert CDPVaultUnwinder__redeemCredit_noCollateral();
            fixedCollateral = fixedCollateral_;
        }
        
        if (
            // msg.sender has the permission of the owner to close the position on their behalf
            !vault.hasPermission(owner, msg.sender)
            // msg.sender has the permission of the payer to use their credit to repay the debt
            || !vault.hasPermission(payer, msg.sender)
        ) revert CDPVaultUnwinder__redeemCredit_noPermission();

        (uint256 collateral, uint256 normalDebt) = vault.positions(owner);
        uint256 repaidNormalDebt_ = repaidNormalDebt[owner] + subNormalDebt;
        if (repaidNormalDebt_ > normalDebt) revert CDPVaultUnwinder__redeemCredit_repaid();
        repaidNormalDebt[owner] = repaidNormalDebt_;

        (,,uint128 accruedRebate) = vault.getPositionIRS(owner);

        uint256 rateAccumulator = fixedGlobalRateAccumulator;
        uint256 debt = wmul(normalDebt, rateAccumulator) - accruedRebate;
        uint256 subDebt = wmul(subNormalDebt, rateAccumulator) - accruedRebate;

        _settleDebt(subDebt);

        collateralRedeemed = subDebt * collateral / debt;
        token.safeTransfer(receiver, wmul(collateralRedeemed, tokenScale));

        emit RedeemCredit(owner, receiver, payer, subNormalDebt, collateralRedeemed);
    }

    /*//////////////////////////////////////////////////////////////
                             AUCTION PHASE
    //////////////////////////////////////////////////////////////*/

    function _getStartPrice(uint256 collateral, uint256 totalDebt_) private view returns (uint160 price) {
        IOracle oracle = vault.oracle();
        if (address(oracle).code.length > 0) {
            try vault.oracle().spot(address(token)) returns (uint256 price_) {
                return uint160(wmul(price_, AUCTION_MULTIPLIER));
            } catch {}
        }
        price = uint160(totalDebt_ * AUCTION_MULTIPLIER / collateral);
    }

    function _auctionPrice(uint256 startPrice, uint256 time) internal pure returns (uint256) {
        if (time >= AUCTION_DURATION) return 0;
        return wmul(startPrice, wdiv(AUCTION_DURATION - time, AUCTION_DURATION));
    }

    function _auctionStatus(uint96 startsAt, uint256 startPrice) internal view returns (bool done, uint256 price) {
        price = _auctionPrice(startPrice, block.timestamp - startsAt);
        done = (block.timestamp - startsAt > AUCTION_DURATION || block.timestamp >= createdAt + AUCTION_END);
    }

    function getAuctionStatus()
        external
        view
        returns (bool needsRedo, uint256 price, uint256 cash, uint256 debt)
    {
        Auction memory auction_ = auction;
        bool done;
        (done, price) = _auctionStatus(auction_.startsAt, auction_.startPrice);
        needsRedo = auction_.debt != 0 && done;
        cash = auction_.cash;
        debt = auction_.debt;
    }

    // 2. Remaining collateral can be auction off for credit
    function startAuction() external {
        if (block.timestamp < createdAt + AUCTION_START || block.timestamp >= createdAt + AUCTION_END)
            revert CDPVaultUnwinder__startAuction_notWithinPeriod();

        if (auction.debt != 0) revert CDPVaultUnwinder__startAuction_alreadyStarted();

        uint256 cash = wdiv(token.balanceOf(address(this)), tokenScale);
        if (cash == 0) revert CDPVaultUnwinder__startAuction_noCash();

        Auction memory auction_ = Auction({
            debt: totalDebt,
            cash: wdiv(cash, tokenScale),
            startsAt: uint96(block.timestamp),
            startPrice: _getStartPrice(cash, totalDebt)
        });

        auction = auction_;

        emit StartAuction(auction_.debt, auction_.cash, auction_.startsAt, auction_.startPrice);
    }

    function redoAuction() external {
        Auction memory auction_ = auction;
        if (auction_.debt == 0) revert CDPVaultUnwinder__redoAuction_notRunning();
        // check that auction needs reset and compute current price [wad]
        (bool done, ) = _auctionStatus(auction_.startsAt, auction_.startPrice);
        if (!done || block.timestamp >= createdAt + AUCTION_END) revert CDPVaultUnwinder__redoAuction_cannotReset();
        auction_.startsAt = uint96(block.timestamp);
        auction_.startPrice = _getStartPrice(auction_.cash, auction_.debt);
        auction = auction_;
        emit RedoAuction(auction_.debt, auction_.cash, auction_.startsAt, auction_.startPrice);
    }

    function takeCash(
        uint256 cashAmount, uint256 maxPrice, address recipient
    ) external returns (uint256 cashToBuy, uint256 creditToPay) {
        Auction memory auction_ = auction;
        if (auction_.debt == 0) revert CDPVaultUnwinder__takeCash_notRunning();

        (bool done, uint256 price) = _auctionStatus(auction_.startsAt, auction_.startPrice);
        // check that auction doesn't need reset
        if (done) revert CDPVaultUnwinder__takeCash_needsReset();
        // ensure price is acceptable to buyer
        if (maxPrice < price) revert CDPVaultUnwinder__takeCash_tooExpensive();

        uint256 cash = auction_.cash;
        uint256 debt = auction_.debt;

        unchecked {
            // purchase as much as possible, up to cashAmount (cashToBuy <= cash)
            cashToBuy = min(cash, cashAmount);
            // credit needed to buy a cashToBuy of this auction
            creditToPay = wmul(cashToBuy, price);

            // don't collect more than debt
            if (creditToPay > debt) {
                creditToPay = debt;
                // adjust cashToBuy
                cashToBuy = wdiv(creditToPay, price);
            // if cashToBuy == cash => auction completed => debtFloor doesn't matter
            } else if (creditToPay < debt && cashToBuy < cash) {
                // safe as creditToPay < debt
                if (debt - creditToPay < AUCTION_DEBT_FLOOR) {
                    // if debt <= AUCTION_DEBT_FLOOR, buyers have to take the entire cash
                    if (debt <= AUCTION_DEBT_FLOOR) revert CDPVaultUnwinder__takeCash_noPartialPurchase();
                    // adjust amount to pay (creditToPay' <= creditToPay), up to debtFloor
                    creditToPay = debt - AUCTION_DEBT_FLOOR;
                    // adjust cashToBuy
                    // cashToBuy' = creditToPay' / price < creditToPay / price == cashToBuy < cash
                    cashToBuy = wdiv(creditToPay, price);
                }
            }

            // calculate remaining debt after operation
            debt = debt - creditToPay; // safe since creditToPay <= debt
            // calculate remaining cash after operation
            cash = cash - cashToBuy;
        }

        auction_.debt = debt;
        auction_.cash = cash;
        auction = auction_;

        // get credit from caller
        _settleDebt(creditToPay);
        // send cash to recipient
        token.safeTransfer(recipient, wmul(cashToBuy, tokenScale));

        emit TakeCash(recipient, cashToBuy, creditToPay, debt, cash, price);
    }

    /*//////////////////////////////////////////////////////////////
                         DELEGATOR CLAIM PHASE
    //////////////////////////////////////////////////////////////*/

    // 3. Delegators can redeem their shares: shares / totalShares * totalCollateral for credit
    function redeemShares(uint256 subShares) external returns (uint256 creditRedeemed) {
        if (block.timestamp < createdAt + AUCTION_END)
            revert CDPVaultUnwinder__redeemShares_notWithinPeriod();

        // fix the delegator claims and continue with the collateral auctions immediately if there's no credit left
        (int256 balance,) = cdm.accounts(address(this));
        uint256 fixedCredit_ = fixedCredit;
        if (fixedCredit_ == 0) {
            fixedCredit_ = getCredit(balance);
            fixedCredit = fixedCredit_;
            if (fixedCredit_ == 0) return 0;
        }

        // no credit left to redeem
        if (balance <= 0) revert CDPVaultUnwinder__redeemShares_noCredit();

        uint256 shares = vault.shares(msg.sender);
        uint256 redeemedShares_ = redeemedShares[msg.sender] + subShares;
        if (redeemedShares_ > shares) revert CDPVaultUnwinder__redeemShares_redeemed();
        redeemedShares[msg.sender] = redeemedShares_;

        creditRedeemed = subShares * fixedCredit_ / fixedTotalShares;
        cdm.modifyBalance(address(this), msg.sender, creditRedeemed);

        emit RedeemShares(msg.sender, subShares, creditRedeemed);
    }
}
