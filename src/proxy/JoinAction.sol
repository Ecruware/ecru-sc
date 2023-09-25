// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferAction, PermitParams} from "./TransferAction.sol";

import {IVault, JoinKind, JoinPoolRequest} from "../vendor/IBalancerVault.sol";

/// @notice The join protocol to use
enum JoinProtocol {
    BALANCER
}

/// @notice The parameters for a join
struct JoinParams {
    JoinProtocol protocol;
    bytes32 poolId;
    address[] assets;
    // used for exact token in joins
    // can be different from `assets` if BPT is one of the assets
    uint256[] assetsIn;
    uint256[] maxAmountsIn;
    uint256 minOut;
    address recipient;
}

contract JoinAction is TransferAction {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Balancer v2 Vault
    IVault public immutable balancerVault;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error JoinAction__join_unsupportedProtocol();
    error JoinAction__transferAndJoin_invalidPermitParams();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    
    constructor(address balancerVault_) {
        balancerVault = IVault(balancerVault_);
    }

    /*//////////////////////////////////////////////////////////////
                             JOIN VARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a transfer from an EOA and then join via `joinParams`
    /// @param from The address to transfer from
    /// @param permitParams A list of parameters for the permit transfers, 
    /// must be the same length and in the same order as `joinParams` assets
    /// @param joinParams The parameters for the join
    function transferAndJoin(
        address from,
        PermitParams[] calldata permitParams,
        JoinParams calldata joinParams
    ) external {
        if (from != address(this)) {
            if (
                joinParams.assets.length != 
                permitParams.length
            ) {
                revert JoinAction__transferAndJoin_invalidPermitParams();
            }

            for (uint256 i = 0; i < joinParams.assets.length;) {
                if (joinParams.maxAmountsIn[i] != 0) {
                    _transferFrom(joinParams.assets[i], from, address(this), joinParams.maxAmountsIn[i], permitParams[i]);
                }
                
                unchecked {
                    ++i;
                }
            }
        }

        join(joinParams);
    }

    /// @notice Perform a join using the specified protocol
    /// @param joinParams The parameters for the join
    function join(JoinParams memory joinParams) public {
        address approveTarget;
        if(joinParams.protocol == JoinProtocol.BALANCER) {
            approveTarget = address(balancerVault);
        } else {
            revert JoinAction__join_unsupportedProtocol();
        }

        for (uint256 i = 0; i < joinParams.assets.length;) {
            if (joinParams.maxAmountsIn[i] != 0) {
                IERC20(joinParams.assets[i]).forceApprove(approveTarget, joinParams.maxAmountsIn[i]);
            }

            unchecked {
                ++i;
            }
        }

        if(joinParams.protocol == JoinProtocol.BALANCER) {
            balancerJoin(joinParams);
        }
    }

    /// @notice Perform a join using the Balancer protocol
    /// @param joinParams The parameters for the join
    /// @dev For more information regarding the Balancer join function check the 
    /// documentation in {IBalancerVault}
    function balancerJoin(JoinParams memory joinParams) public {
        balancerVault.joinPool(
            joinParams.poolId,
            address(this),
            joinParams.recipient,
            JoinPoolRequest({
                assets: joinParams.assets,
                maxAmountsIn: joinParams.maxAmountsIn,
                userData: abi.encode(JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, joinParams.assetsIn, joinParams.minOut),
                fromInternalBalance: false
            })
        );
    }

    /// @notice Helper function to update the join parameters for a levered position
    /// @param joinParams The parameters for the join
    /// @param upFrontToken The upfront token for the levered position
    /// @param joinToken The token to join with
    /// @param flashLoanAmount The amount of the flash loan
    /// @param upfrontAmount The amount of the upfront token
    function updateLeverJoin(
        JoinParams memory joinParams, 
        address joinToken,
        address upFrontToken, 
        uint256 flashLoanAmount,
        uint256 upfrontAmount,
        address poolToken
    ) external pure returns (JoinParams memory outParams) {
        outParams = joinParams;
        
        if (joinParams.protocol == JoinProtocol.BALANCER) {
            uint256 len = joinParams.assets.length;
            // the offset is needed because of the BPT token that needs to be skipped from the join
            bool skipIndex = false;
            uint256 joinAmount = flashLoanAmount;
            if(upFrontToken == joinToken) {
                joinAmount += upfrontAmount;
            }

            // update the join parameters with the new amounts
            for (uint256 i = 0; i < len;) {
                uint256 assetIndex = i - (skipIndex ? 1 : 0);
                if (joinParams.assets[i] == joinToken){
                    outParams.maxAmountsIn[i] = joinAmount;
                    outParams.assetsIn[assetIndex] = joinAmount;
                } else if (joinParams.assets[i] == upFrontToken && joinParams.assets[i] != poolToken) {
                    outParams.maxAmountsIn[i] = upfrontAmount;
                    outParams.assetsIn[assetIndex] = upfrontAmount;
                } else {
                    skipIndex = skipIndex || joinParams.assets[i] == poolToken;
                }
                unchecked {
                    i++;
                }
            }
        }
    }

}