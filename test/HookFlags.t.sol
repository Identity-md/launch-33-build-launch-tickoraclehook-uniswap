// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @notice A contract with no constructor requirements, so mining can be checked for any flag set.
contract Placeholder {}

contract HookFlagsTest is Test {
    function test_constantsMirrorV4Core() public pure {
        assertEq(HookFlags.BEFORE_INITIALIZE, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(HookFlags.AFTER_INITIALIZE, Hooks.AFTER_INITIALIZE_FLAG);
        assertEq(HookFlags.BEFORE_ADD_LIQUIDITY, Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY, Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_REMOVE_LIQUIDITY, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_SWAP, Hooks.BEFORE_SWAP_FLAG);
        assertEq(HookFlags.AFTER_SWAP, Hooks.AFTER_SWAP_FLAG);
        assertEq(HookFlags.BEFORE_DONATE, Hooks.BEFORE_DONATE_FLAG);
        assertEq(HookFlags.AFTER_DONATE, Hooks.AFTER_DONATE_FLAG);
        assertEq(HookFlags.BEFORE_SWAP_RETURN_DELTA, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_SWAP_RETURN_DELTA, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.ALL, Hooks.ALL_HOOK_MASK);
        assertEq(HookFlags.ALL, (1 << 14) - 1);
    }

    function test_flagsOf_readsOnlyTheLowFourteenBits() public pure {
        address hook = address(uint160(0xABCDEF << 14) | uint160(HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP));
        assertEq(HookFlags.flagsOf(hook), HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP);
        assertEq(HookFlags.flagsOf(address(0)), 0);
        assertEq(HookFlags.flagsOf(address(type(uint160).max)), HookFlags.ALL);
    }

    function test_matches_requiresExactlyTheGivenFlags() public pure {
        uint160 wanted = HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP;
        address exact = address(uint160(1 << 40) | wanted);
        address extra = address(uint160(1 << 40) | wanted | HookFlags.BEFORE_SWAP);
        address fewer = address(uint160(1 << 40) | HookFlags.AFTER_SWAP);

        assertTrue(HookFlags.matches(exact, wanted));
        assertFalse(HookFlags.matches(extra, wanted));
        assertFalse(HookFlags.matches(fewer, wanted));
        assertTrue(HookFlags.matches(address(1 << 40), 0));

        // Bits above the flag range in `flags` are ignored.
        assertTrue(HookFlags.matches(exact, wanted | uint160(1 << 20)));
    }

    function testFuzz_miner_findsAnAddressCarryingExactlyTheFlags(uint160 flags) public {
        flags &= HookFlags.ALL;
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, type(Placeholder).creationCode, "");
        assertTrue(HookFlags.matches(predicted, flags));
        assertEq(HookMiner.computeAddress(address(this), salt, keccak256(type(Placeholder).creationCode)), predicted);

        Placeholder deployed = new Placeholder{salt: salt}();
        assertEq(address(deployed), predicted, "CREATE2 landed elsewhere");
    }

    function test_miner_skipsAddressesThatAlreadyHaveCode() public {
        uint160 flags = HookFlags.AFTER_SWAP;
        (address first, bytes32 salt) = HookMiner.find(address(this), flags, type(Placeholder).creationCode, "");
        new Placeholder{salt: salt}();

        (address second, bytes32 salt2) = HookMiner.find(address(this), flags, type(Placeholder).creationCode, "");
        assertTrue(salt2 != salt);
        assertTrue(second != first);
        assertTrue(HookFlags.matches(second, flags));
    }
}
