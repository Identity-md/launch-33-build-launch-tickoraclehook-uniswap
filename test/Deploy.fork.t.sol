// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {TickOracleHook} from "../src/TickOracleHook.sol";
import {TickOracleToken} from "../src/TickOracleToken.sol";
import {HookFlags} from "../src/HookFlags.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Rehearses the launch against real Sepolia state: the live PoolManager, the real USDC.
/// @dev Skipped unless SEPOLIA_RPC_URL is set, so the suite stays runnable offline.
contract DeployForkTest is Test {
    using StateLibrary for IPoolManager;

    Deploy deploy;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        deploy = new Deploy();
    }

    function test_launchFactsHoldOnSepolia() public view {
        assertGt(address(deploy.POOL_MANAGER()).code.length, 0, "no PoolManager at the policy address");
        assertGt(deploy.USDC().code.length, 0, "no USDC at the policy address");
        assertEq(IERC20Metadata(deploy.USDC()).symbol(), "USDC");
        assertEq(IERC20Metadata(deploy.USDC()).decimals(), 6);
        assertGt(CREATE2_FACTORY.code.length, 0, "no CREATE2 factory");
        assertEq(deploy.FEE(), 3000);
        assertEq(deploy.TICK_SPACING(), 60);
        assertEq(deploy.INITIAL_SQRT_PRICE_X96(), 79228162514264337593543950336);
    }

    function test_deployScript_launchesHookTokenAndPool() public {
        (TickOracleHook hook, TickOracleToken token, PoolKey memory key) = deploy.run();

        // Hook: on an address carrying exactly its flags, bound to the live PoolManager.
        assertTrue(HookFlags.matches(address(hook), deploy.HOOK_FLAGS()));
        assertEq(address(hook.poolManager()), address(deploy.POOL_MANAGER()));

        // Token: the whole fixed supply, minted once to the broadcaster.
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.decimals(), 18);

        // Pool: TOS/USDC at the policy fee, spacing and price, with the hook attached.
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(hook));
        bool tokenIsCurrency0 = address(token) < deploy.USDC();
        assertEq(Currency.unwrap(key.currency0), tokenIsCurrency0 ? address(token) : deploy.USDC());
        assertEq(Currency.unwrap(key.currency1), tokenIsCurrency0 ? deploy.USDC() : address(token));

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = deploy.POOL_MANAGER().getSlot0(key.toId());
        assertEq(sqrtPriceX96, deploy.INITIAL_SQRT_PRICE_X96());
        assertEq(tick, 0);
        assertEq(lpFee, 3000);

        // The hook took its first observation on the live manager.
        (uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick) = hook.states(key.toId());
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);
        assertEq(lastTick, 0);
        (uint32 blockTimestamp,, bool initialized) = hook.observations(key.toId(), 0);
        assertEq(blockTimestamp, uint32(block.timestamp));
        assertTrue(initialized);
    }
}
