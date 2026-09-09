// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {TickOracleHook} from "../src/TickOracleHook.sol";
import {TickOracleToken} from "../src/TickOracleToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @notice A stand-in for Circle's USDC with the one property the launch depends on: six decimals.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Rehearses the Sepolia launch with no network: a real PoolManager constructed at the policy address,
/// a six-decimal USDC at the policy address, and the deploy script run exactly as it would be broadcast.
/// @dev The fork test does the same against live state and skips without an RPC, so it never runs where the
/// suite is verified. This one always runs. It checks everything the fork test checks, and then uses what
/// was launched: seeds the TOS/USDC pool from the broadcaster's supply and trades on it across blocks.
contract DeployLocalTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant START_TIME = 1_700_000_000;
    uint256 constant TOTAL_SUPPLY = 1_000_000_000_000_000_000_000_000_000;

    Deploy deploy;
    PoolManager manager;
    MockUSDC usdc;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    function setUp() public {
        vm.warp(START_TIME);
        deploy = new Deploy();

        constructAt(
            abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))), address(deploy.POOL_MANAGER())
        );
        constructAt(type(MockUSDC).creationCode, deploy.USDC());
        manager = PoolManager(address(deploy.POOL_MANAGER()));
        usdc = MockUSDC(deploy.USDC());

        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
    }

    /// @dev Runs `initCode`'s constructor at `where`, so immutables such as PoolManager's NoDelegateCall anchor
    /// record that address. Etching runtime code copied from elsewhere would leave them pointing at the
    /// original, and every call to the copy would revert.
    function constructAt(bytes memory initCode, address where) internal {
        vm.etch(where, initCode);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok && runtime.length > 0, "constructor failed");
        vm.etch(where, runtime);
    }

    // ---------------------------------------------------------------------------------------------
    // The facts the policy fixes
    // ---------------------------------------------------------------------------------------------

    function test_scriptConstantsMatchTheLaunchPolicy() public view {
        assertEq(address(deploy.POOL_MANAGER()), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(deploy.USDC(), 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
        assertEq(deploy.FEE(), 3000);
        assertEq(deploy.TICK_SPACING(), 60);
        assertEq(deploy.INITIAL_SQRT_PRICE_X96(), 79228162514264337593543950336);
        assertEq(deploy.INITIAL_SQRT_PRICE_X96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(deploy.HOOK_FLAGS(), HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP);
        assertEq(deploy.HOOK_FLAGS(), 0x1040);
        assertEq(usdc.decimals(), 6);
    }

    function test_poolKey_sortsTheCurrenciesWhicheverSideTheTokenLandsOn() public view {
        address below = address(uint160(deploy.USDC()) - 1);
        address above = address(uint160(deploy.USDC()) + 1);
        IHooks hooks = IHooks(address(0x1040));

        PoolKey memory low = deploy.poolKey(below, hooks);
        assertEq(Currency.unwrap(low.currency0), below);
        assertEq(Currency.unwrap(low.currency1), deploy.USDC());

        PoolKey memory high = deploy.poolKey(above, hooks);
        assertEq(Currency.unwrap(high.currency0), deploy.USDC());
        assertEq(Currency.unwrap(high.currency1), above);

        assertEq(low.fee, 3000);
        assertEq(low.tickSpacing, 60);
        assertEq(address(low.hooks), address(hooks));
        assertEq(high.fee, 3000);
        assertEq(high.tickSpacing, 60);
    }

    // ---------------------------------------------------------------------------------------------
    // The launch itself
    // ---------------------------------------------------------------------------------------------

    function test_run_launchesTheHookTheTokenAndThePoolWithoutANetwork() public {
        // Mined here first, the way the script does it, so the address the script must land on is known
        // before it runs.
        (address predicted,) = HookMiner.find(
            CREATE2_FACTORY, deploy.HOOK_FLAGS(), type(TickOracleHook).creationCode, abi.encode(deploy.POOL_MANAGER())
        );

        vm.recordLogs();
        (TickOracleHook hook, TickOracleToken token, PoolKey memory key) = deploy.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Hook: through the CREATE2 factory, on an address carrying exactly its flags, bound to the policy
        // pool manager.
        assertEq(address(hook), predicted, "hook landed off the mined address");
        assertTrue(HookFlags.matches(address(hook), deploy.HOOK_FLAGS()));
        assertEq(HookFlags.flagsOf(address(hook)), 0x1040);
        assertEq(address(hook.poolManager()), address(deploy.POOL_MANAGER()));
        assertEq(hook.MAX_CARDINALITY(), 1024);

        // Token: the policy metadata, and the whole fixed supply minted once to whoever broadcast.
        assertEq(token.name(), "Tick Oracle Signal");
        assertEq(token.symbol(), "TOS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        address broadcaster = mintRecipient(logs, address(token));
        assertEq(token.balanceOf(broadcaster), TOTAL_SUPPLY, "the broadcaster does not hold the whole supply");
        assertEq(token.balanceOf(address(deploy)), 0, "the script contract kept tokens");
        assertEq(token.balanceOf(address(this)), 0, "the test kept tokens");
        assertEq(token.balanceOf(address(hook)), 0, "the hook holds tokens");

        // Pool: TOS against USDC at the policy fee, spacing and price, with the hook attached.
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(hook));
        bool tokenIsCurrency0 = address(token) < deploy.USDC();
        assertEq(Currency.unwrap(key.currency0), tokenIsCurrency0 ? address(token) : deploy.USDC());
        assertEq(Currency.unwrap(key.currency1), tokenIsCurrency0 ? deploy.USDC() : address(token));
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPriceX96, deploy.INITIAL_SQRT_PRICE_X96());
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, 3000);

        // The hook took its first observation from the live initialization.
        (uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick) = hook.states(key.toId());
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);
        assertEq(lastTick, 0);
        (uint32 blockTimestamp, int56 tickCumulative, bool initialized) = hook.observations(key.toId(), 0);
        assertEq(blockTimestamp, uint32(START_TIME));
        assertEq(tickCumulative, 0);
        assertTrue(initialized);

        // The pool can be initialized only once, so the launch cannot be replayed onto the same key.
        uint160 launchPrice = deploy.INITIAL_SQRT_PRICE_X96();
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, launchPrice);

        tradeOnTheLaunchedPool(hook, token, key, broadcaster);
    }

    /// @dev The launch leaves liquidity to whoever holds USDC. Here the broadcaster is given some, seeds the
    /// pool, and trades across blocks; the oracle must follow.
    function tradeOnTheLaunchedPool(TickOracleHook hook, TickOracleToken token, PoolKey memory key, address holder)
        internal
    {
        usdc.mint(holder, 1_000_000_000e6);
        vm.startPrank(holder);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);

        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e12, salt: bytes32(0)}), ""
        );
        (, uint16 grown) = hook.increaseObservationCardinalityNext(key, 4);
        assertEq(grown, 4);

        vm.warp(START_TIME + 12);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e9, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 tick1,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(tick1, 0);

        vm.warp(START_TIME + 36);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -2e9, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 tick2,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertGt(tick2, tick1);
        vm.stopPrank();

        (uint16 index, uint16 cardinality,, int24 lastTick) = hook.states(key.toId());
        assertEq(index, 2);
        assertEq(cardinality, 4);
        assertEq(lastTick, tick2);
        (uint32 ts1, int56 c1,) = hook.observations(key.toId(), 1);
        (uint32 ts2, int56 c2,) = hook.observations(key.toId(), 2);
        assertEq(ts1, uint32(START_TIME + 12));
        assertEq(c1, 0); // tick 0 for the first twelve seconds
        assertEq(ts2, uint32(START_TIME + 36));
        assertEq(c2, int56(tick1) * 24);
        assertEq(hook.consult(key, 24), tick1);
        assertEq(hook.consult(key, 36), int24(floorDiv(int256(tick1) * 24, 36)));
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(usdc.balanceOf(address(hook)), 0);
    }

    /// @dev The recipient of the single mint `token` emitted during the run.
    function mintRecipient(Vm.Log[] memory logs, address token) internal pure returns (address recipient) {
        uint256 mints;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != token || logs[i].topics[0] != IERC20.Transfer.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "the token emitted a non-mint transfer");
            recipient = address(uint160(uint256(logs[i].topics[2])));
            assertEq(abi.decode(logs[i].data, (uint256)), TOTAL_SUPPLY, "a partial mint");
            mints++;
        }
        assertEq(mints, 1, "the token minted more than once");
    }

    function floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q--;
    }
}
