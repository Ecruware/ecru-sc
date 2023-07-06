// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {CDPVault_TypeAHandler} from "./handlers/CDPVault_TypeAHandler.sol";
import {CDPVault_TypeAWrapper} from "./CDPVault_TypeAWrapper.sol";

/// @title CDPVault_RInvariantTest
/// @notice CDPVault_R invariant tests 
contract CDPVault_TypeAInvariantTest is InvariantTestBase{

    CDPVault_TypeAWrapper internal vault;
    CDPVault_TypeAHandler internal vaultHandler;

    /// ======== Setup ======== ///

    function setUp() public override virtual{
        super.setUp();
        
        vault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            targetHealthFactor: 1.05 ether, 
            baseRate: BASE_RATE_1_005,
            limitOrderFloor: 1 ether,
            protocolFee: 0.01 ether
        });
        
        vaultHandler = new CDPVault_TypeAHandler(this, vault, new GhostVariableStorage());
        cdm.grantRole(keccak256("ACCOUNT_CONFIG_ROLE"), address(vaultHandler));

        excludeSender(address(vault));
        excludeSender(address(vaultHandler));

        vm.label({ account: address(vault), newLabel: "CDPVault_TypeA" });
        vm.label({ account: address(vaultHandler), newLabel: "CDPVault_TypeAHandler" });

        deal(address(token), address(vaultHandler), vaultHandler.tokenReserve());
        // setup CDPVault_R selectors 
        (bytes4[] memory selectors, ) = vaultHandler.getTargetSelectors();
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: selectors}));

        targetContract(address(vaultHandler));
    }

    /// ======== CDM Invariant Tests ======== ///

    function invariant_CDM_A() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_A(); }
    function invariant_CDM_B() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_B(); }
    function invariant_CDM_C() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_C(vaultHandler); }
    function invariant_CDM_D() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_D(vaultHandler); }
    function invariant_CDM_E() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_E(vaultHandler); }

    /// ======== CDPVault_R Invariant Tests ======== ///
    function invariant_CDPVault_TypeA_A() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_A(vault, vaultHandler); }
    function invariant_CDPVault_TypeA_B() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_B(vault, vaultHandler); }
    function invariant_CDPVault_TypeA_C() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_C(vault, vaultHandler); }
    function invariant_CDPVault_TypeA_D() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_D(vault, vaultHandler); }
    function invariant_CDPVault_TypeA_E() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_E(vault, vaultHandler); }
    function invariant_CDPVault_TypeA_F() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_F(vault, vaultHandler); }
}