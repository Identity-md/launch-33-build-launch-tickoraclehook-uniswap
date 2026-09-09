// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Collects the distinct four-byte immediates in runtime bytecode.
/// @dev Solidity's dispatcher compares the calldata selector against each externally reachable function's
/// selector held as a PUSH4 immediate, so the set of PUSH4 immediates in a contract's runtime code is a
/// superset of its function selectors. A function that was left out of the interface, or hidden behind a
/// selector nobody thought to call, still has to appear here to be reachable at all. The scan steps over
/// every PUSH immediate so bytes inside longer constants are not read as opcodes. Metadata is disabled in
/// foundry.toml, so the whole code section is instructions.
library Selectors {
    function push4Immediates(bytes memory code) internal pure returns (bytes4[] memory found) {
        bytes4[] memory scratch = new bytes4[](code.length / 5 + 1);
        uint256 n;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op < 0x60 || op > 0x7f) continue;
            uint256 len = op - 0x5f; // PUSH1..PUSH32 carry 1..32 bytes of immediate
            if (len == 4 && i + 4 < code.length) {
                bytes4 value = bytes4(bytes.concat(code[i + 1], code[i + 2], code[i + 3], code[i + 4]));
                if (!contains(scratch, n, value)) scratch[n++] = value;
            }
            i += len;
        }
        found = new bytes4[](n);
        for (uint256 k = 0; k < n; k++) {
            found[k] = scratch[k];
        }
    }

    function contains(bytes4[] memory set, bytes4 value) internal pure returns (bool) {
        return contains(set, set.length, value);
    }

    function contains(bytes4[] memory set, uint256 length, bytes4 value) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (set[i] == value) return true;
        }
        return false;
    }
}
