// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Oracle, MAX_CARDINALITY} from "../src/libraries/Oracle.sol";

/// @notice Exposes the Oracle library on one storage buffer so each rule can be checked in isolation,
/// with hand-picked timestamps and ticks.
contract OracleHarness {
    using Oracle for Oracle.Observation[MAX_CARDINALITY];

    Oracle.Observation[MAX_CARDINALITY] public observations;
    uint16 public index;
    uint16 public cardinality;
    uint16 public cardinalityNext;

    function initialize(uint32 time) external {
        (cardinality, cardinalityNext) = observations.initialize(time);
        index = 0;
    }

    function write(uint32 blockTimestamp, int24 tick) external {
        (index, cardinality) = observations.write(index, blockTimestamp, tick, cardinality, cardinalityNext);
    }

    function grow(uint16 next) external returns (uint16) {
        cardinalityNext = observations.grow(cardinalityNext, next);
        return cardinalityNext;
    }

    function observe(uint32 time, uint32[] calldata secondsAgos, int24 tick) external view returns (int56[] memory) {
        return observations.observe(time, secondsAgos, tick, index, cardinality);
    }

    function observeSingle(uint32 time, uint32 secondsAgo, int24 tick) external view returns (int56) {
        return observations.observeSingle(time, secondsAgo, tick, index, cardinality);
    }

    function lte(uint32 time, uint32 a, uint32 b) external pure returns (bool) {
        return Oracle.lte(time, a, b);
    }

    function transform(Oracle.Observation memory last, uint32 blockTimestamp, int24 tick)
        external
        pure
        returns (Oracle.Observation memory)
    {
        return Oracle.transform(last, blockTimestamp, tick);
    }

    /// @dev Direct ring setup for search tests.
    function set(uint16 slot, uint32 blockTimestamp, int56 tickCumulative, bool initialized) external {
        observations[slot] = Oracle.Observation({
            blockTimestamp: blockTimestamp, tickCumulative: tickCumulative, initialized: initialized
        });
    }

    function setState(uint16 index_, uint16 cardinality_, uint16 cardinalityNext_) external {
        index = index_;
        cardinality = cardinality_;
        cardinalityNext = cardinalityNext_;
    }
}

contract OracleTest is Test {
    uint32 constant WRAP = type(uint32).max; // 2**32 - 1

    OracleHarness oracle;

    function setUp() public {
        oracle = new OracleHarness();
    }

    // ---------------------------------------------------------------------------------------------
    // initialize / transform
    // ---------------------------------------------------------------------------------------------

    function test_initialize_writesSlotZeroWithOneLiveSlot() public {
        oracle.initialize(5);
        assertEq(oracle.index(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityNext(), 1);
        assertObservation(0, 5, 0, true);
        assertObservation(1, 0, 0, false);
    }

    function test_transform_accumulatesTickOverElapsedSeconds() public view {
        Oracle.Observation memory last =
            Oracle.Observation({blockTimestamp: 100, tickCumulative: 1000, initialized: true});
        Oracle.Observation memory next = oracle.transform(last, 107, -3);
        assertEq(next.blockTimestamp, 107);
        assertEq(next.tickCumulative, 1000 - 3 * 7);
        assertTrue(next.initialized);
    }

    function test_transform_elapsedSecondsWrapWithTheTimestamp() public view {
        Oracle.Observation memory last =
            Oracle.Observation({blockTimestamp: WRAP - 4, tickCumulative: 50, initialized: true});
        // Five seconds later the uint32 clock reads 0; nine seconds later it reads 4.
        assertEq(oracle.transform(last, 0, 10).tickCumulative, 50 + 10 * 5);
        assertEq(oracle.transform(last, 4, 10).tickCumulative, 50 + 10 * 9);
    }

    // ---------------------------------------------------------------------------------------------
    // write
    // ---------------------------------------------------------------------------------------------

    function test_write_sameTimestampIsANoop() public {
        oracle.initialize(5);
        oracle.write(5, 100);
        assertEq(oracle.index(), 0);
        assertObservation(0, 5, 0, true);
    }

    function test_write_appliesTheTickThatStoodSinceTheLastObservation() public {
        oracle.initialize(5);
        oracle.write(10, 7); // 7 for 5 seconds
        assertObservation(0, 10, 35, true);
        oracle.write(13, -4); // -4 for 3 seconds
        assertObservation(0, 13, 23, true);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.index(), 0);
    }

    function test_write_promotesTheReservationOnlyWhenTheRingIsAtItsLastSlot() public {
        oracle.initialize(0);
        oracle.grow(3);

        oracle.write(1, 1); // index 0 == cardinality-1: cardinality 1 -> 3, index -> 1
        assertEq(oracle.cardinality(), 3);
        assertEq(oracle.index(), 1);

        oracle.grow(5); // reserved mid-cycle
        oracle.write(2, 1); // index 1 != 2: cardinality stays 3
        assertEq(oracle.cardinality(), 3);
        assertEq(oracle.index(), 2);

        oracle.write(3, 1); // index 2 == cardinality-1: cardinality 3 -> 5, index -> 3
        assertEq(oracle.cardinality(), 5);
        assertEq(oracle.index(), 3);

        oracle.write(4, 1);
        assertEq(oracle.index(), 4);
        oracle.write(5, 1); // index 4 == cardinality-1 and nothing reserved: wrap
        assertEq(oracle.cardinality(), 5);
        assertEq(oracle.index(), 0);
        assertObservation(0, 5, 5, true);
    }

    function test_write_wrapsTheIndexAndOverwritesTheOldest() public {
        oracle.initialize(0);
        oracle.grow(3);
        oracle.write(10, 2);
        oracle.write(20, 3);
        oracle.write(30, 4);
        assertEq(oracle.index(), 0);
        assertObservation(0, 30, 2 * 10 + 3 * 10 + 4 * 10, true);
        assertObservation(1, 10, 20, true);
        assertObservation(2, 20, 50, true);
    }

    // ---------------------------------------------------------------------------------------------
    // grow
    // ---------------------------------------------------------------------------------------------

    function test_grow_revertsOnAnUninitializedBuffer() public {
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        oracle.grow(2);
    }

    function test_grow_revertsPastTheCap() public {
        oracle.initialize(0);
        vm.expectRevert(abi.encodeWithSelector(Oracle.CardinalityTooLarge.selector, uint16(1025), uint16(1024)));
        oracle.grow(1025);
        assertEq(oracle.grow(1024), 1024);
    }

    function test_grow_isANoopWhenNotLarger() public {
        oracle.initialize(0);
        assertEq(oracle.grow(4), 4);
        assertEq(oracle.grow(4), 4);
        assertEq(oracle.grow(2), 4);
        assertEq(oracle.cardinalityNext(), 4);
    }

    function test_grow_marksReservedSlotsWithoutInitializingThem() public {
        oracle.initialize(0);
        oracle.grow(4);
        for (uint16 i = 1; i < 4; i++) {
            assertObservation(i, 1, 0, false);
        }
        assertObservation(4, 0, 0, false);
        assertEq(oracle.cardinality(), 1, "grow must not change the live count");
    }

    // ---------------------------------------------------------------------------------------------
    // lte: chronological order under uint32 wrap
    // ---------------------------------------------------------------------------------------------

    function test_lte_plainOrderWhenNothingHasWrapped() public view {
        assertTrue(oracle.lte(10, 3, 5));
        assertFalse(oracle.lte(10, 5, 3));
        assertTrue(oracle.lte(10, 5, 5));
        assertTrue(oracle.lte(10, 10, 10));
    }

    function test_lte_aValueAboveNowIsFromBeforeTheWrap() public view {
        // now = 10; WRAP - 5 happened 16 seconds ago, 3 happened 7 seconds ago.
        assertTrue(oracle.lte(10, WRAP - 5, 3));
        assertFalse(oracle.lte(10, 3, WRAP - 5));
        assertTrue(oracle.lte(10, WRAP - 5, 10));
        assertTrue(oracle.lte(10, WRAP - 5, 0));
    }

    function test_lte_twoValuesFromBeforeTheWrapKeepTheirOrder() public view {
        assertTrue(oracle.lte(10, WRAP - 5, WRAP - 3));
        assertFalse(oracle.lte(10, WRAP - 3, WRAP - 5));
        assertTrue(oracle.lte(10, WRAP - 3, WRAP - 3));
    }

    function testFuzz_lte_agreesWithUnwrappedTime(uint32 time, uint32 agoA, uint32 agoB) public view {
        // Two moments at most a full cycle back from `time`, compared on an unwrapped clock.
        uint256 now256 = uint256(time) + 2 ** 32;
        uint256 a256 = now256 - agoA;
        uint256 b256 = now256 - agoB;
        assertEq(oracle.lte(time, uint32(a256), uint32(b256)), a256 <= b256);
    }

    // ---------------------------------------------------------------------------------------------
    // observe
    // ---------------------------------------------------------------------------------------------

    function test_observe_revertsOnAnUninitializedBuffer() public {
        uint32[] memory secondsAgos = new uint32[](1);
        vm.expectRevert(Oracle.OracleCardinalityCannotBeZero.selector);
        oracle.observe(0, secondsAgos, 0);
    }

    function test_observe_zeroSecondsAgo_sameBlockReadsTheNewestObservation() public {
        oracle.initialize(5);
        oracle.write(10, 7);
        assertEq(oracle.observeSingle(10, 0, 999), 35);
    }

    function test_observe_zeroSecondsAgo_laterBlockExtrapolatesWithTheCurrentTick() public {
        oracle.initialize(5);
        oracle.write(10, 7);
        assertEq(oracle.observeSingle(16, 0, -2), 35 - 2 * 6);
    }

    function test_observe_targetAfterTheNewestObservationExtrapolates() public {
        oracle.initialize(5);
        oracle.write(10, 7);
        // now = 20, 4 seconds ago = 16: newest is at 10, so 6 seconds of the current tick.
        assertEq(oracle.observeSingle(20, 4, -2), 35 - 2 * 6);
    }

    function test_observe_exactBoundaries() public {
        oracle.initialize(0);
        oracle.grow(3);
        oracle.write(10, 5); // 50
        oracle.write(25, -2); // 50 - 30 = 20

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 25;
        secondsAgos[1] = 15;
        secondsAgos[2] = 0;
        int56[] memory result = oracle.observe(25, secondsAgos, 0);
        assertEq(result[0], 0);
        assertEq(result[1], 50);
        assertEq(result[2], 20);
    }

    function test_observe_interpolatesWithAPerSecondQuotientTruncatedTowardZero() public {
        // Cumulatives here are set directly so the interval's mean tick is not a whole number.
        oracle.initialize(0);
        oracle.grow(2);
        oracle.set(1, 10, 33, true); // 3.3 per second
        oracle.setState(1, 2, 2);

        assertEq(oracle.observeSingle(10, 6, 0), int56(3 * 4)); // 12, not 13
        assertEq(oracle.observeSingle(10, 1, 0), int56(3 * 9)); // 27, not 29

        oracle.set(1, 10, -33, true);
        assertEq(oracle.observeSingle(10, 6, 0), int56(-3 * 4)); // -12, not -13
    }

    function test_observe_revertsBeforeTheOldestObservation() public {
        oracle.initialize(100);
        oracle.grow(2);
        oracle.write(110, 1);

        assertEq(oracle.observeSingle(120, 20, 0), 0);
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, uint32(100), uint32(99))
        );
        oracle.observeSingle(120, 21, 0);
    }

    function test_observe_revertsBeforeTheOldestWhenTheOldestHasBeenOverwritten() public {
        oracle.initialize(100);
        oracle.write(110, 1); // cardinality 1: overwrites slot 0
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, uint32(110), uint32(105))
        );
        oracle.observeSingle(120, 15, 0);
    }

    function test_observe_skipsReservedSlotsDuringSearch() public {
        // Ring of 8 with only 3 written: the search must treat reserved slots as "look more recently".
        oracle.initialize(0);
        oracle.grow(8);
        oracle.write(10, 1);
        oracle.write(20, 2);
        assertEq(oracle.cardinality(), 8);
        assertEq(oracle.index(), 2);

        assertEq(oracle.observeSingle(20, 15, 0), 5); // between 0 and 10
        assertEq(oracle.observeSingle(20, 5, 0), 10 + 2 * 5); // between 10 and 20
    }

    function test_observe_searchesAcrossTheRingBoundary() public {
        oracle.initialize(0);
        oracle.grow(4);
        oracle.write(10, 1); // slot 1: 10
        oracle.write(20, 2); // slot 2: 30
        oracle.write(30, 3); // slot 3: 60
        oracle.write(40, 4); // slot 0: 100, overwriting time 0
        oracle.write(50, 5); // slot 1: 150, overwriting time 10
        assertEq(oracle.index(), 1);

        // Oldest live is slot 2 (t=20). Ring order: 20 (slot 2), 30 (slot 3), 40 (slot 0), 50 (slot 1).
        assertEq(oracle.observeSingle(50, 30, 0), 30);
        assertEq(oracle.observeSingle(50, 25, 0), 30 + 3 * 5);
        assertEq(oracle.observeSingle(50, 15, 0), 60 + 4 * 5);
        assertEq(oracle.observeSingle(50, 5, 0), 100 + 5 * 5);
        vm.expectRevert(abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, uint32(20), uint32(19)));
        oracle.observeSingle(50, 31, 0);
    }

    function test_observe_searchesAcrossTheUint32Wrap() public {
        oracle.initialize(WRAP - 9); // 4294967286
        oracle.grow(4);
        oracle.write(WRAP - 2, 100); // 4294967293: 700
        oracle.write(4, 100); // 7 seconds later: 1400
        oracle.write(9, 100); // 1900
        uint32 time = 15;

        assertEq(oracle.observeSingle(time, 6, 100), 1900); // exactly the newest
        assertEq(oracle.observeSingle(time, 0, 100), 2500); // extrapolated 6s
        assertEq(oracle.observeSingle(time, 13, 100), 700 + 100 * 5); // target 2: across the wrap
        assertEq(oracle.observeSingle(time, 15, 100), 700 + 100 * 3); // target 0
        assertEq(oracle.observeSingle(time, 17, 100), 700 + 100 * 1); // target 4294967294: one second after
        assertEq(oracle.observeSingle(time, 20, 100), 100 * 5); // target 4294967291: before the wrap
        assertEq(oracle.observeSingle(time, 25, 100), 0); // target 4294967286: the oldest
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, uint32(WRAP - 9), uint32(WRAP - 10))
        );
        oracle.observeSingle(time, 26, 100);
    }

    /// @dev Every observation the search can return must agree with a linear scan of the same ring.
    function testFuzz_observe_matchesALinearScan(uint8 writes, uint32 secondsAgo, int24 tick) public {
        tick = int24(bound(tick, -887272, 887272));
        oracle.initialize(1000);
        oracle.grow(16);

        uint32[64] memory times;
        int56[64] memory cumulatives;
        times[0] = 1000;
        uint256 n = 1;
        uint32 t = 1000;
        for (uint256 i = 0; i < uint256(writes) % 40; i++) {
            t += uint32(1 + ((i * 7919) % 13));
            oracle.write(t, tick);
            times[n] = t;
            cumulatives[n] = cumulatives[n - 1] + int56(tick) * int56(uint56(times[n] - times[n - 1]));
            n++;
        }
        uint32 time = t + 5;
        secondsAgo = uint32(bound(secondsAgo, 0, time - 1000));
        uint32 target = time - secondsAgo;

        // Linear reference over the observations still in the ring (the last 16, or fewer).
        uint256 oldest = n > 16 ? n - 16 : 0;
        if (target < times[oldest]) {
            vm.expectRevert(
                abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, times[oldest], target)
            );
            oracle.observeSingle(time, secondsAgo, tick);
            return;
        }
        int56 expected;
        if (target >= times[n - 1]) {
            expected = cumulatives[n - 1] + int56(tick) * int56(uint56(target - times[n - 1]));
        } else {
            uint256 k = oldest;
            while (times[k + 1] < target) k++;
            if (times[k + 1] == target) {
                expected = cumulatives[k + 1];
            } else {
                int56 mean = (cumulatives[k + 1] - cumulatives[k]) / int56(uint56(times[k + 1] - times[k]));
                expected = cumulatives[k] + mean * int56(uint56(target - times[k]));
            }
        }
        assertEq(oracle.observeSingle(time, secondsAgo, tick), expected);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function assertObservation(uint256 slot, uint32 blockTimestamp, int56 tickCumulative, bool initialized)
        internal
        view
    {
        (uint32 ts, int56 c, bool init) = oracle.observations(slot);
        assertEq(ts, blockTimestamp, "observation timestamp");
        assertEq(c, tickCumulative, "observation cumulative");
        assertEq(init, initialized, "observation initialized");
    }
}
