// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {WAD} from "../../utils/Math.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {JoinAction, JoinParams} from "../../proxy/JoinAction.sol";
import {PositionAction, LeverParams, CollateralParams} from "../../proxy/PositionAction.sol";
import {PositionActionAura} from "../../proxy/PositionActionAura.sol";

import {ApprovalType, PermitParams} from "../../proxy/TransferAction.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {PermitMaker} from "../utils/PermitMaker.sol";

// temp stuff
import {IVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IBaseRewardPool4626, IOperator} from "../../vendor/IBaseRewardPool4626.sol";
import {AuraVault} from "aura/AuraVault.sol";

contract PositionActionAuraTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    address wstETH_bb_a_WETH_BPTl = 0x41503C9D499ddbd1dCdf818a1b05e9774203Bf46;
    bytes32 poolId = 0x41503c9d499ddbd1dcdf818a1b05e9774203bf46000000000000000000000594;

    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant bbaweth = 0xbB6881874825E60e1160416D6C426eae65f2459E;
    address constant rewardToken = 0xba100000625a3754423978a60c9317c58a424e3D;

    ERC4626 constant auraRewardsPool = ERC4626(0xA822b750F8f84020ECD691164c5f6a0F7A5e7C64);

    // user
    PRBProxy userProxy;
    address internal user;
    uint256 internal userPk;
    uint256 internal constant NONCE = 0;

    // Permit2
    ISignatureTransfer internal constant permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // cdp vaults
    CDPVault_TypeA vault;

    AuraVault auraVault;

    function setUp() public override {
        super.setUp();

        vm.label(BALANCER_VAULT, "balancer");
        vm.label(wstETH, "wstETH");
        vm.label(bbaweth, "bbaweth");
        vm.label(wstETH_bb_a_WETH_BPTl, "wstETH-bb-a-WETH-BPTl");

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        auraVault = new AuraVault({
            rewardPool_: address(auraRewardsPool),
            asset_ : wstETH_bb_a_WETH_BPTl,
            feed_: address(oracle),
            maxClaimerIncentive_: 100,
            maxLockerIncentive_: 100,
            tokenName_:  "Aura Vault",
            tokenSymbol_: "auraVault"
        });

        // deploy vaults
        vault = createCDPVault_TypeA(
            ERC20(auraVault), // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            WAD, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        vault.addLimitPriceTick(1 ether, 0);

        // configure oracle spot prices
         oracle.updateSpot(address(wstETH_bb_a_WETH_BPTl), 1 ether);
         oracle.updateSpot(address(rewardToken), 1 ether);

        // configure vaults
        cdm.setParameter(address(vault), "debtCeiling", 5_000_000 ether);

        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        vm.startPrank(user);
        ERC20(wstETH).approve(address(permit2), type(uint256).max);
        ERC20(bbaweth).approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        vm.label(address(permit2), "permit2");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(user), "user");
        vm.label(address(auraRewardsPool), "BaseRewardPool");
        vm.label(address(0xA57b8d98dAE62B26Ec3bcC4a365338157060B234), "operator");
        vm.label(address(0xba100000625a3754423978a60c9317c58a424e3D), "rewardToken|crv");
        vm.label(address(0xaF52695E1bB01A16D33D7194C28C42b10e0Dbec2), "staker");
        vm.label(address(0xED5437c11D04f799363346EbCF2F272CA2bf127B), "staking token");
        vm.label(address(0x29488df9253171AcD0a0598FDdA92C5F6E767a38), "wstETH-bb-a-WETH-BPT Gauge Deposit proxy");
        vm.label(address(0xe5F96070CA00cd54795416B1a4b4c2403231c548), "wstETH-bb-a-WETH-BPT Gauge Deposit impl");
        vm.label(address(0xC128a9954e6c874eA3d62ce62B468bA073093F25), "Vote Escrowed Balancer BPT");
    }

    event debug(string message, address[] tokens);

    function test_deposit_asd() public {
        uint256 depositAmount = 1000 ether;

        deal(wstETH, user, depositAmount);
        deal(bbaweth, user, depositAmount);

        vm.startPrank(user);
        
        ERC20(wstETH).approve(address(BALANCER_VAULT), type(uint256).max);

        address[] memory tokens = new address[](3);
        tokens[0] = wstETH_bb_a_WETH_BPTl;
        tokens[1] = wstETH;
        tokens[2] = bbaweth;

        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[0] = 0;
        maxAmountsIn[1] = 100 ether;
        maxAmountsIn[2] = 0;

        uint256[] memory userAmountsIn = new uint256[](2);
        userAmountsIn[0] = 100 ether;
        userAmountsIn[1] = 0;
        
        IVault(BALANCER_VAULT).joinPool(
            poolId,
            user,
            user,
            JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, userAmountsIn, 0),
                fromInternalBalance: false
            })
        );

        uint256 balance = ERC20(wstETH_bb_a_WETH_BPTl).balanceOf(user);
        ERC20(wstETH_bb_a_WETH_BPTl).approve(address(auraVault), type(uint256).max);
        auraVault.deposit(balance, user);

        balance = auraVault.balanceOf(user);

        ERC20(auraVault).approve(address(vault), type(uint256).max);
        vault.deposit(user, balance);

        uint256 cash = vault.cash(user);
        vault.modifyCollateralAndDebt(user, user, user, int256(cash), 0);
    }

    function test_joinAction() public {
        uint256 depositAmount = 1000 ether;

        deal(wstETH, user, depositAmount);
        deal(bbaweth, user, depositAmount);

        // get permit2 signature
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = PermitMaker.getPermit2TransferFromSignature(
            address(wstETH),
            address(userProxy),
            depositAmount,
            NONCE,
            deadline,
            userPk
        );
        PermitParams memory permitParams = PermitParams({
            approvalType: ApprovalType.PERMIT2,
            approvalAmount: depositAmount,
            nonce: NONCE,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        address[] memory tokens = new address[](3);
        tokens[0] = wstETH_bb_a_WETH_BPTl;
        tokens[1] = wstETH;
        tokens[2] = bbaweth;

        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[0] = 0;
        maxAmountsIn[1] = 100 ether;
        maxAmountsIn[2] = 0;

        uint256[] memory tokensIn = new uint256[](2);
        tokensIn[0] = 100 ether;
        tokensIn[1] = 0;

        JoinParams memory joinParams = JoinParams({
            poolId: poolId,
            assets: tokens,
            assetsIn: tokensIn,
            maxAmountsIn: maxAmountsIn,
            minOut: 0,
            recipient: user
        });

        vm.startPrank(user);
        
        uint256 poolBefore = ERC20(0xED5437c11D04f799363346EbCF2F272CA2bf127B).balanceOf(address(auraRewardsPool));

        userProxy.execute(
            address(joinAction),
            abi.encodeWithSelector(
                joinAction.transferAndJoin.selector,
                user,
                permitParams,
                joinParams
            )
        );

        uint256 poolAfter = ERC20(0xED5437c11D04f799363346EbCF2F272CA2bf127B).balanceOf(address(auraRewardsPool));

        emit log_named_uint("pool balance after" , poolAfter);
        emit log_named_uint("Delta pool balance" , poolAfter - poolBefore);

        emit log_named_uint("token balance", ERC20(wstETH_bb_a_WETH_BPTl ).balanceOf(address(userProxy)));
        emit log_named_uint("token balance", ERC20(wstETH_bb_a_WETH_BPTl ).balanceOf(address(user)));
        emit log_named_uint("token balance", ERC20(wstETH_bb_a_WETH_BPTl ).balanceOf(address(this)));
    }

    function getForkBlockNumber() internal virtual override(IntegrationTestBase) pure returns (uint256){
        return 17870449; // Aug-08-2023 01:17:35 PM +UTC
    }
}