// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console2} from "forge-std/console2.sol";

import {Strings} from "openzeppelin/contracts/utils/Strings.sol";

import {InvariantTestBase} from "../InvariantTestBase.sol";

string constant USERS_CATEGORY = "USERS_CATEGORY";
string constant VAULTS_CATEGORY = "VAULTS_CATEGORY";
string constant CONTRACTS_CATEGORY = "CONTRACTS_CATEGORY";
string constant LIMIT_ORDERS_CATEGORY = "LIMIT_ORDERS_CATEGORY";

string constant TRACK_FUNCTION_START_KEY = "START";
string constant TRACK_FUNCTION_END_KEY = "END";

string constant RATE_ACCUMULATOR =  "rateAccumulator";
string constant SNAPSHOT_RATE_ACCUMULATOR = "snapshotRateAccumulator";

function getValueKey(address user, string memory key) pure returns (bytes32) {
    return keccak256(abi.encode(user, key));
}

/// @title GhostVariableStorage
/// @notice Ghost variable storage contract that tracks actors by category.
/// The contract can be used to track ghost variables as part of the change in state needed for the invariant test.
/// The intent is that storage can be shared between multiple handlers to track the state of the system.
contract GhostVariableStorage {

    // Track actors by category
    mapping(string category => address[] userList) public actors;

    // Store values for testing changes in state
    mapping(bytes32 key => bytes32 value) public values;

    function setValue(bytes32 key, bytes32 value_) public {
        values[key] = value_;
    }

    function actorsCount(string memory category) public view returns (uint256) {
        return actors[category].length;
    }

    function registered(string memory category, address user) public view returns (bool) {
        bytes32 userKey = keccak256(abi.encodePacked(category, user));
        return values[userKey] != 0;
    }

    function registerUser(string memory category, address user) public {
        bytes32 userKey = keccak256(abi.encodePacked(category, user));
        if (values[userKey] == 0) {
            actors[category].push(user);
            values[userKey] = bytes32(uint256(1));
        }
    }

    function unRegisterUser(string memory category, address user) public {
        bytes32 userKey = keccak256(abi.encodePacked(category, user));
        if (values[userKey] != 0) {
            uint256 actorCount = actors[category].length;
            for (uint256 i = 0; i < actorCount; ++i) {
                if (actors[category][i] == user) {
                    actors[category][i] = actors[category][actorCount - 1];
                    actors[category].pop();
                    break;
                }
            }
            delete values[userKey];
        }
    }
}

/// @title BaseHandler
/// @notice Base handler contract that provides the core functionality needed by handler contracts
abstract contract BaseHandler is  CommonBase, StdCheats, StdUtils {

    using Strings for string;

    /// ======== Constants ======== ///

    uint256 public immutable minWarp = 0;
    uint256 public immutable maxWarp = 30 days;

    string constant internal DEBUG_ENV = "INVARIANT_DEBUG";

    /// ======== Storage ======== ///

    // Name of the handler, used for debugging
    string public name;

    // Target test contract   
    InvariantTestBase public testContract;
    // Ghost variable storage contract
    GhostVariableStorage public ghostStorage;

    /// ======== Modifiers ======== ///

    // Modifier to restrict access to non-actor accounts
    modifier onlyNonActor(string memory category, address actor) {
        if (!ghostStorage.registered(category, actor)){
            _;
        }
    }

    // warp the time to the current timestamp
    modifier useCurrentTimestamp() {
        vm.warp(testContract.currentTimestamp());
        _;
    }

    // warp the time to the current timestamp, and then warp it by the given amount after the code execution
    modifier useAndUpdateCurrentTimestamp(uint256 warpAmount_) {
        warpInterval(warpAmount_);
        _;
    }

    constructor(string memory name_, InvariantTestBase testContract_, GhostVariableStorage ghostStorage_) {
        if(address(ghostStorage_) != address(0)){
            ghostStorage = ghostStorage_;
        } else {
            ghostStorage = new GhostVariableStorage();
        }
        
        name = name_;
        testContract = testContract_;
        registerContracts();
    }

    /// ======== Utility functions ======== ///    

    function warpInterval(uint256 warpAmount_) public {
        warpAmount_ = bound(warpAmount_, minWarp, maxWarp);
        testContract.setCurrentTimestamp(testContract.currentTimestamp() + warpAmount_);
        vm.warp(testContract.currentTimestamp());
    }

    // Virtual method to provide method signatures and names for the invariant test contract
    function getTargetSelectors() public pure virtual returns (bytes4[] memory selectors, string[] memory names);

    /// ======== Logging functions ======== ///    

    // Debug function that prints the call report to the console
    function printCallReport() public {
        string memory debugFlag = vm.envOr(DEBUG_ENV, string(""));

        // check if we should print this report
        if(!debugFlag.equal(name) && !debugFlag.equal("*")){
            return;
        }
        
        (bytes4[] memory selectors, string[] memory names) = getTargetSelectors();
        uint256 selectorCount = selectors.length;
        if(selectorCount == 0) return;

        console2.log("-----------------------[CALL REPORT]-----------------------");
        console2.log(" Vaults generated: %d", count(VAULTS_CATEGORY));
        console2.log(" Users generated: %d", count(USERS_CATEGORY));
        for (uint256 i = 0; i < selectorCount; ++i) {
            printCallCount(names[i], selectors[i]);
        }
    }

    // Print the call count for a given function
    function printCallCount(string memory functionName, bytes4 sig) public view {
        bytes32 keyStart = keccak256(abi.encodePacked(sig, TRACK_FUNCTION_START_KEY));
        bytes32 keyEnd = keccak256(abi.encodePacked(sig, TRACK_FUNCTION_END_KEY));

        uint256 enters = uint256(ghostStorage.values(keyStart));
        uint256 exits = uint256(ghostStorage.values(keyEnd));
        uint256 accuracy = 0;
        uint256 earlyExit = enters - exits;

        if(enters != 0){
            accuracy = (enters - earlyExit) * 100 / enters;
        }
        
        console2.log(" Function `%s` stats:", functionName);
        console2.log(" Call count %d | Early exits: %d | Accuracy: %d%", 
            enters, 
            earlyExit, 
            accuracy
        );
        console2.log("-----------------------------------------------------------");
    }

    /// ======== Tracking helper functions ======== ///    

    // Ghost storage functions
    function setGhostValue(bytes32 key, bytes32 value) public {
        ghostStorage.setValue(key, value);
    }

    function getGhostValue(bytes32 key) public view returns (bytes32) {
        return ghostStorage.values(key);
    }

    // Track when we enter a function
    function trackCallStart(bytes4 sig) internal {
        bytes32 keyStart = keccak256(abi.encodePacked(sig, TRACK_FUNCTION_START_KEY));
        uint256 enters = uint256(ghostStorage.values(keyStart));
        ghostStorage.setValue(keyStart, bytes32(enters + 1));
    }

    // Track when we exit a function
    function trackCallEnd(bytes4 sig) internal {
        bytes32 keyEnd = keccak256(abi.encodePacked(sig, TRACK_FUNCTION_END_KEY));
        uint256 exits = uint256(ghostStorage.values(keyEnd));
        ghostStorage.setValue(keyEnd, bytes32(exits + 1));
    }

    // Track a value change over time by storing the current and the previous value
    function trackValue(bytes32 key, bytes32 value) internal {
        bytes32 prevValueKey = keccak256(abi.encode(key, "PREV"));
        bytes32 currentValueKey = keccak256(abi.encode(key));
        bytes32 currentValue = getGhostValue(currentValueKey);
        if (currentValue == 0) currentValue = value;

        setGhostValue(prevValueKey, currentValue);
        setGhostValue(currentValueKey, value);
    }

    function trackValue(string memory key, bytes32 value) internal {
        trackValue(keccak256(abi.encode(key)), value);
    }

    // Retrieve the current and the previous value of a tracked property
    function getTrackedValue(bytes32 key) public view returns (bytes32 prevValue, bytes32 currentValue){
        bytes32 prevValueKey = keccak256(abi.encode(key, "PREV"));
        bytes32 currentValueKey = keccak256(abi.encode(key));
        prevValue = getGhostValue(prevValueKey);
        currentValue = getGhostValue(currentValueKey);
    }

    function getTrackedValue(string memory key) public view returns (bytes32 prevValue, bytes32 currentValue){
        return getTrackedValue(keccak256(abi.encode(key)));
    }

    // Track actors by category
    function addActor(string memory category, address a) internal {
        ghostStorage.registerUser(category, a);
    }

    // Remove a tracked actor from a category
    function removeActor(string memory category, address a) internal {
        ghostStorage.unRegisterUser(category, a);
    }

    function addActors(string memory category, address[] memory a) internal {
        uint256 actorCount = a.length;
        for (uint256 i = 0; i < actorCount; ++i) {
            addActor(category, a[i]);
        }
    }

    function count(string memory category) public view returns (uint256) {
        return ghostStorage.actorsCount(category);
    }

    function isRegistered(string memory category, address actor) public view returns (bool) {
        return ghostStorage.registered(category, actor);
    }

    function getActor(string memory category, uint256 index) public view returns (address) {
        return ghostStorage.actors(category, index);
    }

    function getRandomActor(string memory category, uint256 seed) public view returns (address) {
        uint256 actorCount = ghostStorage.actorsCount(category);
        if(actorCount == 0) return address(0);
        
        uint256 index = uint256(keccak256(abi.encodePacked(category, seed))) % actorCount;
        return ghostStorage.actors(category, index);
    }

    function registerContracts() virtual internal {
        address[] memory contracts = testContract.getContracts();
        for (uint256 i = 0; i < contracts.length; i++) {
            addActor(CONTRACTS_CATEGORY, contracts[i]);
        }
    }

    // Define common static size add actors functions for convenience
    // For example, addActors("borrower", [borrower1, borrower2]);
    // For dynamic size arrays, use addActors("borrower", borrowerArray);

    // 2 actors
    function addActors(string memory category, address[2] memory a) internal {
        uint256 actorCount = a.length;
        for (uint256 i = 0; i < actorCount; ++i) {
            addActor(category, a[i]);
        }
    }

    // 3 actors
    function addActors(string memory category, address[3] memory a) internal {
        uint256 actorCount = a.length;
        for (uint256 i = 0; i < actorCount; ++i) {
            addActor(category, a[i]);
        }
    }

    // 4 actors
    function addActors(string memory category, address[4] memory a) internal {
        uint256 actorCount = a.length;
        for (uint256 i = 0; i < actorCount; ++i) {
            addActor(category, a[i]);
        }
    }
}
