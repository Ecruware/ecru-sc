// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferAction, PermitParams} from "./TransferAction.sol";

import {IVault, JoinKind, JoinPoolRequest} from "../vendor/IBalancerVault.sol";

/// @notice The parameters for a join
struct JoinParams {
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
    
    constructor(address balancerVault_) {
        balancerVault = IVault(balancerVault_);
    }

    /*//////////////////////////////////////////////////////////////
                             JOIN VARIANTS
    //////////////////////////////////////////////////////////////*/

    function transferAndJoin(
        address from,
        PermitParams calldata permitParams,
        JoinParams calldata joinParams
    ) external {
        if (from != address(this)) {
            for (uint256 i = 0; i < joinParams.assets.length;){
                if (joinParams.maxAmountsIn[i] != 0) {
                    _transferFrom(joinParams.assets[i], from, address(this), joinParams.maxAmountsIn[i], permitParams);
                }
                
                unchecked {
                    ++i;
                }
            }
        }
        join(joinParams);
    }

    function join(JoinParams memory joinParams) public {
        for (uint256 i = 0; i < joinParams.assets.length;){
            if (joinParams.maxAmountsIn[i] != 0) {
                IERC20(joinParams.assets[i]).forceApprove(address(balancerVault), joinParams.maxAmountsIn[i]);
            }

            unchecked {
                ++i;
            }
        }
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
}