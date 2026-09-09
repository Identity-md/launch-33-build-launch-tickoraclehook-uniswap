// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {TickOracleHook} from "../../src/TickOracleHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared scaffolding for the hook suites: a live PoolManager, the v4-core test routers, the hook
/// placed by CREATE2 at an address carrying exactly its two flags, three address-sorted tokens and the pool
/// keys the suites drive.
abstract contract TickOracleHookFixture is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant HOOK_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant START_TIME = 1_700_000_000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant RANGE_LOWER = -6000;
    int24 internal constant RANGE_UPPER = 6000;
    int256 internal constant RANGE_LIQUIDITY = 1000 ether;
    int256 internal constant SWAP_IN = 1 ether;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    PoolDonateTest internal donateRouter;
    TickOracleHook internal hook;

    // Sorted so that tokenA < tokenB < tokenC.
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    PoolKey internal keyAB; // hooked
    PoolKey internal keyBC; // hooked, a second pool
    PoolKey internal keyABPlain; // the same pair without a hook: the settlement control

    /// @dev The routers refund leftover ETH to their caller, which native-currency pools need.
    receive() external payable {}

    function setUp() public virtual {
        vm.warp(START_TIME);

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        donateRouter = new PoolDonateTest(manager);
        hook = deployHook(manager, HOOK_FLAGS);

        MockERC20[3] memory tokens =
            [new MockERC20("A", "A", SUPPLY), new MockERC20("B", "B", SUPPLY), new MockERC20("C", "C", SUPPLY)];
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && address(tokens[j]) < address(tokens[j - 1]); j--) {
                (tokens[j], tokens[j - 1]) = (tokens[j - 1], tokens[j]);
            }
        }
        (tokenA, tokenB, tokenC) = (tokens[0], tokens[1], tokens[2]);
        for (uint256 i = 0; i < 3; i++) {
            approveRouters(tokens[i]);
        }

        keyAB = poolKey(address(tokenA), address(tokenB), 3000, TICK_SPACING, IHooks(address(hook)));
        keyBC = poolKey(address(tokenB), address(tokenC), 3000, TICK_SPACING, IHooks(address(hook)));
        keyABPlain = poolKey(address(tokenA), address(tokenB), 3000, TICK_SPACING, IHooks(address(0)));
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment and keys
    // ---------------------------------------------------------------------------------------------

    /// @dev Places a hook by CREATE2 at an address carrying exactly `flags`, the way the deploy script does.
    function deployHook(PoolManager pm, uint160 flags) internal returns (TickOracleHook deployed) {
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TickOracleHook).creationCode, abi.encode(pm));
        deployed = new TickOracleHook{salt: salt}(pm);
        require(address(deployed) == expected, "hook landed off its mined address");
        require(HookFlags.matches(address(deployed), flags), "hook address carries the wrong flags");
    }

    function poolKey(address currency0, address currency1, uint24 fee, int24 tickSpacing, IHooks hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function approveRouters(MockERC20 token) internal {
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Pool actions
    // ---------------------------------------------------------------------------------------------

    /// @dev Initializes `key` at 1:1 and seeds it with liquidity around the current price.
    function openPool(PoolKey memory key) internal {
        manager.initialize(key, SQRT_PRICE_1_1);
        addLiquidity(key, RANGE_LOWER, RANGE_UPPER, RANGE_LIQUIDITY);
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        internal
        returns (BalanceDelta)
    {
        return lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Swaps SWAP_IN of the input currency and returns the pool's tick afterwards.
    function swap(PoolKey memory key, bool zeroForOne) internal returns (int24) {
        return swapAmount(key, zeroForOne, -SWAP_IN);
    }

    /// @dev Swaps `amountSpecified` (negative: exact input, positive: exact output) with the price limit at
    /// the pool's bound, and returns the pool's tick afterwards.
    function swapAmount(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (int24) {
        swapRouter.swap(key, swapParams(zeroForOne, amountSpecified), settings(), "");
        return currentTick(key);
    }

    function swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    // ---------------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------------

    function currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function observeOne(PoolKey memory key, uint32 secondsAgo) internal view returns (int56) {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = secondsAgo;
        return hook.observe(key, secondsAgos)[0];
    }

    // ---------------------------------------------------------------------------------------------
    // Assertions
    // ---------------------------------------------------------------------------------------------

    function assertState(PoolKey memory key, uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick)
        internal
        view
    {
        (uint16 i, uint16 c, uint16 n, int24 t) = hook.states(key.toId());
        assertEq(i, index, "index");
        assertEq(c, cardinality, "cardinality");
        assertEq(n, cardinalityNext, "cardinalityNext");
        assertEq(t, lastTick, "lastTick");
        assertEq(t, currentTick(key), "lastTick disagrees with the pool");
    }

    function assertObservation(
        PoolKey memory key,
        uint256 slot,
        uint32 blockTimestamp,
        int56 tickCumulative,
        bool initialized
    ) internal view {
        (uint32 ts, int56 c, bool init) = hook.observations(key.toId(), slot);
        assertEq(ts, blockTimestamp, "observation timestamp");
        assertEq(c, tickCumulative, "observation cumulative");
        assertEq(init, initialized, "observation initialized");
    }

    /// @dev The revert data for a read that reaches further back than the buffer holds.
    function predates(uint32 oldest, uint32 target) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, oldest, target);
    }

    /// @dev Integer division rounding toward negative infinity.
    function floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q--;
    }
}
