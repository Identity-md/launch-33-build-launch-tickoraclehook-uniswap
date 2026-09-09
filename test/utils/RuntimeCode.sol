// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Scans runtime bytecode for the opcodes that would make a contract's behaviour non-final.
/// @dev Steps over PUSH immediates so a constant that happens to contain 0xf4 or 0xff is not mistaken for
/// an instruction. Metadata is disabled in foundry.toml, so the whole code section is instructions.
library RuntimeCode {
    function assertNoEscapeHatch(bytes memory code) internal pure {
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f; // PUSH1..PUSH32 carry 1..32 bytes of immediate
                continue;
            }
            require(op != 0xff, "runtime code contains SELFDESTRUCT");
            require(op != 0xf4, "runtime code contains DELEGATECALL");
            require(op != 0xf2, "runtime code contains CALLCODE");
        }
    }
}
