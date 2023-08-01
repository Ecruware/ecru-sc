// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPermission} from "../interfaces/IPermission.sol";
import {ICDM} from "../interfaces/ICDM.sol";
import {IMinter} from "../interfaces/IMinter.sol";
import {IStablecoin} from "../interfaces/IStablecoin.sol";
import {ICDPVault} from "../interfaces/ICDPVault.sol";

import {toInt256, wmul} from "../utils/Math.sol";

import {calculateNormalDebt} from "../CDPVault.sol";
import {TransferAction, PermitParams} from "./TransferAction.sol";
import {BaseAction} from "./BaseAction.sol";
import {SwapAction, SwapParams, SwapType} from "./SwapAction.sol";

import {IFlashlender, IERC3156FlashBorrower, ICreditFlashBorrower} from "../interfaces/IFlashlender.sol";

/// @notice Struct containing parameters used for adding or removing a position's collateral
///         and optionally swapping an arbitrary token to the collateral token
struct CollateralParams {
    // token passed in or received by the caller
    address targetToken;
    // amount of collateral to add in CDPVault.tokenScale() or to remove in WAD
    uint256 amount;
    // address that will transfer the collateral or receive the collateral
    address collateralizer;
    // optional swap from `targetToken` to collateral, or collateral to `targetToken`
    SwapParams auxSwap;
}

/// @notice Struct containing parameters used for borrowing or repaying Stablecoin
///         and optionally swapping Stablecoin to an arbitrary token or vice versa
struct CreditParams {
    // amount of debt to increase by or the amount of normal debt to decrease by [wad]
    uint256 amount;
    // address that will transfer the debt to repay or receive the debt to borrow
    address creditor;
    // optional swap from Stablecoin to arbitrary token
    SwapParams auxSwap;
}

/// @notice General parameters relevant for both increasing and decreasing leverage
struct LeverParams {
    // position to lever
    address position;
    // the vault to lever
    address vault;
    // the vault's token
    address collateralToken;
    // the swap parameters to swap collateral to Stablecoin or vice versa
    SwapParams primarySwap;
    // optional swap parameters to swap an arbitrary token to the collateral token or vice versa
    SwapParams auxSwap;
}

/// @title PositionAction
/// @notice Base contract for interacting with CDPVaults via a proxy
/// @dev This contract is designed to be called via a proxy contract and can be dangerous to call directly
///      This contract does not support fee-on-transfer tokens
abstract contract PositionAction is IERC3156FlashBorrower, ICreditFlashBorrower, TransferAction, BaseAction {

    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes32 public constant CALLBACK_SUCCESS_CREDIT = keccak256("CreditFlashBorrower.onCreditFlashLoan");

    /// @notice The CDM contract
    ICDM public immutable cdm;
    /// @notice The flashloan contract
    IFlashlender public immutable flashlender;
    /// @notice Stablecoin token
    IStablecoin public immutable stablecoin;
    /// @notice Stablecoin mint
    IMinter public immutable minter;
    /// @notice The address of this contract
    address public immutable self;
    /// @notice The SwapAction contract
    SwapAction public immutable swapAction;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PositionAction__deposit_InvalidAuxSwap();
    error PositionAction__borrow_InvalidAuxSwap();
    error PositionAction__repay_InvalidAuxSwap();
    error PositionAction__delegateViaStablecoin_InvalidAuxSwap();
    error PositionAction__increaseLever_invalidPrimarySwap();
    error PositionAction__increaseLever_invalidAuxSwap();
    error PositionAction__decreaseLever_invalidPrimarySwap();
    error PositionAction__decreaseLever_invalidAuxSwap();
    error PositionAction__decreaseLever_invalidResidualRecipient();
    error PositionAction__onFlashLoan__invalidSender();
    error PositionAction__onCreditFlashLoan__invalidSender();
    error PositionAction__onlyDelegatecall();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address flashlender_, address swapAction_) {
        flashlender = IFlashlender(flashlender_);
        stablecoin = flashlender.stablecoin();
        minter = flashlender.minter();
        cdm = flashlender.cdm();
        self = address(this);
        swapAction = SwapAction(swapAction_);
        cdm.modifyPermission(address(minter), true);
        cdm.modifyPermission(flashlender_, true);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if not called via delegatecall, this is to prevent users from calling the contract directly
    modifier onlyDelegatecall() {
        if (address(this) == self) revert PositionAction__onlyDelegatecall();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                VIRTUAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook to deposit collateral into CDPVault, handles any CDP specific actions
    /// @param vault The CDP Vault
    /// @param src Token passed in by the caller
    /// @param amount The amount of collateral to deposit [CDPVault.tokenScale()]
    /// @return Amount of collateral deposited [wad]
    function _onDeposit(address vault, address src, uint256 amount) internal virtual returns (uint256);

    /// @notice Hook to withdraw collateral from CDPVault, handles any CDP specific actions
    /// @param vault The CDP Vault
    /// @param dst Token the caller expects to receive
    /// @param amount The amount of collateral to deposit [wad]
    /// @return Amount of collateral (or dst) withdrawn [CDPVault.tokenScale()]
    function _onWithdraw(address vault, address dst, uint256 amount) internal virtual returns (uint256);

    /// @notice Hook to increase lever by depositing collateral into the CDPVault, handles any CDP specific actions
    /// @param leverParams LeverParams struct
    /// @param upFrontToken the token passed up front
    /// @param upFrontAmount the amount of `upFrontToken` (or amount received from the aux swap)[CDPVault.tokenScale()]
    /// @param swapAmountOut the amount of tokens received from the stablecoin flash loan swap [CDPVault.tokenScale()]
    /// @return Amount of collateral added to CDPVault [wad]
    function _onIncreaseLever(
        LeverParams memory leverParams,
        address upFrontToken,
        uint256 upFrontAmount,
        uint256 swapAmountOut
    ) internal virtual returns (uint256);

    /// @notice Hook to decrease lever by withdrawing collateral from the CDPVault, handles any CDP specific actions
    /// @param leverParams LeverParams struct
    /// @param subCollateral Amount of collateral to decrease by [wad]
    /// @return Amount of underlying token withdrawn from CDPVault [CDPVault.tokenScale()]
    function _onDecreaseLever(LeverParams memory leverParams, uint256 subCollateral) internal virtual returns (uint256);

    /*//////////////////////////////////////////////////////////////
                             ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds collateral to a CDP Vault
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param collateralParams The collateral parameters
    function deposit(
        address position,
        address vault,
        CollateralParams calldata collateralParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        uint256 collateral = _deposit(vault, collateralParams, permitParams);
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            toInt256(collateral),
            0
        );
    }

    /// @notice Removes collateral from a CDP Vault
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param collateralParams The collateral parameters
    function withdraw(
        address position,
        address vault,
        CollateralParams calldata collateralParams
    ) external onlyDelegatecall {
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            -toInt256(collateralParams.amount),
            0
        );
        _withdraw(vault, collateralParams);
    }

    /// @notice Adds debt to a CDP Vault by minting Stablecoin (and optionally swaps Stablecoin to an arbitrary token)
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param creditParams The borrow parameters
    function borrow(address position, address vault, CreditParams calldata creditParams) external onlyDelegatecall {
        uint256 addNormalDebt = _debtToNormalDebt(vault, position, creditParams.amount);
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            0,
            toInt256(addNormalDebt)
        );
        _borrow(creditParams);
    }

    /// @notice Repays debt to a CDP Vault via Stablecoin (optionally swapping an arbitrary token to Stablecoin)
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param creditParams The credit parameters
    /// @param permitParams The permit parameters
    function repay(
        address position,
        address vault,
        CreditParams calldata creditParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        _repay(position, vault, creditParams, permitParams);
        IPermission(address(cdm)).modifyPermission(position, vault, true);
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            0,
            -toInt256(creditParams.amount)
        );
        IPermission(address(cdm)).modifyPermission(position, vault, false);
    }

    /// @notice Delegates credit to `vault`
    /// @dev Wrapper function around CDPVault.delegateCredit()
    /// @param creditAmount Amount of credit to delegate [wad]
    /// @return sharesAmount Amount of shares issued [wad]
    function delegate(address vault, uint256 creditAmount) public returns (uint256 sharesAmount) {
        cdm.modifyPermission(vault, true);
        sharesAmount = ICDPVault(vault).delegateCredit(creditAmount);
        cdm.modifyPermission(vault, false);
    }

    /// @notice Undelegate credit from a vault
    /// @dev Wrapper function around CDPVault.undelegateCredit()
    /// @dev This function does not have the onlyDelegatecall modifier to save gas but should only be called via Proxy
    /// @param shareAmount Amount of shares to redeem [wad]
    /// @param prevQueuedEpochs Array of stale epochs for which shares were queued
    /// @return estimatedClaim Estimated amount of withdrawable credit, if no bad debt is accrued [wad]
    /// @return epoch Epoch at which the undelegation was initiated
    /// @return claimableAtEpoch Epoch at which the undelegated credit can be claimed by the delegator
    /// @return fixableUntilEpoch Epoch at which the credit claim of the epoch has to be fixed by
    function undelegate(address vault, uint256 shareAmount, uint256[] calldata prevQueuedEpochs) external returns (
        uint256 estimatedClaim, uint256 epoch, uint256 claimableAtEpoch, uint256 fixableUntilEpoch
    ) {
        return ICDPVault(vault).undelegateCredit(shareAmount, prevQueuedEpochs);
    }

    /// @notice Claim undelegated credit from a vault
    /// @dev Wrapper function around CDPVault.claimUndelegatedCredit()
    /// @dev This function does not have the onlyDelegatecall modifier to save gas but should only be called via Proxy
    /// @param vault The CDP Vault
    /// @param claimForEpoch The epoch to claim undelegatedCredit for
    /// @return creditAmount Amount of credit claimed [wad]
    function claimUndelegatedCredit(address vault, uint256 claimForEpoch) external returns (uint256 creditAmount) {
        creditAmount = ICDPVault(vault).claimUndelegatedCredit(claimForEpoch);
    }

    /// @notice Adds collateral and debt to a CDP Vault
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param collateralParams The collateral parameters
    /// @param creditParams The credit parameters
    function depositAndBorrow(
        address position,
        address vault,
        CollateralParams calldata collateralParams,
        CreditParams calldata creditParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        uint256 collateral = _deposit(vault, collateralParams, permitParams);
        uint256 addNormalDebt = _debtToNormalDebt(vault, position, creditParams.amount);
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            toInt256(collateral),
            toInt256(addNormalDebt)
        );
        _borrow(creditParams);
    }

    /// @notice Removes collateral and debt from a CDP Vault
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param collateralParams The collateral parameters
    /// @param creditParams The credit parameters
    /// @param permitParams The permit parameters
    function withdrawAndRepay(
        address position,
        address vault,
        CollateralParams calldata collateralParams,
        CreditParams calldata creditParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        _repay(position, vault, creditParams, permitParams);
        IPermission(address(cdm)).modifyPermission(position, vault, true);
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            -toInt256(collateralParams.amount),
            -toInt256(creditParams.amount)
        );
        IPermission(address(cdm)).modifyPermission(position, vault, false);
        _withdraw(vault, collateralParams);
    }

    /// @notice Adds collateral and delegates credit to a vault
    /// @param position The CDP Vault position
    /// @param depositVault The CDP Vault to deposit collateral into
    /// @param delegateVault The CDP Vault to delegate credit to
    /// @param credit The amount of credit to delegate
    /// @param collateralParams The collateral parameters
    /// @param permitParams The permit parameters
    function depositAndDelegate(
        address position,
        address depositVault,
        address delegateVault,
        uint256 credit,
        CollateralParams calldata collateralParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        uint256 collateral = _deposit(depositVault, collateralParams, permitParams);
        uint256 addNormalDebt = _debtToNormalDebt(depositVault, position, credit);
        ICDPVault(depositVault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            toInt256(collateral),
            toInt256(addNormalDebt)
        );
        delegate(delegateVault, credit);
    }

    /// @notice Swap for stablecoin or transfer stablecoin directly, then delegate to a vault
    /// @param creditor The address to transfer stablecoin or swap tokens from
    /// @param vault The CDP Vault to delegate credit to
    /// @param credit The amount of credit to delegate [wad]
    /// @param swapParams The swap parameters for swapping an arbitrary asset to stablecoin
    /// @param permitParams The permit parameters
    function delegateViaStablecoin(
        address creditor,
        address vault,
        uint256 credit,
        SwapParams calldata swapParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        // perform swap from arbitrary token to Stablecoin
        if (swapParams.assetIn != address(0)) {
            if (swapParams.recipient != address(this)) revert PositionAction__delegateViaStablecoin_InvalidAuxSwap();
            credit = _transferAndSwap(creditor, swapParams, permitParams);
        } else if (creditor != address(this)) {
            // otherwise just transfer Stablecoin directly from creditor
            _transferFrom(
                address(stablecoin),
                creditor,
                address(this),
                credit,
                permitParams
            );
        }

        // transfer stablecoin to credit
        stablecoin.approve(address(minter), credit);
        minter.enter(address(this), credit);

        // then delegate the credit
        delegate(vault, credit);
    }

    /// @notice Undelegate credit from a vault and withdraw collateral from a vault
    /// @param position The CDP Vault position
    /// @param withdrawVault The CDP Vault to withdraw collateral from
    /// @param delegateVault The CDP Vault to undelegate credit from
    /// @param claimForEpoch The epoch to claim undelegatedCredit for
    /// @param subNormalDebt The amount of normal debt to repay [wad]
    /// @param collateralParams The collateral parameters for collateral withdrawal
    function withdrawAndClaim(
        address position,
        address withdrawVault,
        address delegateVault,
        uint256 claimForEpoch,
        uint256 subNormalDebt,
        CollateralParams calldata collateralParams
    ) external onlyDelegatecall {
        ICDPVault(delegateVault).claimUndelegatedCredit(claimForEpoch);
        cdm.modifyPermission(position, withdrawVault, true);
        ICDPVault(withdrawVault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            -toInt256(collateralParams.amount),
            -toInt256(subNormalDebt)
        );
        cdm.modifyPermission(position, withdrawVault, false);
        _withdraw(withdrawVault, collateralParams);
    }

    /// @notice Undelegate and then repay a position
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param claimForEpoch The epoch to claim undelegatedCredit for
    /// @param subNormalDebt The amount of normal debt to repay [wad]
    /// @param creditParams The credit parameters for debt repayment
    /// @param permitParams The permit parameters
    function repayAndClaim(
        address position,
        address vault,
        uint256 claimForEpoch,
        uint256 subNormalDebt,
        CreditParams calldata creditParams,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        _repay(position, vault, creditParams, permitParams);
        ICDPVault(vault).claimUndelegatedCredit(claimForEpoch);
        IPermission(address(cdm)).modifyPermission(position, vault, true);
        ICDPVault(vault).modifyCollateralAndDebt(
            position,
            address(this),
            address(this),
            0,
            -toInt256(creditParams.amount + subNormalDebt)
        );
        IPermission(address(cdm)).modifyPermission(position, vault, false);
    }

    /// @notice Allows for multiple calls to be made to cover use cases not covered by the other functions
    /// @param targets The addresses to call
    /// @param data The encoded data to call each address with
    /// @param delegateCall Whether or not to use delegatecall or call
    function multisend(
        address[] calldata targets,
        bytes[] calldata data,
        bool[] calldata delegateCall
    ) external onlyDelegatecall {
        uint256 totalTargets = targets.length;
        for (uint256 i; i < totalTargets;) {
            if (delegateCall[i]) {
                _delegateCall(targets[i], data[i]);
            } else {
                (bool success, bytes memory response) = targets[i].call(data[i]);
                if (!success) _revertBytes(response);
            }
            unchecked { ++i; }
        }
    }

    /// @notice Increase the leverage of a position by taking out a flash loan and buying Stablecoin
    /// @param leverParams The parameters for the lever action,
    /// `primarySwap` - parameters to swap Stablecoin provided by the flash loan into the collateral token
    /// `auxSwap` - parameters to swap the `upFrontToken` to the collateral token
    /// @param upFrontToken The token to transfer up front to the LeverAction contract
    /// @param upFrontAmount The amount of `upFrontToken` to transfer to the LeverAction contract [upFrontToken-Scale]
    /// @param collateralizer The address to transfer `upFrontToken` from
    /// @param permitParams The permit parameters for the `collateralizer` to transfer `upFrontToken`
    function increaseLever(
        LeverParams calldata leverParams,
        address upFrontToken,
        uint256 upFrontAmount,
        address collateralizer,
        PermitParams calldata permitParams
    ) external onlyDelegatecall {
        // validate the primary swap
        if (leverParams.primarySwap.swapType != SwapType.EXACT_IN ||
            leverParams.primarySwap.assetIn != address(stablecoin) ||
            leverParams.primarySwap.recipient != self
        ) revert PositionAction__increaseLever_invalidPrimarySwap();

        // validate aux swap if it exists
        if (leverParams.auxSwap.assetIn != address(0) && (
            leverParams.auxSwap.swapType != SwapType.EXACT_IN ||
            leverParams.auxSwap.assetIn != upFrontToken ||
            leverParams.auxSwap.recipient != self
        )) revert PositionAction__increaseLever_invalidAuxSwap();

        // transfer any up front amount to the LeverAction contract
        if (upFrontAmount > 0) {
            if (collateralizer == address(this)) {
                IERC20(upFrontToken).safeTransfer(self, upFrontAmount); // if tokens are on the proxy then just transfer
            } else {
                _transferFrom(upFrontToken, collateralizer, self, upFrontAmount, permitParams);
            }
        }

        // take out flash loan
        IPermission(leverParams.vault).modifyPermission(leverParams.position, self, true);
        flashlender.flashLoan(
            IERC3156FlashBorrower(self),
            address(stablecoin),
            leverParams.primarySwap.amount,
            abi.encode(leverParams, upFrontToken, upFrontAmount)
        );
        IPermission(leverParams.vault).modifyPermission(leverParams.position, self, false);
    }

    /// @notice Decrease the leverage of a position by taking out a credit flash loan to withdraw and sell collateral
    /// @param leverParams The parameters for the lever action:
    /// `primarySwap` swap parameters to swap the collateral withdrawn from the CDPVault using the flash loan to
    /// Stablecoin `auxSwap` swap parameters to swap the collateral not used to payback the flash loan
    /// @param subCollateral The amount of collateral to withdraw from the position [wad]
    /// @param residualRecipient Optional parameter that must be provided if an `auxSwap` *is not* provided
    /// This parameter is the address to send the residual collateral to
    function decreaseLever(
        LeverParams calldata leverParams,
        uint256 subCollateral,
        address residualRecipient
    ) external onlyDelegatecall {
        // validate the primary swap
        if (leverParams.primarySwap.swapType != SwapType.EXACT_OUT ||
            leverParams.primarySwap.recipient != self
        ) revert PositionAction__decreaseLever_invalidPrimarySwap();

        // validate aux swap if it exists
        if (leverParams.auxSwap.assetIn != address(0) && (
            leverParams.auxSwap.swapType != SwapType.EXACT_IN
        )) revert PositionAction__decreaseLever_invalidAuxSwap();

        /// validate residual recipient is provided if no aux swap is provided
        if (leverParams.auxSwap.assetIn == address(0) &&
            residualRecipient == address(0)
        ) revert PositionAction__decreaseLever_invalidResidualRecipient();

        // take out credit flash loan
        IPermission(leverParams.vault).modifyPermission(leverParams.position, self, true);
        flashlender.creditFlashLoan(
            ICreditFlashBorrower(self),
            leverParams.primarySwap.amount,
            abi.encode(leverParams, subCollateral, residualRecipient)
        );
        IPermission(leverParams.vault).modifyPermission(leverParams.position, self, false);
    }

    /*//////////////////////////////////////////////////////////////
                          FLASHLOAN CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback function for the flash loan taken out in increaseLever
    /// @param data The encoded bytes that were passed into the flash loan
    function onFlashLoan(
        address /*initiator*/,
        address /*token*/,
        uint256 /*amount*/,
        uint256 /*fee*/,
        bytes calldata data
    ) external returns (bytes32) {
        if (msg.sender != address(flashlender)) revert PositionAction__onFlashLoan__invalidSender();
        (
            LeverParams memory leverParams,
            address upFrontToken,
            uint256 upFrontAmount
        ) = abi.decode(data, (LeverParams, address, uint256));

        // perform a pre swap from arbitrary token to collateral token if necessary
        if (leverParams.auxSwap.assetIn != address(0)) {
            bytes memory auxSwapData = _delegateCall(
                address(swapAction), abi.encodeWithSelector(swapAction.swap.selector, leverParams.auxSwap)
            );
            upFrontAmount = abi.decode(auxSwapData, (uint256));
        }

        // swap stablecoin to collateral
        bytes memory swapData = _delegateCall(
            address(swapAction), abi.encodeWithSelector(swapAction.swap.selector, leverParams.primarySwap)
        );
        uint256 swapAmountOut = abi.decode(swapData, (uint256));

        // deposit collateral and handle any CDP specific actions
        uint256 collateral = _onIncreaseLever(leverParams, upFrontToken, upFrontAmount, swapAmountOut);

        // derive the amount of normal debt from the amount of Stablecoin swapped
        uint256 addNormalDebt = _debtToNormalDebt(
            leverParams.vault, leverParams.position, leverParams.primarySwap.amount
        );

        // add collateral and debt
        ICDPVault(leverParams.vault).modifyCollateralAndDebt(
            leverParams.position,
            address(this),
            address(this),
            toInt256(collateral),
            toInt256(addNormalDebt)
        );

        // mint stablecoin to pay back the flash loans
        minter.exit(address(this), leverParams.primarySwap.amount);

        // Approve stablecoin to be used to pay back the flash loan.
        stablecoin.approve(address(flashlender), leverParams.primarySwap.amount);

        return CALLBACK_SUCCESS;
    }

    /// @notice Callback function for the credit flash loan taken out in decreaseLever
    /// @param data The encoded bytes that were passed into the credit flash loan
    function onCreditFlashLoan(
        address /*initiator*/,
        uint256 /*amount*/,
        uint256 /*fee*/,
        bytes calldata data
    ) external returns (bytes32) {
        if (msg.sender != address(flashlender)) revert PositionAction__onCreditFlashLoan__invalidSender();
        (
            LeverParams memory leverParams,
            uint256 subCollateral,
            address residualRecipient
        ) = abi.decode(data,(LeverParams, uint256, address));

        // derive the amount of normal debt from the amount of Stablecoin received from the swap
        uint256 subNormalDebt = _debtToNormalDebt(
            leverParams.vault,
            leverParams.position,
            leverParams.primarySwap.amount
        );

        // sub collateral and debt
        cdm.modifyPermission(leverParams.vault, true);
        ICDPVault(leverParams.vault).modifyCollateralAndDebt(
            leverParams.position,
            address(this),
            address(this),
            -toInt256(subCollateral),
            -toInt256(subNormalDebt)
        );
        cdm.modifyPermission(leverParams.vault, false);

        // withdraw collateral and handle any CDP specific actions
        uint256 withdrawnCollateral = _onDecreaseLever(leverParams, subCollateral);

        bytes memory swapData = _delegateCall(
            address(swapAction),
            abi.encodeWithSelector(
                swapAction.swap.selector,
                leverParams.primarySwap
            )
        );
        uint256 swapAmountIn = abi.decode(swapData, (uint256));

        // swap collateral to stablecoin and calculate the amount leftover
        uint256 residualAmount = withdrawnCollateral - swapAmountIn;

        // mint stablecoin from collateral to pay back the flash loan
        stablecoin.approve(address(minter), leverParams.primarySwap.amount);
        minter.enter(address(this), leverParams.primarySwap.amount);

        // send left over collateral that was not needed to payback the flash loan to `residualRecipient`
        if (residualAmount > 0) {

            // perform swap from collateral to arbitrary token if necessary
            if (leverParams.auxSwap.assetIn != address(0)) {
                _delegateCall(
                    address(swapAction),
                    abi.encodeWithSelector(
                        swapAction.swap.selector,
                        leverParams.auxSwap
                    )
                );
            } else {
                // otherwise just send the collateral to `residualRecipient`
                IERC20(leverParams.primarySwap.assetIn).safeTransfer(residualRecipient, residualAmount);
            }

        }

        return CALLBACK_SUCCESS_CREDIT;
    }


    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits collateral into CDPVault (optionally transfer and swaps an arbitrary token to collateral)
    /// @param vault The CDP Vault
    /// @param collateralParams The collateral parameters
    /// @return The amount of collateral deposited [wad]
    function _deposit(
        address vault,
        CollateralParams calldata collateralParams,
        PermitParams calldata permitParams
    ) internal returns (uint256) {
        uint256 amount = collateralParams.amount;

        if (collateralParams.auxSwap.assetIn != address(0)) {
            if (collateralParams.auxSwap.assetIn != collateralParams.targetToken
                || collateralParams.auxSwap.recipient != address(this)
            ) revert PositionAction__deposit_InvalidAuxSwap();
            amount = _transferAndSwap(collateralParams.collateralizer, collateralParams.auxSwap, permitParams);
        } else if (collateralParams.collateralizer != address(this)) {
            _transferFrom(
                collateralParams.targetToken,
                collateralParams.collateralizer,
                address(this),
                amount,
                permitParams
            );
        }

        return _onDeposit(vault, collateralParams.targetToken, amount);
    }

    /// @notice Withdraws collateral from CDPVault (optionally swaps collateral to an arbitrary token)
    /// @param vault The CDP Vault
    /// @param collateralParams The collateral parameters
    /// @return The amount of collateral withdrawn [token.decimals()]
    function _withdraw(address vault, CollateralParams calldata collateralParams) internal returns (uint256) {
        uint256 collateral = _onWithdraw(vault, collateralParams.targetToken, collateralParams.amount);

        // perform swap from collateral to arbitrary token
        if (collateralParams.auxSwap.assetIn != address(0)) {
            _delegateCall(
                address(swapAction),
                abi.encodeWithSelector(
                    swapAction.swap.selector,
                    collateralParams.auxSwap
                )
            );
        } else {
            // otherwise just send the collateral to `collateralizer`
            IERC20(collateralParams.targetToken).safeTransfer(collateralParams.collateralizer, collateral);
        }
        return collateral;
    }

    /// @notice Mints Stablecoin and optionally swaps Stablecoin to an arbitrary token
    /// @param creditParams The credit parameters
    function _borrow(CreditParams calldata creditParams) internal {

        IPermission(address(cdm)).modifyPermission(address(this), address(minter), true);
        if (creditParams.auxSwap.assetIn == address(0)) {
            minter.exit(creditParams.creditor, creditParams.amount);
            IPermission(address(cdm)).modifyPermission(address(this), address(minter), false);
        } else {

            minter.exit(address(this), creditParams.amount);
            IPermission(address(cdm)).modifyPermission(address(this), address(minter), false);

            // hanlde exit swap
            if (creditParams.auxSwap.assetIn != address(stablecoin)) revert PositionAction__borrow_InvalidAuxSwap();
            _delegateCall(
                address(swapAction),
                abi.encodeWithSelector(
                    swapAction.swap.selector,
                    creditParams.auxSwap
                )
            );
        }
    }

    /// @notice Repays debt by redeeming Stablecoin and optionally swaps an arbitrary token to stablecoin
    /// @param position The CDP Vault position
    /// @param vault The CDP Vault
    /// @param creditParams The credit parameters
    /// @param permitParams The permit parameters
    function _repay(
        address position,
        address vault,
        CreditParams calldata creditParams,
        PermitParams calldata permitParams
    ) internal {
        // transfer arbitrary token and swap to stablecoin
        uint256 amount;
        if (creditParams.auxSwap.assetIn != address(0)) {

            if (creditParams.auxSwap.recipient != address(this)) revert PositionAction__repay_InvalidAuxSwap();

            amount = _transferAndSwap(creditParams.creditor, creditParams.auxSwap, permitParams);

        } else {
            // calculate the amount of stablecoin to repay
            (uint64 rateAccumulator, uint256 accruedRebate,) = ICDPVault(vault).virtualIRS(position);
            amount = wmul(rateAccumulator, creditParams.amount) - accruedRebate;

            if (creditParams.creditor != address(this)) {
                // transfer stablecoin directly from creditor
                _transferFrom(
                    address(stablecoin),
                    creditParams.creditor,
                    address(this),
                    amount,
                    permitParams
                );
            }
        }

        // generate credit from stablecoin to repay with
        stablecoin.approve(address(minter), amount);
        minter.enter(address(this), amount);
    }

    /// @dev Sends remaining tokens back to `sender` instead of leaving them on the proxy
    function _transferAndSwap(
        address sender,
        SwapParams calldata swapParams,
        PermitParams calldata permitParams
    ) internal returns (uint256 amountOut) {
        bytes memory response = _delegateCall(
            address(swapAction),
            abi.encodeWithSelector(
                swapAction.transferAndSwap.selector,
                sender,
                permitParams,
                swapParams
            )
        );
        uint256 retAmount = abi.decode(response, (uint256));

        // if this is an exact out swap then transfer the remainder to the `sender`
        if (swapParams.swapType == SwapType.EXACT_OUT) {
            uint256 remainder = swapParams.limit - retAmount;
            if (remainder > 0) {
                IERC20(swapParams.assetIn).safeTransfer(sender, remainder);
            }
            amountOut = swapParams.amount;
        } else {
            amountOut = retAmount;
        }
    }

    /// @notice Compute normalized debt of a `Position` using the up to date interest rate state
    /// @param vault CDPVault on which the position is opened
    /// @param position Position to compute normalized debt for
    /// @param debt Debt to convert to normal debt using `Position` in `Vault`'s rateAccumulator and accruedRebate [wad]
    /// @return normalDebt Normalized debt of the position [wad]
    function _debtToNormalDebt(
        address vault,
        address position,
        uint256 debt
    ) internal returns (uint256 normalDebt) {
        (uint64 rateAccumulator, uint256 accruedRebate,) = ICDPVault(vault).virtualIRS(position);
        normalDebt = calculateNormalDebt(debt, rateAccumulator, accruedRebate);
    }
}
