// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickOracleHook} from "../src/TickOracleHook.sol";
import {TickOracleHookFixture} from "./utils/TickOracleHookFixture.sol";

/// @notice Drives the hook through sequences of real swaps, warped blocks, buffer growth and liquidity changes
/// on two live pools, and checks every state field, every ring slot and every read against a reference model
/// kept in this test.
/// @dev The model is deliberately naive. It keeps timestamps unwrapped, walks its ring in order instead of
/// binary searching, and interpolates with the rule the task states (v3's per-second quotient), so a wrong
/// search, a wrong promotion, a wrong wrap or a wrong interpolation in the hook shows up as a disagreement
/// rather than being reproduced.
contract TickOracleHookModelTest is TickOracleHookFixture {
    struct Slot {
        /// @dev Unwrapped. Zero for a slot never touched; one for a slot reserved by growth but not written.
        uint256 timestamp;
        int56 tickCumulative;
        bool initialized;
    }

    struct Model {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
        int24 lastTick;
        Slot[1024] ring;
    }

    uint16 internal constant CAP = 1024;
    uint256 internal constant STEPS = 48;

    Model[2] internal models;
    PoolKey[2] internal keys;

    /// @dev The unwrapped block timestamp the test believes in; the hook only ever sees it truncated.
    uint256 internal clock;

    function setUp() public override {
        super.setUp();
        keys[0] = keyAB;
        keys[1] = keyBC;
    }

    // ---------------------------------------------------------------------------------------------
    // Random sequences on two pools
    // ---------------------------------------------------------------------------------------------

    /// @notice Every reachable state of the hook agrees with the model, at every step, on both pools.
    /// @param seed Drives the sequence: which pool, swap or warp or grow or liquidity change or read.
    /// @param nearTheWrap Starts the clock just before the uint32 timestamp wraps, so the sequence crosses it.
    function testFuzz_hook_agreesWithTheReferenceModel(uint256 seed, bool nearTheWrap) public {
        clock = nearTheWrap ? 2 ** 32 - 61 : START_TIME;
        vm.warp(clock);
        for (uint256 p = 0; p < 2; p++) {
            openPool(keys[p]);
            modelInitialize(models[p], clock, currentTick(keys[p]));
            checkState(p);
        }

        int256[3] memory amounts = [int256(0.001 ether), 0.1 ether, 1 ether];

        for (uint256 step = 0; step < STEPS; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 p = r % 2;
            r >>= 8;
            uint256 action = r % 16;
            r >>= 8;

            if (action < 6) {
                // A swap: either direction, exact input or exact output, three sizes.
                bool zeroForOne = r % 2 == 0;
                r >>= 8;
                int256 amount = amounts[r % 3];
                r >>= 8;
                bool exactOutput = r % 4 == 0;
                int24 tick = swapAmount(keys[p], zeroForOne, exactOutput ? amount : -amount);
                modelSwap(models[p], clock, tick);
            } else if (action < 11) {
                // A new block, or (one time in four) more activity in the same block.
                uint256 elapsed = r % 4 == 0 ? 0 : 1 + ((r >> 8) % 90);
                clock += elapsed;
                vm.warp(clock);
            } else if (action < 13) {
                // Reserve room, sometimes less than is already reserved, sometimes zero.
                uint16 wanted = uint16(r % 24);
                uint16 reservedBefore = models[p].cardinalityNext;
                (uint16 reportedOld, uint16 reportedNew) = hook.increaseObservationCardinalityNext(keys[p], wanted);
                modelGrow(models[p], wanted);
                assertEq(reportedOld, reservedBefore, "reported old reservation");
                assertEq(reportedNew, models[p].cardinalityNext, "reported new reservation");
            } else if (action < 14) {
                // Liquidity moves that the hook has no permission to see. They must not touch the oracle.
                int24 tickBefore = currentTick(keys[p]);
                addLiquidity(keys[p], RANGE_LOWER, RANGE_UPPER, r % 2 == 0 ? int256(1 ether) : -int256(1 ether));
                assertEq(currentTick(keys[p]), tickBefore, "a liquidity change moved the tick");
            } else {
                checkReads(p, r);
            }

            checkState(0);
            checkState(1);
        }

        for (uint256 p = 0; p < 2; p++) {
            checkRing(p);
            checkReads(p, uint256(keccak256(abi.encode(seed, p, "final"))));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The largest buffer
    // ---------------------------------------------------------------------------------------------

    /// @notice A buffer grown to the cap fills all 1024 slots, wraps its index back to zero, overwrites its
    /// oldest observations, and answers reads over the whole ring, including across the storage boundary
    /// between slot 1023 and slot 0.
    function test_ring_atTheCap_wrapsAndSearchesAcrossTheWholeRing() public {
        PoolKey memory key = keys[0];
        Model storage m = models[0];
        PoolId id = key.toId();

        clock = START_TIME;
        openPool(key);
        modelInitialize(m, clock, currentTick(key));
        (, uint16 reserved) = hook.increaseObservationCardinalityNext(key, CAP);
        assertEq(reserved, CAP);
        modelGrow(m, CAP);

        uint256 writes = uint256(CAP) + 6; // one full pass, then six slots into the second
        for (uint256 i = 1; i <= writes; i++) {
            clock += 2 + (i % 5); // 2 to 6 seconds per block, never zero
            vm.warp(clock);
            int24 tick = swapAmount(key, i % 3 != 0, -0.01 ether);
            modelSwap(m, clock, tick);
        }

        checkState(0);
        (uint16 index, uint16 cardinality,,) = hook.states(id);
        assertEq(index, uint16(writes % CAP), "index after wrapping");
        assertEq(cardinality, CAP, "cardinality at the cap");

        // Slot index+1 holds the oldest live observation: the one from write index+1, since writes 1..1023 went
        // to their own slot numbers and writes 1024.. started overwriting from slot 0.
        (uint256[] memory ts,) = liveObservations(m);
        assertEq(ts.length, CAP, "every slot is live");
        (uint32 oldestTs,, bool oldestInit) = hook.observations(id, index + 1);
        assertTrue(oldestInit);
        assertEq(oldestTs, uint32(ts[0]), "oldest observation sits after the newest");

        checkRing(0);

        clock += 5;
        vm.warp(clock);
        checkReads(0, uint256(keccak256("cap")));

        // Reads on both sides of the storage boundary, chosen explicitly.
        uint32[] memory agos = new uint32[](4);
        agos[0] = uint32(clock - m.ring[CAP - 1].timestamp); // slot 1023 exactly
        agos[1] = uint32(clock - m.ring[0].timestamp); // slot 0 exactly, from the second pass
        agos[2] = uint32(clock - m.ring[CAP - 1].timestamp - 1); // between them
        agos[3] = uint32(clock - m.ring[index + 1].timestamp); // the oldest exactly
        int56[] memory got = hook.observe(key, agos);
        (uint256[] memory liveTs, int56[] memory liveCum) = liveObservations(m);
        for (uint256 i = 0; i < agos.length; i++) {
            (bool ok, int56 want) = modelObserve(m, liveTs, liveCum, agos[i]);
            assertTrue(ok);
            assertEq(got[i], want, "read across the storage boundary");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Checks against the model
    // ---------------------------------------------------------------------------------------------

    function checkState(uint256 p) internal view {
        Model storage m = models[p];
        PoolKey memory key = keys[p];
        (uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick) = hook.states(key.toId());
        assertEq(index, m.index, "index");
        assertEq(cardinality, m.cardinality, "cardinality");
        assertEq(cardinalityNext, m.cardinalityNext, "cardinalityNext");
        assertEq(lastTick, m.lastTick, "lastTick");
        assertEq(lastTick, currentTick(key), "lastTick disagrees with the pool");
        assertLt(index, cardinality, "index < cardinality");
        assertLe(cardinality, cardinalityNext, "cardinality <= cardinalityNext");
        assertLe(cardinalityNext, CAP, "cardinalityNext <= cap");
    }

    function checkRing(uint256 p) internal view {
        Model storage m = models[p];
        PoolId id = keys[p].toId();
        for (uint256 slot = 0; slot < m.cardinalityNext; slot++) {
            (uint32 ts, int56 cumulative, bool initialized) = hook.observations(id, slot);
            assertEq(ts, uint32(m.ring[slot].timestamp), "slot timestamp");
            assertEq(cumulative, m.ring[slot].tickCumulative, "slot cumulative");
            assertEq(initialized, m.ring[slot].initialized, "slot initialized");
        }
        if (m.cardinalityNext < CAP) {
            (uint32 ts, int56 cumulative, bool initialized) = hook.observations(id, m.cardinalityNext);
            assertEq(ts, 0, "slot past the reservation was touched");
            assertEq(cumulative, 0, "slot past the reservation was touched");
            assertFalse(initialized, "slot past the reservation was touched");
        }
    }

    /// @dev A battery of reads: now, the oldest, a random point, and for a sample of live observations the
    /// exact moment plus one second either side. Then the reverts: one second past the oldest, an arbitrary
    /// distance past it, a zero window, and a window one second too long.
    function checkReads(uint256 p, uint256 r) internal {
        Model storage m = models[p];
        PoolKey memory key = keys[p];
        (uint256[] memory ts, int56[] memory cum) = liveObservations(m);
        uint256 n = ts.length;
        uint256 oldest = ts[0];
        uint256 age = clock - oldest;

        uint256 samples = n < 8 ? n : 8;
        uint32[] memory agos = new uint32[](3 * samples + 3);
        uint256 w;
        agos[w++] = 0;
        agos[w++] = uint32(age);
        agos[w++] = uint32(age == 0 ? 0 : r % (age + 1));
        for (uint256 s = 0; s < samples; s++) {
            uint256 i = s == 0 ? 0 : (s == samples - 1 ? n - 1 : uint256(keccak256(abi.encode(r, s))) % n);
            uint256 back = clock - ts[i];
            agos[w++] = uint32(back);
            agos[w++] = uint32(back + 1 > age ? age : back + 1);
            agos[w++] = uint32(back == 0 ? 0 : back - 1);
        }
        int56[] memory got = hook.observe(key, agos);
        for (uint256 i = 0; i < agos.length; i++) {
            (bool ok, int56 want) = modelObserve(m, ts, cum, agos[i]);
            assertTrue(ok, "the model expected a revert for an in-range read");
            assertEq(got[i], want, "observe disagrees with the model");
        }

        expectPredates(key, uint32(age + 1), uint32(oldest));
        expectPredates(key, uint32(bound(r >> 32, age + 1, type(uint32).max)), uint32(oldest));

        if (age > 0) {
            uint32 window = uint32(1 + ((r >> 64) % age));
            (bool ok, int24 want) = modelConsult(m, ts, cum, window);
            assertTrue(ok);
            assertEq(hook.consult(key, window), want, "consult disagrees with the model");
            (ok, want) = modelConsult(m, ts, cum, uint32(age));
            assertTrue(ok);
            assertEq(hook.consult(key, uint32(age)), want, "consult over the whole buffer");
        }
        vm.expectRevert(TickOracleHook.ZeroWindow.selector);
        hook.consult(key, 0);
        vm.expectRevert(predates(uint32(oldest), wrappedTarget(uint32(age + 1))));
        hook.consult(key, uint32(age + 1));
    }

    function expectPredates(PoolKey memory key, uint32 secondsAgo, uint32 oldest) internal {
        uint32[] memory one = new uint32[](1);
        one[0] = secondsAgo;
        vm.expectRevert(predates(oldest, wrappedTarget(secondsAgo)));
        hook.observe(key, one);
    }

    /// @dev The target timestamp as the hook computes it: the truncated clock minus `secondsAgo`, wrapping.
    function wrappedTarget(uint32 secondsAgo) internal view returns (uint32 target) {
        unchecked {
            target = uint32(clock) - secondsAgo;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The model
    // ---------------------------------------------------------------------------------------------

    function modelInitialize(Model storage m, uint256 timestamp, int24 tick) internal {
        m.ring[0] = Slot({timestamp: timestamp, tickCumulative: 0, initialized: true});
        m.index = 0;
        m.cardinality = 1;
        m.cardinalityNext = 1;
        m.lastTick = tick;
    }

    /// @dev A new block writes one observation carrying the tick that stood since the newest one; the same
    /// block writes nothing. Either way the post-swap tick is what the next write will carry.
    function modelSwap(Model storage m, uint256 timestamp, int24 tickAfter) internal {
        Slot memory last = m.ring[m.index];
        if (last.timestamp != timestamp) {
            uint16 cardinality =
                (m.cardinalityNext > m.cardinality && m.index == m.cardinality - 1) ? m.cardinalityNext : m.cardinality;
            uint16 index = uint16((uint256(m.index) + 1) % cardinality);
            m.ring[index] = Slot({
                timestamp: timestamp,
                tickCumulative: accumulate(last.tickCumulative, m.lastTick, timestamp - last.timestamp),
                initialized: true
            });
            m.index = index;
            m.cardinality = cardinality;
        }
        m.lastTick = tickAfter;
    }

    function modelGrow(Model storage m, uint16 wanted) internal {
        if (wanted <= m.cardinalityNext || wanted > CAP) return;
        for (uint16 i = m.cardinalityNext; i < wanted; i++) {
            m.ring[i].timestamp = 1; // the hook marks reserved slots this way, and its getter shows it
        }
        m.cardinalityNext = wanted;
    }

    function accumulate(int56 cumulative, int24 tick, uint256 elapsed) internal pure returns (int56) {
        unchecked {
            return cumulative + int56(tick) * int56(int256(elapsed));
        }
    }

    /// @dev The written observations in chronological order: from the slot after the newest round to the
    /// newest, skipping reserved slots, which the invariant says sit at the front of that walk.
    function liveObservations(Model storage m) internal view returns (uint256[] memory ts, int56[] memory cum) {
        uint256 cardinality = m.cardinality;
        uint256[] memory t = new uint256[](cardinality);
        int56[] memory c = new int56[](cardinality);
        uint256 n;
        for (uint256 k = 1; k <= cardinality; k++) {
            Slot storage s = m.ring[(uint256(m.index) + k) % cardinality];
            if (!s.initialized) continue;
            t[n] = s.timestamp;
            c[n] = s.tickCumulative;
            n++;
        }
        ts = new uint256[](n);
        cum = new int56[](n);
        for (uint256 i = 0; i < n; i++) {
            ts[i] = t[i];
            cum[i] = c[i];
            if (i > 0) assertGt(ts[i], ts[i - 1], "model ring out of order");
        }
    }

    /// @return ok False when the read must revert with TargetPredatesOldestObservation.
    function modelObserve(Model storage m, uint256[] memory ts, int56[] memory cum, uint32 secondsAgo)
        internal
        view
        returns (bool ok, int56 value)
    {
        uint256 n = ts.length;
        if (secondsAgo == 0) return (true, accumulate(cum[n - 1], m.lastTick, clock - ts[n - 1]));
        if (secondsAgo > clock - ts[0]) return (false, 0);

        uint256 target = clock - secondsAgo;
        if (target >= ts[n - 1]) return (true, accumulate(cum[n - 1], m.lastTick, target - ts[n - 1]));

        uint256 k;
        while (ts[k + 1] <= target) {
            k++;
        }
        if (ts[k] == target) return (true, cum[k]);
        unchecked {
            // v3's rule: the interval's per-second quotient times the seconds into it. On observations the hook
            // itself wrote this is exact, since one tick stood for the whole interval and the quotient is it.
            int56 meanTick = (cum[k + 1] - cum[k]) / int56(int256(ts[k + 1] - ts[k]));
            return (true, cum[k] + meanTick * int56(int256(target - ts[k])));
        }
    }

    function modelConsult(Model storage m, uint256[] memory ts, int56[] memory cum, uint32 window)
        internal
        view
        returns (bool ok, int24 meanTick)
    {
        (bool okStart, int56 start) = modelObserve(m, ts, cum, window);
        if (!okStart) return (false, 0);
        (, int56 end) = modelObserve(m, ts, cum, 0);
        int56 delta;
        unchecked {
            delta = end - start;
        }
        return (true, int24(floorDiv(int256(delta), int256(uint256(window)))));
    }
}
