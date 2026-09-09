// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickOracleHook} from "../src/TickOracleHook.sol";
import {TickOracleToken} from "../src/TickOracleToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title Deploy
/// @notice Launches TickOracleHook and TickOracleToken on Sepolia and opens the TOS/USDC pool on the hook.
/// @dev The launch facts below are fixed by policy; the README states the same numbers. The hook is placed
/// by CREATE2 through the deterministic factory at an address mined to carry exactly its two flags, the
/// token mints its whole supply to the broadcasting account, and the pool is initialized at 1:1.
///
/// Simulate:  forge script script/Deploy.s.sol --rpc-url sepolia
/// Broadcast: forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --account <name> --verify
contract Deploy is Script {
    /// @notice Uniswap v4 PoolManager on Sepolia.
    IPoolManager public constant POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);

    /// @notice USDC on Sepolia: the currency TOS is paired with.
    address public constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /// @notice Fee tier of the launch pool, in hundredths of a bip.
    uint24 public constant FEE = 3000;

    /// @notice Canonical tick spacing for the 0.30% tier.
    int24 public constant TICK_SPACING = 60;

    /// @notice sqrtPriceX96 for a 1:1 price.
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336;

    /// @notice The permission bits the hook's address must carry.
    uint160 public constant HOOK_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP;

    function run() external returns (TickOracleHook hook, TickOracleToken token, PoolKey memory key) {
        // Salted `new` under broadcast goes through forge-std's deterministic CREATE2 factory, which is
        // live on Sepolia, so that is the deployer the salt must be mined for.
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(TickOracleHook).creationCode, abi.encode(POOL_MANAGER));

        vm.startBroadcast();

        hook = new TickOracleHook{salt: salt}(POOL_MANAGER);
        require(address(hook) == hookAddress, "hook landed off its mined address");

        token = new TickOracleToken();

        key = poolKey(address(token), IHooks(address(hook)));
        POOL_MANAGER.initialize(key, INITIAL_SQRT_PRICE_X96);

        vm.stopBroadcast();

        console.log("TickOracleHook  ", address(hook));
        console.log("TickOracleToken ", address(token));
        console.log("Pool id");
        console.logBytes32(PoolId.unwrap(key.toId()));
    }

    /// @notice The launch pool's key for `token` and `hooks`: currencies sorted, fee and spacing fixed.
    function poolKey(address token, IHooks hooks) public pure returns (PoolKey memory) {
        (address currency0, address currency1) = token < USDC ? (token, USDC) : (USDC, token);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }
}
