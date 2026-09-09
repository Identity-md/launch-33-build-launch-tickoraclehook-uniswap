// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Searches for a CREATE2 salt that lands a hook on an address carrying exactly the flags it needs.
/// @dev Fourteen flag bits means one address in 16,384 matches, so the search is short. The deploy script
/// and the tests both place the hook through this library, so a hook is deployed the same way in both.
library HookMiner {
    /// @notice Thrown when no salt below MAX_LOOP produces a matching address.
    error NoSaltFound(uint160 flags);

    /// @dev Upper bound on salts tried. A 14-bit match fails to appear within it with probability ~5e-6.
    uint256 internal constant MAX_LOOP = 200_000;

    /// @notice Finds a salt such that `deployer` deploying `creationCode ++ constructorArgs` with CREATE2
    /// lands on an address whose low fourteen bits equal `flags` exactly and which has no code yet.
    /// @param deployer The address that will perform the CREATE2: the CREATE2 factory in a script, or the
    /// test contract when it deploys directly.
    /// @param flags The exact set of permission bits the address must carry.
    /// @param creationCode The hook's creation code, without constructor arguments.
    /// @param constructorArgs The ABI-encoded constructor arguments.
    /// @return hookAddress The address the hook will be deployed to.
    /// @return salt The salt that produces it.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hookAddress, flags) && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }
        revert NoSaltFound(flags);
    }

    /// @notice The address CREATE2 assigns to `deployer` for `salt` and `initCodeHash`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
