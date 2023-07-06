// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";

import {IPermission} from "../../interfaces/IPermission.sol";

import {WAD} from "../../utils/Math.sol";
import {CDM} from "../../CDM.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

contract PositionOwner {
    constructor(IPermission vault) {
        // Allow deployer to modify Position
        vault.modifyPermission(msg.sender, true);
    }
}

contract CDPVaultTest is TestBase {

    uint256 constant internal BASE_RATE_1_025 = 1000000000780858271; // 2.5% base rate
    
    function setUp() public override {
        super.setUp();
    }

    function test_modifyCollateralAndDebt_cdm_reads_writes() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 100_000 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);

        address positionOwner = address(new PositionOwner(vault));
        token.mint(positionOwner, 100 ether);
        vm.startPrank(positionOwner);
        token.approve(address(vault), 100 ether);
        vault.deposit(positionOwner, 100 ether);

        vm.record();
        vault.modifyCollateralAndDebt(positionOwner, positionOwner, positionOwner, 100 ether, 50 ether);

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(
            address(cdm)
        );

        assertLe(reads.length, 14);
        assertLe(writes.length, 5);

        vm.stopPrank();
    }

    function test_modifyCollateralAndDebt_vault_reads_writes() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, 100_000 ether, 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);

        address positionOwner = address(new PositionOwner(vault));
        token.mint(positionOwner, 100 ether);
        vm.startPrank(positionOwner);
        token.approve(address(vault), 100 ether);
        vault.deposit(positionOwner, 100 ether);

        vm.record();
        vault.modifyCollateralAndDebt(positionOwner, positionOwner, positionOwner, 100 ether, 50 ether);

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(
            address(vault)
        );

        assertLe(reads.length, 25);
        assertLe(writes.length, 9);

        vm.stopPrank();
    }

    function test_modifyCollateralAndDebt_multiple() public {
        CDPVault_TypeA vault = createCDPVault_TypeA(token, uint256(type(int256).max), 0, 1.25 ether, 1.0 ether, 0, 1.05 ether, 0, WAD, BASE_RATE_1_025, 0, 0);
        uint256 posCount = 200;

        for (uint256 i=0; i<posCount; ++i){
            address positionOwner = address(new PositionOwner(vault));
            token.mint(positionOwner, 100 ether);

            vm.startPrank(positionOwner);

            token.approve(address(vault), 100 ether);
            vault.deposit(positionOwner, 100 ether);
            cdm.modifyPermission(address(vault), true);
            vault.modifyCollateralAndDebt(positionOwner, positionOwner, positionOwner, 100 ether, 50 ether);
            vault.modifyCollateralAndDebt(positionOwner, positionOwner, positionOwner, 0, -25 ether);

            vm.stopPrank();
        }
    }
}
