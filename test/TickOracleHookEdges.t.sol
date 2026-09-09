// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickOracleHook} from "../src/TickOracleHook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {Oracle} from "../src/libraries/Oracle.sol";
import {TickOracleHookFixture} from "./utils/TickOracleHookFixture.sol";
import {Selectors} from "./utils/Selectors.sol";

/// @notice The inputs the happy path does not exercise: empty and maximal arguments, the same call twice,
/// swaps that do not move the tick or move it to its limit, pools in native ETH, callers the code did not
/// expect, and every revert reachable from outside.
contract TickOracleHookEdgesTest is TickOracleHookFixture {
    // ---------------------------------------------------------------------------------------------
    // observe: empty, maximal and repeated inputs
    // ---------------------------------------------------------------------------------------------

    function test_observe_emptyRequestReturnsAnEmptyAnswer() public {
        openPool(keyAB);
        int56[] memory none = hook.observe(keyAB, new uint32[](0));
        assertEq(none.length, 0);
    }

    function test_observe_emptyRequestStillRevertsForAPoolThisHookNeverInitialized() public {
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        hook.observe(keyBC, new uint32[](0));
    }

    function test_observe_keepsOrderAndDuplicates() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        vm.warp(START_TIME + 10);
        swap(keyAB, true);
        vm.warp(START_TIME + 20);

        uint32[] memory agos = new uint32[](5);
        agos[0] = 5;
        agos[1] = 0;
        agos[2] = 5;
        agos[3] = 15;
        agos[4] = 0;
        int56[] memory got = hook.observe(keyAB, agos);
        assertEq(got.length, 5);
        assertEq(got[0], got[2], "same input, same answer");
        assertEq(got[1], got[4], "same input, same answer");
        for (uint256 i = 0; i < agos.length; i++) {
            assertEq(got[i], observeOne(keyAB, agos[i]), "position changes the answer");
        }
    }

    function test_observe_theLargestSecondsAgoRevertsNamingTheWrappedTarget() public {
        openPool(keyAB);
        uint32 now32 = uint32(START_TIME);
        // 2**32 - 1 seconds ago wraps to one second in the future; the oracle refuses it as before the oldest.
        uint32[] memory agos = new uint32[](1);
        agos[0] = type(uint32).max;
        vm.expectRevert(predates(now32, now32 + 1));
        hook.observe(keyAB, agos);
    }

    function test_observe_oneBadEntryFailsTheWholeRequest() public {
        openPool(keyAB);
        vm.warp(START_TIME + 5);
        uint32[] memory agos = new uint32[](3);
        agos[0] = 0;
        agos[1] = 6; // one second before the pool existed
        agos[2] = 5;
        vm.expectRevert(predates(uint32(START_TIME), uint32(START_TIME - 1)));
        hook.observe(keyAB, agos);
    }

    function test_observe_inTheInitializationBlockOnlyNowExists() public {
        openPool(keyAB);
        assertEq(observeOne(keyAB, 0), 0);
        uint32[] memory agos = new uint32[](1);
        agos[0] = 1;
        vm.expectRevert(predates(uint32(START_TIME), uint32(START_TIME - 1)));
        hook.observe(keyAB, agos);
        vm.expectRevert(predates(uint32(START_TIME), uint32(START_TIME - 1)));
        hook.consult(keyAB, 1);
    }

    function test_observe_afterALongIdleStretchExtrapolatesTheWholeGap() public {
        openPool(keyAB);
        int24 tick = swap(keyAB, false);
        uint32 gap = 30 days;
        vm.warp(START_TIME + gap);
        assertEq(observeOne(keyAB, 0), int56(tick) * int56(uint56(gap)));
        assertEq(hook.consult(keyAB, gap), tick);
        assertEq(hook.consult(keyAB, 1), tick);

        // The next swap writes exactly that extrapolation as the observation.
        int24 next = swap(keyAB, true);
        assertObservation(keyAB, 0, uint32(START_TIME + gap), int56(tick) * int56(uint56(gap)), true);
        assertState(keyAB, 0, 1, 1, next);
    }

    // ---------------------------------------------------------------------------------------------
    // consult: window edges
    // ---------------------------------------------------------------------------------------------

    function test_consult_theLargestWindowReverts() public {
        openPool(keyAB);
        uint32 now32 = uint32(START_TIME);
        vm.expectRevert(predates(now32, now32 + 1));
        hook.consult(keyAB, type(uint32).max);
    }

    function test_consult_withTheDefaultCardinalityOnlyCoversTheSpanSinceTheNewestWrite() public {
        openPool(keyAB);
        vm.warp(START_TIME + 10);
        int24 tick1 = swap(keyAB, true);
        vm.warp(START_TIME + 25);
        int24 tick2 = swap(keyAB, false);
        // One live slot: it now holds the observation from t+25, and everything older is gone.
        assertObservation(keyAB, 0, uint32(START_TIME + 25), int56(tick1) * 15, true);

        vm.expectRevert(predates(uint32(START_TIME + 25), uint32(START_TIME + 24)));
        hook.consult(keyAB, 1);

        vm.warp(START_TIME + 40);
        assertEq(hook.consult(keyAB, 15), tick2);
        assertEq(hook.consult(keyAB, 1), tick2);
        vm.expectRevert(predates(uint32(START_TIME + 25), uint32(START_TIME + 24)));
        hook.consult(keyAB, 16);
    }

    function test_consult_overExactlyTheWholeLifeOfThePool() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        int24 tick0 = swap(keyAB, true);
        vm.warp(START_TIME + 10);
        int24 tick1 = swap(keyAB, false);
        vm.warp(START_TIME + 33);

        int256 sum = int256(tick0) * 10 + int256(tick1) * 23;
        assertEq(hook.consult(keyAB, 33), int24(floorDiv(sum, 33)));
        vm.expectRevert(predates(uint32(START_TIME), uint32(START_TIME - 1)));
        hook.consult(keyAB, 34);
    }

    function test_consult_revertsOnAZeroWindowBeforeLookingAtThePool() public {
        // Even a pool this hook never saw fails on the window first.
        vm.expectRevert(TickOracleHook.ZeroWindow.selector);
        hook.consult(keyBC, 0);
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        hook.consult(keyBC, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // increaseObservationCardinalityNext: zero, current, repeated, the cap
    // ---------------------------------------------------------------------------------------------

    function test_increaseObservationCardinalityNext_zeroAndTheCurrentValueAreNoOps() public {
        openPool(keyAB);

        vm.recordLogs();
        (uint16 oldNext, uint16 newNext) = hook.increaseObservationCardinalityNext(keyAB, 0);
        assertEq(oldNext, 1);
        assertEq(newNext, 1);
        (oldNext, newNext) = hook.increaseObservationCardinalityNext(keyAB, 1);
        assertEq(oldNext, 1);
        assertEq(newNext, 1);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op emitted");
        assertState(keyAB, 0, 1, 1, 0);
        assertObservation(keyAB, 1, 0, 0, false);

        hook.increaseObservationCardinalityNext(keyAB, 5);
        vm.recordLogs();
        (oldNext, newNext) = hook.increaseObservationCardinalityNext(keyAB, 5);
        assertEq(oldNext, 5);
        assertEq(newNext, 5);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op emitted");
    }

    function test_increaseObservationCardinalityNext_growsInStepsAndMarksOnlyTheNewSlots() public {
        openPool(keyAB);
        PoolId id = keyAB.toId();

        vm.expectEmit(true, false, false, true, address(hook));
        emit TickOracleHook.IncreaseObservationCardinalityNext(id, 1, 3);
        hook.increaseObservationCardinalityNext(keyAB, 3);
        assertObservation(keyAB, 1, 1, 0, false);
        assertObservation(keyAB, 2, 1, 0, false);
        assertObservation(keyAB, 3, 0, 0, false);

        vm.expectEmit(true, false, false, true, address(hook));
        emit TickOracleHook.IncreaseObservationCardinalityNext(id, 3, 6);
        (uint16 oldNext, uint16 newNext) = hook.increaseObservationCardinalityNext(keyAB, 6);
        assertEq(oldNext, 3);
        assertEq(newNext, 6);
        for (uint256 slot = 1; slot < 6; slot++) {
            assertObservation(keyAB, slot, 1, 0, false);
        }
        assertObservation(keyAB, 6, 0, 0, false);
        assertObservation(keyAB, 0, uint32(START_TIME), 0, true);
        assertState(keyAB, 0, 1, 6, 0);
    }

    function test_increaseObservationCardinalityNext_theCapIsIdempotentAndNothingPassesIt() public {
        openPool(keyAB);
        assertEq(hook.MAX_CARDINALITY(), 1024);

        (, uint16 newNext) = hook.increaseObservationCardinalityNext(keyAB, 1024);
        assertEq(newNext, 1024);

        vm.recordLogs();
        (uint16 oldNext, uint16 again) = hook.increaseObservationCardinalityNext(keyAB, 1024);
        assertEq(oldNext, 1024);
        assertEq(again, 1024);
        assertEq(vm.getRecordedLogs().length, 0, "growing to the cap twice emitted twice");

        vm.expectRevert(abi.encodeWithSelector(Oracle.CardinalityTooLarge.selector, uint16(1025), uint16(1024)));
        hook.increaseObservationCardinalityNext(keyAB, 1025);
        vm.expectRevert(abi.encodeWithSelector(Oracle.CardinalityTooLarge.selector, type(uint16).max, uint16(1024)));
        hook.increaseObservationCardinalityNext(keyAB, type(uint16).max);
        assertState(keyAB, 0, 1, 1024, 0);
    }

    function test_increaseObservationCardinalityNext_pastTheCapRevertsEvenOnAFreshPool() public {
        openPool(keyAB);
        vm.expectRevert(abi.encodeWithSelector(Oracle.CardinalityTooLarge.selector, uint16(2000), uint16(1024)));
        hook.increaseObservationCardinalityNext(keyAB, 2000);
    }

    function test_observations_theSlotPastTheCapIsUnreachable() public {
        openPool(keyAB);
        PoolId id = keyAB.toId();
        (uint32 ts,, bool init) = hook.observations(id, 1023);
        assertEq(ts, 0);
        assertFalse(init);
        // The generated getter bounds-checks with a bare revert, not a panic.
        (bool ok, bytes memory data) = address(hook).call(abi.encodeCall(hook.observations, (id, 1024)));
        assertFalse(ok, "read past the last slot");
        assertEq(data.length, 0);
        (ok,) = address(hook).call(abi.encodeCall(hook.observations, (id, type(uint256).max)));
        assertFalse(ok, "read far past the last slot");
    }

    // ---------------------------------------------------------------------------------------------
    // afterSwap: swaps the happy path does not make
    // ---------------------------------------------------------------------------------------------

    function test_afterSwap_exactOutputSwapsAreTrackedLikeExactInput() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);

        vm.warp(START_TIME + 10);
        int24 tick1 = swapAmount(keyAB, true, 1 ether); // exactly one token1 out
        assertLt(tick1, 0);
        assertState(keyAB, 1, 4, 4, tick1);
        assertObservation(keyAB, 1, uint32(START_TIME + 10), 0, true);

        vm.warp(START_TIME + 30);
        int24 tick2 = swapAmount(keyAB, false, 1 ether); // exactly one token0 out
        assertGt(tick2, tick1);
        assertState(keyAB, 2, 4, 4, tick2);
        assertObservation(keyAB, 2, uint32(START_TIME + 30), int56(tick1) * 20, true);
        assertEq(hook.consult(keyAB, 20), tick1);
    }

    function test_afterSwap_aSwapTooSmallToMoveTheTickStillWritesAnObservation() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        vm.warp(START_TIME + 5);
        int24 tick1 = swap(keyAB, false); // away from the tick boundary the pool opened on

        vm.warp(START_TIME + 12);
        int24 tick2 = swapAmount(keyAB, true, -1); // one wei of input
        assertEq(tick2, tick1, "one wei moved the tick");
        assertState(keyAB, 2, 4, 4, tick1);
        assertObservation(keyAB, 2, uint32(START_TIME + 12), int56(tick1) * 7, true);

        vm.warp(START_TIME + 20);
        assertEq(hook.consult(keyAB, 15), tick1);
    }

    function test_afterSwap_aSwapThatExhaustsTheRangeRecordsThePoolsTickAtItsLimit() public {
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        addLiquidity(keyAB, -120, 120, 10 ether); // a sliver of liquidity, easily drained
        hook.increaseObservationCardinalityNext(keyAB, 4);

        vm.warp(START_TIME + 10);
        int24 tick1 = swapAmount(keyAB, true, -100 ether); // a partial fill that runs to the price limit
        assertEq(tick1, TickMath.getTickAtSqrtPrice(TickMath.MIN_SQRT_PRICE + 1));
        assertEq(tick1, TickMath.MIN_TICK);
        assertState(keyAB, 1, 4, 4, tick1);

        vm.warp(START_TIME + 40);
        int24 tick2 = swapAmount(keyAB, false, -100 ether); // back through the range and out the other side
        assertEq(tick2, TickMath.getTickAtSqrtPrice(TickMath.MAX_SQRT_PRICE - 1));
        assertState(keyAB, 2, 4, 4, tick2);
        assertObservation(keyAB, 2, uint32(START_TIME + 40), int56(tick1) * 30, true);
        assertEq(hook.consult(keyAB, 30), tick1);
    }

    function test_afterSwap_extremeTicksAccumulateOverYearsWithoutOverflow() public {
        // An empty pool: its tick moves to whichever limit a swap asks for, at no cost, which is how the pool
        // itself behaves and exactly what the oracle must record. This is the widest tick swing possible.
        manager.initialize(keyAB, TickMath.MIN_SQRT_PRICE);
        assertState(keyAB, 0, 1, 1, TickMath.MIN_TICK);
        hook.increaseObservationCardinalityNext(keyAB, 4);

        uint32 year = 365 days;
        vm.warp(START_TIME + year);
        int24 top = swapAmount(keyAB, false, -1 ether);
        assertEq(top, TickMath.MAX_TICK - 1);
        int56 c1 = int56(TickMath.MIN_TICK) * int56(uint56(year));
        assertObservation(keyAB, 1, uint32(START_TIME + year), c1, true);

        vm.warp(START_TIME + 2 * year);
        int24 bottom = swapAmount(keyAB, true, -1 ether);
        assertEq(bottom, TickMath.MIN_TICK);
        int56 c2 = c1 + int56(top) * int56(uint56(year));
        assertObservation(keyAB, 2, uint32(START_TIME + 2 * year), c2, true);

        assertEq(hook.consult(keyAB, year), top);
        // A year at MIN_TICK and a year at MAX_TICK - 1 average to minus a half, which floors to minus one.
        assertEq(hook.consult(keyAB, 2 * year), -1);

        vm.warp(START_TIME + 3 * year);
        assertEq(observeOne(keyAB, 0), c2 + int56(TickMath.MIN_TICK) * int56(uint56(year)));
        assertEq(hook.consult(keyAB, year), TickMath.MIN_TICK);
    }

    function test_afterSwap_theSameBlockRuleHoldsAcrossSendersAndTransactions() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        tokenA.transfer(alice, 10 ether);
        tokenB.transfer(bob, 10 ether);

        vm.warp(START_TIME + 10);
        vm.startPrank(alice);
        tokenA.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(keyAB, swapParams(true, -SWAP_IN), settings(), "");
        vm.stopPrank();
        int24 afterAlice = currentTick(keyAB);
        assertState(keyAB, 1, 4, 4, afterAlice);

        vm.startPrank(bob);
        tokenB.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(keyAB, swapParams(false, -SWAP_IN), settings(), "");
        vm.stopPrank();
        int24 afterBob = currentTick(keyAB);
        assertTrue(afterBob != afterAlice);

        // Two transactions, two senders, one block: still one observation, carrying the pre-block tick.
        assertState(keyAB, 1, 4, 4, afterBob);
        assertObservation(keyAB, 1, uint32(START_TIME + 10), 0, true);
        assertObservation(keyAB, 2, 1, 0, false);
    }

    function test_afterSwap_hookDataIsIgnored() public {
        openPool(keyAB);
        openPool(keyABPlain);
        vm.warp(START_TIME + 3);
        bytes memory noise = abi.encode(address(0xBEEF), uint256(42), "anything at all");
        BalanceDelta hooked = swapRouter.swap(keyAB, swapParams(true, -SWAP_IN), settings(), noise);
        BalanceDelta plain = swapRouter.swap(keyABPlain, swapParams(true, -SWAP_IN), settings(), "");
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(hooked.amount1(), plain.amount1());
        assertEq(currentTick(keyAB), currentTick(keyABPlain));
        assertObservation(keyAB, 0, uint32(START_TIME + 3), 0, true);
    }

    /// @notice For any size and direction, a swap through the hooked pool settles exactly what the same swap
    /// through the hookless pool settles: the hook's delta really is zero.
    function testFuzz_afterSwap_neverChangesWhatASwapSettles(bool zeroForOne, bool exactOutput, uint96 size) public {
        int256 amount = int256(bound(uint256(size), 1, 50 ether));
        openPool(keyAB);
        openPool(keyABPlain);
        vm.warp(START_TIME + 7); // so the hooked pool takes the write path as well

        SwapParams memory params = swapParams(zeroForOne, exactOutput ? amount : -amount);
        BalanceDelta hooked = swapRouter.swap(keyAB, params, settings(), "");
        BalanceDelta plain = swapRouter.swap(keyABPlain, params, settings(), "");

        assertEq(hooked.amount0(), plain.amount0(), "amount0 differs from the hookless pool");
        assertEq(hooked.amount1(), plain.amount1(), "amount1 differs from the hookless pool");
        assertEq(currentTick(keyAB), currentTick(keyABPlain), "tick differs from the hookless pool");
        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds token0");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook holds token1");
        assertState(keyAB, 0, 1, 1, currentTick(keyAB));
        assertObservation(keyAB, 0, uint32(START_TIME + 7), 0, true);
    }

    // ---------------------------------------------------------------------------------------------
    // What the oracle must not react to
    // ---------------------------------------------------------------------------------------------

    function test_liquidityChangesAndDonationsLeaveTheOracleAlone() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 4);
        vm.warp(START_TIME + 10);
        int24 tick1 = swap(keyAB, true);
        assertState(keyAB, 1, 4, 4, tick1);

        vm.warp(START_TIME + 20);
        addLiquidity(keyAB, -120, 120, 5 ether);
        vm.warp(START_TIME + 30);
        addLiquidity(keyAB, RANGE_LOWER, RANGE_UPPER, -1 ether);
        vm.warp(START_TIME + 40);
        donateRouter.donate(keyAB, 1 ether, 1 ether, "");

        // No observation, no tick change, no promotion: the hook was never called.
        assertState(keyAB, 1, 4, 4, tick1);
        assertObservation(keyAB, 1, uint32(START_TIME + 10), 0, true);
        assertObservation(keyAB, 2, 1, 0, false);

        // Time still passed for the oracle, which extrapolates the standing tick across it.
        assertEq(observeOne(keyAB, 0), int56(tick1) * 30);
        assertEq(hook.consult(keyAB, 30), tick1);

        // And the next swap accumulates the whole idle stretch.
        int24 tick2 = swap(keyAB, false);
        assertState(keyAB, 2, 4, 4, tick2);
        assertObservation(keyAB, 2, uint32(START_TIME + 40), int56(tick1) * 30, true);
    }

    function test_manipulation_aSwapInTheCurrentBlockCannotMoveTheOracleUntilTheNextBlock() public {
        openPool(keyAB);
        hook.increaseObservationCardinalityNext(keyAB, 8);
        vm.warp(START_TIME + 10);
        swap(keyAB, true);
        vm.warp(START_TIME + 20);
        int24 standing = swap(keyAB, false);
        vm.warp(START_TIME + 30);

        int56 nowBefore = observeOne(keyAB, 0);
        int24 meanBefore = hook.consult(keyAB, 30);
        int24 lastSecondBefore = hook.consult(keyAB, 1);
        assertEq(lastSecondBefore, standing);

        int24 pushed = swapAmount(keyAB, true, -200 ether);
        assertLt(pushed, standing - 500, "the swap should have moved the price a long way");

        // Nothing a reader sees in this block has changed.
        assertEq(observeOne(keyAB, 0), nowBefore);
        assertEq(hook.consult(keyAB, 30), meanBefore);
        assertEq(hook.consult(keyAB, 1), standing);

        // From the next block the moved tick starts to count, one second at a time.
        vm.warp(START_TIME + 31);
        assertEq(observeOne(keyAB, 0), nowBefore + int56(pushed));
        assertEq(hook.consult(keyAB, 1), pushed);
        assertEq(hook.consult(keyAB, 11), int24(floorDiv(int256(standing) * 10 + int256(pushed), 11)));
    }

    // ---------------------------------------------------------------------------------------------
    // Pools the happy path does not open
    // ---------------------------------------------------------------------------------------------

    function test_nativeCurrencyPool_settlesLikeAHooklessPoolAndTheHookHoldsNoEth() public {
        vm.deal(address(this), 10_000 ether);
        PoolKey memory keyEth = poolKey(address(0), address(tokenA), 3000, TICK_SPACING, IHooks(address(hook)));
        PoolKey memory keyEthPlain = poolKey(address(0), address(tokenA), 3000, TICK_SPACING, IHooks(address(0)));
        manager.initialize(keyEth, SQRT_PRICE_1_1);
        manager.initialize(keyEthPlain, SQRT_PRICE_1_1);
        ModifyLiquidityParams memory range = ModifyLiquidityParams({
            tickLower: RANGE_LOWER, tickUpper: RANGE_UPPER, liquidityDelta: 100 ether, salt: bytes32(0)
        });
        lpRouter.modifyLiquidity{value: 100 ether}(keyEth, range, "");
        lpRouter.modifyLiquidity{value: 100 ether}(keyEthPlain, range, "");
        hook.increaseObservationCardinalityNext(keyEth, 4);
        assertState(keyEth, 0, 1, 4, 0);

        vm.warp(START_TIME + 10);
        BalanceDelta hooked = swapRouter.swap{value: 1 ether}(keyEth, swapParams(true, -1 ether), settings(), "");
        BalanceDelta plain = swapRouter.swap{value: 1 ether}(keyEthPlain, swapParams(true, -1 ether), settings(), "");
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(hooked.amount1(), plain.amount1());
        int24 tick1 = currentTick(keyEth);
        assertEq(tick1, currentTick(keyEthPlain));
        assertLt(tick1, 0);

        vm.warp(START_TIME + 25);
        hooked = swapRouter.swap(keyEth, swapParams(false, -1 ether), settings(), "");
        plain = swapRouter.swap(keyEthPlain, swapParams(false, -1 ether), settings(), "");
        assertEq(hooked.amount0(), plain.amount0());
        assertEq(hooked.amount1(), plain.amount1());
        int24 tick2 = currentTick(keyEth);

        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds the token");
        assertObservation(keyEth, 1, uint32(START_TIME + 10), 0, true);
        assertObservation(keyEth, 2, uint32(START_TIME + 25), int56(tick1) * 15, true);
        assertState(keyEth, 2, 4, 4, tick2);
        assertEq(hook.consult(keyEth, 25), int24(floorDiv(int256(tick1) * 15, 25)));
    }

    function test_theSamePairOnAnotherFeeTierIsAnotherOracle() public {
        PoolKey memory keyAB500 = poolKey(address(tokenA), address(tokenB), 500, 10, IHooks(address(hook)));
        openPool(keyAB);
        vm.warp(START_TIME + 5);
        manager.initialize(keyAB500, TickMath.getSqrtPriceAtTick(200));
        addLiquidity(keyAB500, -1000, 1000, RANGE_LIQUIDITY);
        assertTrue(PoolId.unwrap(keyAB.toId()) != PoolId.unwrap(keyAB500.toId()));
        hook.increaseObservationCardinalityNext(keyAB500, 2);
        assertState(keyAB, 0, 1, 1, 0);
        assertState(keyAB500, 0, 1, 2, 200);

        vm.warp(START_TIME + 15);
        int24 tickAB = swap(keyAB, true);
        assertState(keyAB, 0, 1, 1, tickAB);
        assertObservation(keyAB, 0, uint32(START_TIME + 15), 0, true);
        assertState(keyAB500, 0, 1, 2, 200);
        assertObservation(keyAB500, 0, uint32(START_TIME + 5), 0, true);

        vm.warp(START_TIME + 27);
        int24 tick500 = swap(keyAB500, false);
        assertState(keyAB500, 1, 2, 2, tick500);
        assertObservation(keyAB500, 0, uint32(START_TIME + 5), 0, true);
        assertObservation(keyAB500, 1, uint32(START_TIME + 27), int56(200) * 22, true);
        assertState(keyAB, 0, 1, 1, tickAB);
        assertObservation(keyAB, 0, uint32(START_TIME + 15), 0, true);
        assertObservation(keyAB, 1, 0, 0, false);
        assertEq(hook.consult(keyAB500, 22), 200);
        assertEq(hook.consult(keyAB, 12), tickAB);
    }

    function test_twoInstancesOfTheHookKeepSeparateOracles() public {
        TickOracleHook other = deployHook(manager, HOOK_FLAGS);
        assertTrue(address(other) != address(hook));
        PoolKey memory keyABOther =
            poolKey(address(tokenA), address(tokenB), 3000, TICK_SPACING, IHooks(address(other)));
        openPool(keyAB);
        openPool(keyABOther);

        vm.warp(START_TIME + 10);
        int24 tick = swap(keyAB, true);
        assertState(keyAB, 0, 1, 1, tick);
        assertObservation(keyAB, 0, uint32(START_TIME + 10), 0, true);

        // The other hook never saw keyAB's pool, and this hook never saw the other's.
        (uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick) = other.states(keyABOther.toId());
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);
        assertEq(lastTick, 0);
        (uint32 ts,, bool init) = other.observations(keyABOther.toId(), 0);
        assertEq(ts, uint32(START_TIME));
        assertTrue(init);

        uint32[] memory agos = new uint32[](1);
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        hook.observe(keyABOther, agos);
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        other.observe(keyAB, agos);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks: return values, and callers who are not the pool manager
    // ---------------------------------------------------------------------------------------------

    function test_afterSwap_returnsItsSelectorAndAZeroDeltaOnEveryPath() public {
        openPool(keyAB);
        SwapParams memory params = swapParams(true, -1);
        BalanceDelta none = BalanceDelta.wrap(0);

        // Same block as the newest observation: nothing written.
        vm.prank(address(manager));
        (bytes4 selector, int128 delta) = hook.afterSwap(address(this), keyAB, params, none, "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertState(keyAB, 0, 1, 1, 0);

        // A later block: an observation written into the only slot.
        vm.warp(START_TIME + 3);
        vm.prank(address(manager));
        (selector, delta) = hook.afterSwap(address(this), keyAB, params, none, "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertObservation(keyAB, 0, uint32(START_TIME + 3), 0, true);
        assertState(keyAB, 0, 1, 1, 0);

        // A later block with a reservation to promote.
        hook.increaseObservationCardinalityNext(keyAB, 2);
        vm.warp(START_TIME + 8);
        vm.prank(address(manager));
        (selector, delta) = hook.afterSwap(address(this), keyAB, params, none, "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(delta, 0);
        assertState(keyAB, 1, 2, 2, 0);
        assertObservation(keyAB, 1, uint32(START_TIME + 8), 0, true);
    }

    function test_afterInitialize_returnsItsSelectorAndRecordsTheTickItWasGiven() public {
        vm.prank(address(manager));
        bytes4 selector = hook.afterInitialize(address(this), keyBC, SQRT_PRICE_1_1, -4242);
        assertEq(selector, IHooks.afterInitialize.selector);
        (uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick) = hook.states(keyBC.toId());
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);
        assertEq(lastTick, -4242);
        assertObservation(keyBC, 0, uint32(START_TIME), 0, true);
    }

    function test_callbacks_refuseAnotherPoolManager() public {
        openPool(keyAB);
        PoolManager impostor = new PoolManager(address(this));
        SwapParams memory params = swapParams(true, -1);

        vm.prank(address(impostor));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), keyAB, params, BalanceDelta.wrap(0), "");

        vm.prank(address(impostor));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), keyBC, SQRT_PRICE_1_1, 0);

        // The pool manager the hook was built for is the only one it answers.
        assertEq(address(hook.poolManager()), address(manager));
        assertState(keyAB, 0, 1, 1, 0);
    }

    function test_callbacks_refuseTheHookItselfAndTheRouters() public {
        openPool(keyAB);
        SwapParams memory params = swapParams(true, -1);
        address[3] memory callers = [address(hook), address(swapRouter), address(lpRouter)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterSwap(address(this), keyAB, params, BalanceDelta.wrap(0), "");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // No admin surface
    // ---------------------------------------------------------------------------------------------

    function test_hook_hasNoAdminSetterOrEscapeHatchToCall() public {
        openPool(keyAB);
        string[20] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "setOwner(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "setPoolManager(address)",
            "setFee(uint24)",
            "setMaxCardinality(uint16)",
            "withdraw(address,uint256)",
            "sweep(address)",
            "collect(address,uint256)",
            "mint(address,uint256)",
            "burn(uint256)",
            "take(address,address,uint256)",
            "settle()",
            "reset(bytes32)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(this), uint256(1));
            vm.prank(address(0xBEEF));
            (bool ok,) = address(hook).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertState(keyAB, 0, 1, 1, 0);
        assertObservation(keyAB, 0, uint32(START_TIME), 0, true);
    }

    /// @notice The dispatcher reaches exactly the functions the hook declares: the ten IHooks callbacks, the
    /// permission and pool manager getters, and the oracle surface. Nothing is hidden behind a selector the
    /// interface does not name.
    function test_runtimeCode_dispatchesExactlyTheDeclaredFunctions() public view {
        bytes4[] memory found = Selectors.push4Immediates(address(hook).code);
        bytes4[18] memory declared = [
            IHooks.beforeInitialize.selector,
            IHooks.afterInitialize.selector,
            IHooks.beforeAddLiquidity.selector,
            IHooks.afterAddLiquidity.selector,
            IHooks.beforeRemoveLiquidity.selector,
            IHooks.afterRemoveLiquidity.selector,
            IHooks.beforeSwap.selector,
            IHooks.afterSwap.selector,
            IHooks.beforeDonate.selector,
            IHooks.afterDonate.selector,
            TickOracleHook.getHookPermissions.selector,
            bytes4(keccak256("poolManager()")),
            bytes4(keccak256("MAX_CARDINALITY()")),
            bytes4(keccak256("observations(bytes32,uint256)")),
            bytes4(keccak256("states(bytes32)")),
            TickOracleHook.increaseObservationCardinalityNext.selector,
            TickOracleHook.observe.selector,
            TickOracleHook.consult.selector
        ];
        for (uint256 i = 0; i < declared.length; i++) {
            assertTrue(Selectors.contains(found, declared[i]), "a declared function is missing from the dispatcher");
        }
        for (uint256 i = 0; i < found.length; i++) {
            bool isDeclared;
            for (uint256 k = 0; k < declared.length; k++) {
                if (found[i] == declared[k]) isDeclared = true;
            }
            // The compiler's width masks for uint32 and uint16 are the only other four-byte constants.
            bool isMask = found[i] == bytes4(0xffffffff) || found[i] == bytes4(0xffff0000);
            assertTrue(isDeclared || isMask, "an undeclared selector is reachable");
        }
    }
}
