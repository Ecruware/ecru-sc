// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {CDMHandler} from "./handlers/CDMHandler.sol";
import {StablecoinHandler} from "./handlers/StablecoinHandler.sol";

import {ACCOUNT_CONFIG_ROLE} from "../../CDM.sol";
import {MINTER_AND_BURNER_ROLE} from "../../Stablecoin.sol";

/// @title CDMInvariantTest
/// @notice CDM invariant tests 
contract CDMInvariantTest is InvariantTestBase{

    StablecoinHandler internal stablecoinHandler;
    CDMHandler internal cdmHandler;

    /// ======== Setup ======== ///
    function setUp() public override virtual{
        super.setUp();

        GhostVariableStorage ghostVariableStorage = new GhostVariableStorage();
        stablecoinHandler = new StablecoinHandler(address(stablecoin), this, ghostVariableStorage);
        stablecoin.grantRole(0x00, address(stablecoinHandler));
        stablecoin.grantRole(MINTER_AND_BURNER_ROLE, address(stablecoinHandler));
        // setup stablecoin handler selectors
        bytes4[] memory stablecoinHandlerSelectors = new bytes4[](7);
        stablecoinHandlerSelectors[0] = StablecoinHandler.mint.selector;
        stablecoinHandlerSelectors[1] = StablecoinHandler.burn.selector;
        stablecoinHandlerSelectors[2] = StablecoinHandler.transferFrom.selector;
        stablecoinHandlerSelectors[3] = StablecoinHandler.transfer.selector;
        stablecoinHandlerSelectors[4] = StablecoinHandler.approve.selector;
        stablecoinHandlerSelectors[5] = StablecoinHandler.increaseAllowance.selector;
        stablecoinHandlerSelectors[6] = StablecoinHandler.decreaseAllowance.selector;
        targetSelector(FuzzSelector({addr: address(stablecoinHandler), selectors: stablecoinHandlerSelectors}));
        cdmHandler = new CDMHandler(address(cdm), this, ghostVariableStorage);

        cdm.grantRole(ACCOUNT_CONFIG_ROLE, address(cdmHandler));
        // exclude the handlers from the invariants
        excludeSender(address(stablecoinHandler));
        excludeSender(address(cdmHandler));
        // label the handlers
        vm.label({ account: address(stablecoinHandler), newLabel: "StablecoinHandler" });
        vm.label({ account: address(cdmHandler), newLabel: "CDMHandler" });
        targetContract(address(stablecoinHandler));
        targetContract(address(cdmHandler));
    }

    /// ======== Stablecoin Invariant Tests ======== ///

    function invariant_Stablecoin_A() external useCurrentTimestamp printReport(stablecoinHandler) { 
        assert_invariant_Stablecoin_A(stablecoinHandler.totalUserBalance()); 
    }
    function invariant_Stablecoin_B() external useCurrentTimestamp printReport(stablecoinHandler) { 
        assert_invariant_Stablecoin_B(stablecoinHandler.mintAccumulator(), stablecoinHandler.burnAccumulator()); 
    }

    /// ======== CDM Invariant Tests ======== ///
    
    //function invariant_CDM_A() external useCurrentTimestamp { assert_invariant_CDM_A(); }
    function invariant_CDM_B() external useCurrentTimestamp printReport(cdmHandler) { assert_invariant_CDM_B(); }
    function invariant_CDM_C() external useCurrentTimestamp printReport(cdmHandler) { assert_invariant_CDM_C(cdmHandler); }
    function invariant_CDM_D() external useCurrentTimestamp printReport(cdmHandler) { assert_invariant_CDM_D(cdmHandler); }
    function invariant_CDM_E() external useCurrentTimestamp printReport(cdmHandler) { assert_invariant_CDM_E(cdmHandler); }
}