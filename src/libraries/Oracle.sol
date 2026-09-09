// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @dev The largest number of observations a single buffer may hold. File-level so it can size the
/// storage array in contracts that use the library.
uint16 constant MAX_CARDINALITY = 1024;

/// @title Oracle
/// @notice A ring buffer of time-weighted tick observations, ported from Uniswap v3's Oracle library.
/// @dev Each observation records a block timestamp and the tick cumulative at that instant. The buffer
/// starts with one live slot, grows on demand up to MAX_CARDINALITY, and overwrites its oldest slot once it
/// has cycled through every live one. v3's seconds-per-liquidity accumulator is dropped; everything else,
/// including the wrapping uint32 timestamps and the wrapping int56 accumulator, follows v3, which was written
/// for Solidity 0.7 and relied on unchecked arithmetic. Every place that relies on wrapping is `unchecked`.
library Oracle {
    /// @notice Thrown when reading from, or growing, a buffer that has never been initialized.
    error OracleCardinalityCannotBeZero();

    /// @notice Thrown when the buffer is asked to grow past MAX_CARDINALITY.
    error CardinalityTooLarge(uint16 requested, uint16 max);

    /// @notice Thrown when a requested time is older than the oldest observation still in the buffer.
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    struct Observation {
        /// @dev Block timestamp of the observation, truncated to uint32; it wraps in 2106.
        uint32 blockTimestamp;
        /// @dev Sum of tick * seconds since the buffer was initialized, wrapping.
        int56 tickCumulative;
        /// @dev Whether the slot has been written. Slots reserved by `grow` are not yet.
        bool initialized;
    }

    /// @notice Projects `last` forward to `blockTimestamp`, accumulating `tick` over the elapsed seconds.
    /// @dev `tick` must be the tick that stood for the whole interval since `last`.
    function transform(Observation memory last, uint32 blockTimestamp, int24 tick)
        internal
        pure
        returns (Observation memory)
    {
        unchecked {
            uint32 delta = blockTimestamp - last.blockTimestamp;
            return Observation({
                blockTimestamp: blockTimestamp,
                tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(delta)),
                initialized: true
            });
        }
    }

    /// @notice Writes the first observation, at `time` with a zero cumulative.
    /// @return cardinality The number of live slots, one.
    /// @return cardinalityNext The number of slots reserved, one.
    function initialize(Observation[MAX_CARDINALITY] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({blockTimestamp: time, tickCumulative: 0, initialized: true});
        return (1, 1);
    }

    /// @notice Writes a new observation if `blockTimestamp` differs from the latest one; a no-op otherwise.
    /// @dev The buffer only starts using slots reserved by `grow` when its current cycle wraps, so the
    /// cardinality bumps at most once per cycle and never leaves a gap of uninitialized slots behind.
    /// @param index The slot of the latest observation.
    /// @param blockTimestamp The current block timestamp, truncated to uint32.
    /// @param tick The tick that has stood since the latest observation.
    /// @param cardinality The number of live slots.
    /// @param cardinalityNext The number of reserved slots.
    /// @return indexUpdated The slot of the latest observation after the call.
    /// @return cardinalityUpdated The number of live slots after the call.
    function write(
        Observation[MAX_CARDINALITY] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];

        // At most one observation per block.
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }

        indexUpdated = (index + 1) % cardinalityUpdated;
        self[indexUpdated] = transform(last, blockTimestamp, tick);
    }

    /// @notice Reserves slots so the buffer can hold `next` observations. A no-op if `next <= current`.
    /// @dev Each reserved slot gets a nonzero timestamp now so the write that later fills it pays for a
    /// dirty slot rather than a fresh one. `initialized` stays false, so reads skip them.
    /// @param current The number of slots currently reserved.
    /// @param next The number of slots wanted.
    /// @return The number of slots reserved after the call.
    function grow(Observation[MAX_CARDINALITY] storage self, uint16 current, uint16 next) internal returns (uint16) {
        if (current == 0) revert OracleCardinalityCannotBeZero();
        if (next > MAX_CARDINALITY) revert CardinalityTooLarge(next, MAX_CARDINALITY);
        if (next <= current) return current;
        for (uint16 i = current; i < next; i++) {
            self[i].blockTimestamp = 1;
        }
        return next;
    }

    /// @notice Whether `a` is chronologically at or before `b`, where both are at or before `time`.
    /// @dev Timestamps are uint32 and wrap, so a numerically larger value can be earlier. Anything above
    /// `time` must be from before the wrap, and is shifted down by a full cycle for the comparison.
    function lte(uint32 time, uint32 a, uint32 b) internal pure returns (bool) {
        if (a <= time && b <= time) return a <= b;

        uint256 aAdjusted = a > time ? a : a + 2 ** 32;
        uint256 bAdjusted = b > time ? b : b + 2 ** 32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice Finds the observations at or before and at or after `target` by binary search over the ring.
    /// @dev Only called once the caller has established that `target` lies strictly between the oldest and
    /// the newest observation, so the search always terminates by finding a bracketing pair.
    function binarySearch(
        Observation[MAX_CARDINALITY] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        unchecked {
            uint256 l = (index + 1) % cardinality; // oldest observation
            uint256 r = l + cardinality - 1; // newest observation
            uint256 i;
            while (true) {
                i = (l + r) / 2;

                beforeOrAt = self[i % cardinality];

                // Landed on a reserved but unwritten slot: search more recently.
                if (!beforeOrAt.initialized) {
                    l = i + 1;
                    continue;
                }

                atOrAfter = self[(i + 1) % cardinality];

                bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

                if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

                if (!targetAtOrAfter) r = i - 1;
                else l = i + 1;
            }
        }
    }

    /// @notice Finds the observations that bracket `target`, extrapolating from the newest one when the
    /// target is at or after it.
    /// @dev Reverts if `target` is older than the oldest observation still in the buffer.
    function getSurroundingObservations(
        Observation[MAX_CARDINALITY] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // Optimistically take the newest observation.
        beforeOrAt = self[index];

        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // Same block as the newest observation: it is the answer on its own.
                return (beforeOrAt, atOrAfter);
            } else {
                // After the newest observation: extrapolate with the tick that has stood since.
                return (beforeOrAt, transform(beforeOrAt, target, tick));
            }
        }

        // Now the oldest observation.
        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        if (!lte(time, beforeOrAt.blockTimestamp, target)) {
            revert TargetPredatesOldestObservation(beforeOrAt.blockTimestamp, target);
        }

        return binarySearch(self, time, target, index, cardinality);
    }

    /// @notice The tick cumulative as of `secondsAgo` seconds before `time`.
    /// @dev Zero seconds ago extrapolates from the newest observation with the current tick. Otherwise the
    /// value is read exactly when the target lands on an observation and interpolated linearly between the
    /// two surrounding observations when it does not.
    function observeSingle(
        Observation[MAX_CARDINALITY] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative) {
        if (secondsAgo == 0) {
            Observation memory last = self[index];
            if (last.blockTimestamp != time) last = transform(last, time, tick);
            return last.tickCumulative;
        }

        uint32 target;
        unchecked {
            target = time - secondsAgo;
        }

        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, time, target, tick, index, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            // Left boundary.
            return beforeOrAt.tickCumulative;
        } else if (target == atOrAfter.blockTimestamp) {
            // Right boundary.
            return atOrAfter.tickCumulative;
        } else {
            // Strictly between: interpolate.
            unchecked {
                uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
                uint32 targetDelta = target - beforeOrAt.blockTimestamp;
                int56 cumulativeDelta = atOrAfter.tickCumulative - beforeOrAt.tickCumulative;
                // Dividing first is v3's choice, kept deliberately: the quotient is the interval's mean
                // tick, and multiplying the whole cumulative delta by targetDelta first could overflow int56.
                // forge-lint: disable-next-line(divide-before-multiply)
                int56 meanTick = cumulativeDelta / int56(uint56(observationTimeDelta));
                return beforeOrAt.tickCumulative + meanTick * int56(uint56(targetDelta));
            }
        }
    }

    /// @notice The tick cumulatives as of each of `secondsAgos` seconds before `time`.
    /// @param time The current block timestamp, truncated to uint32.
    /// @param secondsAgos How far back to look for each result; zero means now.
    /// @param tick The tick that has stood since the newest observation.
    /// @param index The slot of the newest observation.
    /// @param cardinality The number of live slots.
    function observe(
        Observation[MAX_CARDINALITY] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives) {
        if (cardinality == 0) revert OracleCardinalityCannotBeZero();

        tickCumulatives = new int56[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = observeSingle(self, time, secondsAgos[i], tick, index, cardinality);
        }
    }
}
