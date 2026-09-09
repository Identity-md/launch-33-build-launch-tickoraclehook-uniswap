// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickOracleHook} from "../src/TickOracleHook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {Oracle} from "../src/libraries/Oracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RuntimeCode} from "./utils/RuntimeCode.sol";

/// @notice Drives TickOracleHook through a live PoolManager: real pools, real swaps, warped blocks.
/// Every expected oracle value is computed here from the ticks and timestamps the test itself observed.
contract TickOracleHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant HOOK_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant START_TIME = 1_700_000_000;
    int24 constant TICK_SPACING = 60;
    int24 constant LIQUIDITY_LOWER = -6000;
    int24 constant LIQUIDITY_UPPER = 6000;
    int256 constant LIQUIDITY = 100 ether;
    int256 constant SWAP_IN = 1 ether;

    PoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    TickOracleHook hook;

    // Sorted so that tokenA < tokenB < tokenC.
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    PoolKey keyAB; // hooked
    PoolKey keyBC; // hooked, a second pool
    PoolKey keyABPlain; // same pair as keyAB, no hook: the settlement control

    function setUp() public {
        vm.warp(START_TIME);

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        hook = deployHook(HOOK_FLAGS);

        MockERC20[3] memory tokens =
            [new MockERC20("A", "A", SUPPLY), new MockERC20("B", "B", SUPPLY), new MockERC20("C", "C", SUPPLY)];
        // Three-element insertion sort by address.
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && address(tokens[j]) < address(tokens[j - 1]); j--) {
                (tokens[j], tokens[j - 1]) = (tokens[j - 1], tokens[j]);
            }
        }
        (tokenA, tokenB, tokenC) = (tokens[0], tokens[1], tokens[2]);
        for (uint256 i = 0; i < 3; i++) {
            tokens[i].approve(address(lpRouter), type(uint256).max);
            tokens[i].approve(address(swapRouter), type(uint256).max);
        }

        keyAB = poolKey(tokenA, tokenB, IHooks(address(hook)));
        keyBC = poolKey(tokenB, tokenC, IHooks(address(hook)));
        keyABPlain = poolKey(tokenA, tokenB, IHooks(address(0)));
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions and placement
    // ---------------------------------------------------------------------------------------------

    function test_permissions_areExactlyAfterInitializeAndAfterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);

        assertEq(HookFlags.flagsOf(address(hook)), HOOK_FLAGS, "address carries other flags");
        assertTrue(HookFlags.matches(address(hook), HOOK_FLAGS));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.MAX_CARDINALITY(), 1024);
    }

    function test_constructor_rejectsAnAddressWithoutItsFlags() public {
        (address wrong, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.BEFORE_SWAP, type(TickOracleHook).creationCode, abi.encode(manager));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        new TickOracleHook{salt: salt}(manager);
    }

    function test_runtimeCode_hasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "over the EIP-170 limit");
        RuntimeCode.assertNoEscapeHatch(code);
    }

    // ---------------------------------------------------------------------------------------------
    // afterInitialize
    // ---------------------------------------------------------------------------------------------

    function test_afterInitialize_writesTheFirstObservation() public {
        int24 tick = manager.initialize(keyAB, TickMath.getSqrtPriceAtTick(1000));
        assertEq(tick, 1000);

        assertState(keyAB, 0, 1, 1, 1000);
        assertObservation(keyAB, 0, uint32(START_TIME), 0, true);
        assertObservation(keyAB, 1, 0, 0, false);
    }

    function test_afterInitialize_keepsPoolsApart() public {
        manager.initialize(keyAB, TickMath.getSqrtPriceAtTick(-300));
        vm.warp(START_TIME + 7);
        manager.initialize(keyBC, TickMath.getSqrtPriceAtTick(300));

        assertState(keyAB, 0, 1, 1, -300);
        assertObservation(keyAB, 0, uint32(START_TIME), 0, true);
        assertState(keyBC, 0, 1, 1, 300);
        assertObservation(keyBC, 0, uint32(START_TIME + 7), 0, true);
    }

    // ---------------------------------------------------------------------------------------------
    // afterSwap
    // ---------------------------------------------------------------------------------------------

    function test_afterSwap_sameBlock_tracksTheTickWithoutASecondObservation() public {
        openPool(keyAB);

        int24 tick1 = swap(keyAB, true);
        assertLt(tick1, 0, "selling token0 should move the tick down");
        assertState(keyAB, 0, 1, 1, tick1);

        int24 tick2 = swap(keyAB, true);
        assertLt(tick2, tick1);
        assertState(keyAB, 0, 1, 1, tick2);

        // Still the single observation written at initialization.
        assertObservation(keyAB, 0, uint32(START_TIME), 0, true);
        assertObservation(keyAB, 1, 0, 0, false);
    }

    function test_afterSwap_newBlock_accumulatesTheTickOfThePreviousBlock() public {
        openPool(keyAB);
        int24 tick1 = swap(keyAB, true); // same block as initialization: no observation

        vm.warp(START_TIME + 10);
        int24 tick2 = swap(keyAB, false);
        // tick1 stood from START_TIME to START_TIME + 10; tick2 is only recorded for the next write.
        int56 c1 = int56(tick1) * 10;
        assertObservation(keyAB, 0, uint32(START_TIME + 10), c1, true);
        assertState(keyAB, 0, 1, 1, tick2);

        vm.warp(START_TIME + 25);
        int24 tick3 = swap(keyAB, false);
        int56 c2 = c1 + int56(tick2) * 15;
        assertObservation(keyAB, 0, uint32(START_TIME + 25), c2, true);
        assertState(keyAB, 0, 1, 1, tick3);

        // A second swap in the same block changes the tracked tick only.
        int24 tick4 = swap(keyAB, true);
        assertObservation(keyAB, 0, uint32(START_TIME + 25), c2, true);
        assertState(keyAB, 0, 1, 1, tick4);
    }

    function test_afterSwap_returnsAZeroDeltaSoSwapsSettleAsWithoutTheHook() public {
        openPool(keyAB);
        openPool(keyABPlain);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -SWAP_IN, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        BalanceDelta hooked = swapRouter.swap(keyAB, params, settings, "");
        BalanceDelta plain = swapRouter.swap(keyABPlain, params, settings, "");

        assertEq(hooked.amount0(), plain.amount0(), "amount0 differs from the hookless pool");
        assertEq(hooked.amount1(), plain.amount1(), "amount1 differs from the hookless pool");
        assertEq(hooked.amount0(), -int128(SWAP_IN));
        assertGt(hooked.amount1(), 0);

        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds token0");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook holds token1");
        assertEq(address(hook).balance, 0, "hook holds ETH");
    }

    // ---------------------------------------------------------------------------------------------
    // Cardinality growth and the ring
    // ---------------------------------------------------------------------------------------------

    function test_increaseObservationCardinalityNext_reservesSlotsAndEmits() public {
        openPool(keyAB);
        PoolId id = keyAB.toId();

        vm.expectEmit(true, false, false, true, address(hook));
        emit TickOracleHook.IncreaseObservationCardinalityNext(id, 1, 4);
        (uint16 oldNext, uint16 newNext) = hook.increaseObservationCardinalityNext(keyAB, 4);
        assertEq(oldNext, 1);
        assertEq(newNext, 4);

        // Reserved, not live: cardinality is still 1 until the ring wraps into the new slots.
        assertState(keyAB, 0, 1, 4, 0);
        for (uint256 i = 1; i < 4; i++) {
            assertObservation(keyAB, i, 1, 0, false);
        }
        assertObservation(keyAB, 4, 0, 0, false);

        // Not larger: a no-op that reports the current reservation.
        vm.recordLogs();
        (oldNext, newNext) = hook.increaseObservationCardinalityNext(keyAB, 3);
        assertEq(oldNext, 4);
        assertEq(newNext, 4);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op should not emit");
        assertState(keyAB, 0, 1, 4, 0);
    }

    function test_increaseObservationCardinalityNext_anyoneMayCall() public {
        openPool(keyAB);
        vm.prank(address(0xBEEF));
        (, uint16 newNext) = hook.increaseObservationCardinalityNext(keyAB, 2);
        assertEq(newNext, 2);
    }

    function test_increaseObservationCardinalityNext_stopsAtTheCap() public {
        openPool(keyAB);

        vm.expectRevert(abi.encodeWithSelector(Oracle.CardinalityTooLarge.selector, uint16(1025), uint16(1024)));
        hook.increaseObservationCardinalityNext(keyAB, 1025);

        (, uint16 newNext) = hook.increaseObservationCardinalityNext(keyAB, 1024);
        assertEq(newNext, 1024);
        assertObservation(keyAB, 1023, 1, 0, false);
    }

    function test_increaseObservationCardinalityNext_revertsForAPoolThisHookNeverInitialized() public {
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        hook.increaseObservationCardinalityNext(keyBC, 2);
    }

    function test_ring_growsIntoReservedSlotsAndWraps() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 3);
        int24 tickA = swap(keyAB, true); // same block: tracked, not written

        // First write past index cardinality-1 promotes the reservation: cardinality 1 -> 3.
        vm.warp(START_TIME + 10);
        int24 tickB = swap(keyAB, false);
        int56 c1 = int56(tickA) * 10;
        assertState(keyAB, 1, 3, 3, tickB);
        assertObservation(keyAB, 0, uint32(START_TIME), 0, true);
        assertObservation(keyAB, 1, uint32(START_TIME + 10), c1, true);

        vm.warp(START_TIME + 20);
        int24 tickC = swap(keyAB, false);
        int56 c2 = c1 + int56(tickB) * 10;
        assertState(keyAB, 2, 3, 3, tickC);
        assertObservation(keyAB, 2, uint32(START_TIME + 20), c2, true);

        // Third write wraps to slot 0, overwriting the initial observation.
        vm.warp(START_TIME + 30);
        int24 tickD = swap(keyAB, true);
        int56 c3 = c2 + int56(tickC) * 10;
        assertState(keyAB, 0, 3, 3, tickD);
        assertObservation(keyAB, 0, uint32(START_TIME + 30), c3, true);
        assertObservation(keyAB, 1, uint32(START_TIME + 10), c1, true);
        assertObservation(keyAB, 2, uint32(START_TIME + 20), c2, true);

        vm.warp(START_TIME + 40);
        int24 tickE = swap(keyAB, true);
        int56 c4 = c3 + int56(tickD) * 10;
        assertState(keyAB, 1, 3, 3, tickE);
        assertObservation(keyAB, 1, uint32(START_TIME + 40), c4, true);

        // Reads must follow the ring, not slot order: the oldest live observation is slot 2 (t+20).
        uint32[] memory secondsAgos = new uint32[](4);
        secondsAgos[0] = 20; // t+20: slot 2 exactly
        secondsAgos[1] = 15; // t+25: between slot 2 and slot 0
        secondsAgos[2] = 10; // t+30: slot 0 exactly
        secondsAgos[3] = 0; // t+40: slot 1 exactly
        int56[] memory cumulatives = hook.observe(keyAB, secondsAgos);
        assertEq(cumulatives[0], c2);
        assertEq(cumulatives[1], c2 + ((c3 - c2) / 10) * 5);
        assertEq(cumulatives[2], c3);
        assertEq(cumulatives[3], c4);

        // t+10 was overwritten, so 30 seconds back is beyond the buffer.
        secondsAgos = new uint32[](1);
        secondsAgos[0] = 21;
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(START_TIME + 20), uint32(START_TIME + 19)
            )
        );
        hook.observe(keyAB, secondsAgos);
    }

    function test_ring_growingMidCycleWaitsForTheWrap() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 2);
        vm.warp(START_TIME + 10);
        swap(keyAB, true); // index 0 -> 1, cardinality 2
        assertState(keyAB, 1, 2, 2, currentTick(keyAB));

        // Reserve more while the ring is mid-cycle: not used until index wraps past cardinality-1.
        hook.increaseObservationCardinalityNext(keyAB, 4);
        vm.warp(START_TIME + 20);
        swap(keyAB, true); // index 1 == cardinality-1: promote, index -> 2
        assertState(keyAB, 2, 4, 4, currentTick(keyAB));
        vm.warp(START_TIME + 30);
        swap(keyAB, true);
        assertState(keyAB, 3, 4, 4, currentTick(keyAB));
        vm.warp(START_TIME + 40);
        swap(keyAB, true);
        assertState(keyAB, 0, 4, 4, currentTick(keyAB));
    }

    // ---------------------------------------------------------------------------------------------
    // observe
    // ---------------------------------------------------------------------------------------------

    function test_observe_zeroSecondsAgo_extrapolatesFromTheNewestObservation() public {
        openPool(keyAB);
        int24 tick1 = swap(keyAB, true);

        vm.warp(START_TIME + 10);
        int24 tick2 = swap(keyAB, false);
        int56 c1 = int56(tick1) * 10;

        // Same block as the newest observation: no extrapolation.
        assertEq(observeOne(keyAB, 0), c1);

        // Later, with no swap since: the tracked tick is applied over the seconds elapsed.
        vm.warp(START_TIME + 40);
        assertEq(observeOne(keyAB, 0), c1 + int56(tick2) * 30);
    }

    function test_observe_readsExactObservationsAndInterpolatesBetweenThem() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        int24 tick1 = swap(keyAB, true);

        vm.warp(START_TIME + 10);
        int24 tick2 = swap(keyAB, false);
        int56 c1 = int56(tick1) * 10;

        vm.warp(START_TIME + 17);
        int24 tick3 = swap(keyAB, false);
        int56 c2 = c1 + int56(tick2) * 7;

        vm.warp(START_TIME + 40);

        uint32[] memory secondsAgos = new uint32[](6);
        secondsAgos[0] = 40; // START_TIME: observation 0 exactly
        secondsAgos[1] = 34; // t+6: between observation 0 and 1
        secondsAgos[2] = 30; // t+10: observation 1 exactly
        secondsAgos[3] = 27; // t+13: between observation 1 and 2
        secondsAgos[4] = 23; // t+17: observation 2 exactly
        secondsAgos[5] = 10; // t+30: after the newest, extrapolated with the tracked tick
        int56[] memory cumulatives = hook.observe(keyAB, secondsAgos);

        assertEq(cumulatives[0], 0);
        assertEq(cumulatives[1], 0 + ((c1 - 0) / 10) * 6);
        assertEq(cumulatives[2], c1);
        assertEq(cumulatives[3], c1 + ((c2 - c1) / 7) * 3);
        assertEq(cumulatives[4], c2);
        assertEq(cumulatives[5], c2 + int56(tick3) * 13);
    }

    function test_observe_revertsBeforeTheOldestObservation() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 2);
        vm.warp(START_TIME + 10);
        swap(keyAB, true);
        vm.warp(START_TIME + 30);

        // 30 seconds back is the initial observation itself: fine.
        assertEq(observeOne(keyAB, 30), 0);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 31;
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(START_TIME), uint32(START_TIME - 1)
            )
        );
        hook.observe(keyAB, secondsAgos);
    }

    function test_observe_revertsForAPoolThisHookNeverInitialized() public {
        uint32[] memory secondsAgos = new uint32[](1);
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        hook.observe(keyBC, secondsAgos);
    }

    // ---------------------------------------------------------------------------------------------
    // consult
    // ---------------------------------------------------------------------------------------------

    function test_consult_returnsTheMeanTickRoundedDown() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        int24 tick1 = swap(keyAB, true); // negative
        assertLt(tick1, 0);

        vm.warp(START_TIME + 10);
        int24 tick2 = swap(keyAB, false);
        int24 tick2b = swap(keyAB, false); // same block: replaces tick2 as the tracked tick
        assertGt(tick2b, tick2);

        vm.warp(START_TIME + 17);
        int24 tick3 = swap(keyAB, false);
        assertGt(tick3, 0);

        vm.warp(START_TIME + 30);

        // Whole history: tick1 for 10s, tick2b for 7s, tick3 for 13s.
        int256 sum = int256(tick1) * 10 + int256(tick2b) * 7 + int256(tick3) * 13;
        assertEq(hook.consult(keyAB, 30), int24(floorDiv(sum, 30)));

        // Last 13 seconds: tick3 alone.
        assertEq(hook.consult(keyAB, 13), tick3);

        // Last 20 seconds: tick2b for 7s, tick3 for 13s.
        assertEq(hook.consult(keyAB, 20), int24(floorDiv(int256(tick2b) * 7 + int256(tick3) * 13, 20)));

        // A window that starts between observations: 5s of tick1, 7s of tick2b, 13s of tick3.
        assertEq(
            hook.consult(keyAB, 25), int24(floorDiv(int256(tick1) * 5 + int256(tick2b) * 7 + int256(tick3) * 13, 25))
        );
    }

    function test_consult_roundsNegativeMeansTowardNegativeInfinity() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 2);
        int24 tick1 = swap(keyAB, true);
        assertLt(tick1, 0);

        vm.warp(START_TIME + 10);
        swap(keyAB, true);
        vm.warp(START_TIME + 10 + 3);

        // tick1 for 10s then the newer tick for 3s over a 13-second window.
        int256 sum = int256(tick1) * 10 + int256(currentTick(keyAB)) * 3;
        int256 expected = floorDiv(sum, 13);
        assertTrue(sum % 13 != 0, "pick inputs that do not divide evenly");
        assertEq(hook.consult(keyAB, 13), int24(expected));
        assertLt(expected * 13, sum, "floor lies strictly below");
    }

    function test_consult_revertsOnAZeroWindow() public {
        openPool(keyAB);
        vm.expectRevert(TickOracleHook.ZeroWindow.selector);
        hook.consult(keyAB, 0);
    }

    function test_consult_revertsWhenTheWindowOutrunsTheBuffer() public {
        openPool(keyAB);
        vm.warp(START_TIME + 5);
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(START_TIME), uint32(START_TIME - 1)
            )
        );
        hook.consult(keyAB, 6);
    }

    // ---------------------------------------------------------------------------------------------
    // uint32 wraparound
    // ---------------------------------------------------------------------------------------------

    function test_timestampsCompareCorrectlyAcrossTheUint32Wrap() public {
        uint256 wrap = 2 ** 32;
        vm.warp(wrap - 10); // uint32: 4294967286
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        int24 tick1 = swap(keyAB, true);
        assertObservation(keyAB, 0, uint32(wrap - 10), 0, true);

        vm.warp(wrap - 4); // uint32: 4294967292
        int24 tick2 = swap(keyAB, false);
        int56 c1 = int56(tick1) * 6;
        assertObservation(keyAB, 1, uint32(wrap - 4), c1, true);

        vm.warp(wrap + 5); // uint32: 5, nine seconds later across the wrap
        int24 tick3 = swap(keyAB, false);
        int56 c2 = c1 + int56(tick2) * 9;
        assertObservation(keyAB, 2, 5, c2, true);
        assertState(keyAB, 2, 4, 4, tick3);

        vm.warp(wrap + 12); // uint32: 12
        uint32[] memory secondsAgos = new uint32[](5);
        secondsAgos[0] = 0; // now: extrapolated 7s of tick3
        secondsAgos[1] = 7; // 5: newest observation exactly
        secondsAgos[2] = 10; // 2: between 4294967292 and 5, six seconds after the former
        secondsAgos[3] = 16; // 4294967292: exactly, reached by wrapping 12 - 16
        secondsAgos[4] = 22; // 4294967286: the oldest, exactly
        int56[] memory cumulatives = hook.observe(keyAB, secondsAgos);
        assertEq(cumulatives[0], c2 + int56(tick3) * 7);
        assertEq(cumulatives[1], c2);
        assertEq(cumulatives[2], c1 + ((c2 - c1) / 9) * 6);
        assertEq(cumulatives[3], c1);
        assertEq(cumulatives[4], 0);

        int256 sum = int256(tick1) * 6 + int256(tick2) * 9 + int256(tick3) * 7;
        assertEq(hook.consult(keyAB, 22), int24(floorDiv(sum, 22)));

        secondsAgos = new uint32[](1);
        secondsAgos[0] = 23;
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(wrap - 10), uint32(wrap - 11)
            )
        );
        hook.observe(keyAB, secondsAgos);
    }

    // ---------------------------------------------------------------------------------------------
    // Two pools
    // ---------------------------------------------------------------------------------------------

    function test_twoPools_keepIndependentBuffers() public {
        openPool(keyAB);
        vm.warp(START_TIME + 5);
        openPool(keyBC);
        hook.increaseObservationCardinalityNext(keyAB, 2);

        vm.warp(START_TIME + 15);
        int24 tickAB = swap(keyAB, true);
        vm.warp(START_TIME + 25);
        swap(keyAB, true);

        // keyBC was never swapped: still its initial observation and its initial tick.
        assertState(keyBC, 0, 1, 1, 0);
        assertObservation(keyBC, 0, uint32(START_TIME + 5), 0, true);
        assertEq(observeOne(keyBC, 0), 0);
        assertEq(hook.consult(keyBC, 20), 0);

        // keyAB has moved on its own.
        assertState(keyAB, 0, 2, 2, currentTick(keyAB));
        assertObservation(keyAB, 0, uint32(START_TIME + 25), int56(tickAB) * 10, true);

        // Now swap keyBC: its own ring advances, keyAB's does not.
        vm.warp(START_TIME + 30);
        int24 tickBC = swap(keyBC, false);
        assertState(keyBC, 0, 1, 1, tickBC);
        assertObservation(keyBC, 0, uint32(START_TIME + 30), 0, true); // 25s of tick 0
        assertObservation(keyAB, 0, uint32(START_TIME + 25), int56(tickAB) * 10, true);
    }

    // ---------------------------------------------------------------------------------------------
    // Access
    // ---------------------------------------------------------------------------------------------

    function test_callbacks_refuseCallersOtherThanThePoolManager() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 / 2});
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);

        bytes[10] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), keyAB, SQRT_PRICE_1_1)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), keyAB, SQRT_PRICE_1_1, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), keyAB, lp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), keyAB, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), keyAB, lp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), keyAB, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), keyAB, params, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), keyAB, params, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), keyAB, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), keyAB, 1, 1, ""))
        ];

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory data) = address(hook).call(calls[i]);
            assertFalse(ok, "a callback accepted a caller that was not the pool manager");
            assertEq(bytes4(data), BaseHook.NotPoolManager.selector);
        }
    }

    function test_callbacks_notDeclaredRevertEvenForThePoolManager() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 / 2});
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);

        bytes[8] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), keyAB, SQRT_PRICE_1_1)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), keyAB, lp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), keyAB, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), keyAB, lp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), keyAB, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), keyAB, params, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), keyAB, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), keyAB, 1, 1, ""))
        ];

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(address(manager));
            (bool ok, bytes memory data) = address(hook).call(calls[i]);
            assertFalse(ok, "an undeclared callback succeeded");
            assertEq(bytes4(data), BaseHook.HookNotImplemented.selector);
        }
    }

    function test_hook_acceptsNoValueAndHasNoFallback() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "accepted plain ETH");
        (ok,) = address(hook).call{value: 1}(abi.encodeCall(TickOracleHook.consult, (keyAB, 1)));
        assertFalse(ok, "accepted ETH with a call");
        (ok,) = address(hook).call(hex"deadbeef");
        assertFalse(ok, "has a fallback");
        assertEq(address(hook).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Places the hook by CREATE2 at an address carrying exactly `flags`, as the deployer will.
    function deployHook(uint160 flags) internal returns (TickOracleHook deployed) {
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TickOracleHook).creationCode, abi.encode(manager));
        deployed = new TickOracleHook{salt: salt}(manager);
        require(address(deployed) == expected, "hook landed off its mined address");
    }

    function poolKey(MockERC20 token0, MockERC20 token1, IHooks hooks) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    /// @dev Initializes `key` at 1:1 and seeds it with liquidity around the current price.
    function openPool(PoolKey memory key) internal {
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LIQUIDITY_LOWER, tickUpper: LIQUIDITY_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Swaps SWAP_IN of the input currency and returns the pool's tick afterwards.
    function swap(PoolKey memory key, bool zeroForOne) internal returns (int24) {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SWAP_IN,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return currentTick(key);
    }

    function currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function observeOne(PoolKey memory key, uint32 secondsAgo) internal view returns (int56) {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = secondsAgo;
        return hook.observe(key, secondsAgos)[0];
    }

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

    /// @dev Integer division rounding toward negative infinity.
    function floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q--;
    }
}
