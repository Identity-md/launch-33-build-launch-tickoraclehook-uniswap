// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Tick Oracle Signal (TOS)
/// @notice The fixed-supply ERC-20 the TickOracleHook launch mints.
/// @dev A plain OpenZeppelin ERC20. The whole supply is minted once, in the constructor, to the deployer.
/// There is no owner, no mint or burn entry point afterwards, and no function beyond the ERC-20 standard.
/// Decimals are OpenZeppelin's default of 18.
contract TickOracleToken is ERC20 {
    /// @dev 1,000,000,000 tokens at 18 decimals: 1e27 base units.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Tick Oracle Signal", "TOS") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
