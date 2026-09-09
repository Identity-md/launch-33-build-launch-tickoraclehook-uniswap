// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title ITickOracleHook
/// @notice The oracle surface of TickOracleHook: everything a reader or an integrator calls, and everything a
/// test can assert against without depending on the implementation.
/// @dev Every function here is callable by anyone. The IHooks callbacks are deliberately not part of this
/// interface: only the PoolManager may call those, and BaseHook enforces it.
///
/// For every pool the hook has initialized, that is, every pool whose `cardinality` is nonzero, the
/// implementation keeps these invariants between calls:
///
/// - `index < cardinality <= cardinalityNext <= MAX_CARDINALITY`.
/// - `cardinality` only changes when a write lands on slot `cardinality - 1` while `cardinalityNext` is larger,
///   and then it becomes `cardinalityNext`. Slots reserved by `increaseObservationCardinalityNext` therefore
///   come into use only when the ring wraps, exactly as Uniswap v3 promotes cardinality.
/// - Walking the ring from slot `(index + 1) % cardinality` round to slot `index`, any reserved slots not yet
///   written come first, and the written observations that follow are in strictly increasing chronological
///   order modulo the uint32 wrap. No two written observations share a block timestamp: at most one
///   observation is written per pool per block.
/// - Observation 0 of a freshly initialized pool has a zero tick cumulative, and every later observation's
///   cumulative is the previous one's plus `lastTick` at the time of the write times the seconds elapsed,
///   wrapping in int56 as v3 does.
/// - `lastTick` is the pool's current tick as the PoolManager reports it: the tick after the pool's most
///   recent swap, or its initial tick before any swap. It is the tick that stood since the newest observation,
///   so it is what `observe` extrapolates with when asked for zero seconds ago.
///
/// A pool the hook never initialized has a zero `cardinality`, and reading from or growing its buffer reverts
/// with `Oracle.OracleCardinalityCannotBeZero`.
///
/// The hook's own event and error are declared on TickOracleHook rather than here, so that they can be named
/// through the contract type: `IncreaseObservationCardinalityNext(PoolId indexed id, uint16 cardinalityNextOld,
/// uint16 cardinalityNextNew)`, emitted only when a call actually grows a reservation, and `ZeroWindow()`,
/// thrown by `consult` for a zero window. The remaining reverts come from the Oracle library:
/// `OracleCardinalityCannotBeZero()`, `CardinalityTooLarge(uint16 requested, uint16 max)` and
/// `TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp)`.
interface ITickOracleHook {
    /// @notice The largest observation buffer any pool may have: the hard cap on `cardinalityNext`.
    function MAX_CARDINALITY() external view returns (uint16);

    /// @notice Reserves room for `cardinalityNext` observations in `key`'s buffer.
    /// @dev A no-op that returns the current reservation twice if the buffer already reserves at least that
    /// many. Reverts with `Oracle.OracleCardinalityCannotBeZero` if the pool was never initialized with this
    /// hook, and with `Oracle.CardinalityTooLarge` if `cardinalityNext` exceeds `MAX_CARDINALITY`.
    /// @param key The pool whose buffer to grow.
    /// @param cardinalityNext The number of slots wanted.
    /// @return cardinalityNextOld The number of slots reserved before the call.
    /// @return cardinalityNextNew The number of slots reserved after the call.
    function increaseObservationCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    /// @notice The tick cumulative of `key`'s pool as of each of `secondsAgos` seconds ago.
    /// @dev Zero means now, extrapolated from the newest observation with the pool's current tick. Any other
    /// value is read exactly when it lands on an observation and interpolated linearly between the two
    /// surrounding observations, found by binary search over the ring, when it does not. Reverts with
    /// `Oracle.TargetPredatesOldestObservation` if a requested time is older than the oldest observation still
    /// in the buffer, and with `Oracle.OracleCardinalityCannotBeZero` if the pool has no observations.
    /// @param key The pool to read.
    /// @param secondsAgos How far back to look for each result.
    /// @return tickCumulatives One entry per element of `secondsAgos`, in the same order.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives);

    /// @notice The arithmetic mean tick of `key`'s pool over the last `window` seconds.
    /// @dev Reverts with `ZeroWindow` if `window` is zero, and otherwise as `observe` does for `window`
    /// seconds ago. The mean rounds toward negative infinity, as Uniswap v3-periphery's OracleLibrary does.
    /// @param key The pool to read.
    /// @param window The length of the window, in seconds, ending now.
    /// @return arithmeticMeanTick The mean tick over the window.
    function consult(PoolKey calldata key, uint32 window) external view returns (int24 arithmeticMeanTick);

    /// @notice Buffer bookkeeping and latest tick of the pool `id`.
    /// @return index The slot of the newest observation.
    /// @return cardinality The number of live slots the buffer currently cycles through.
    /// @return cardinalityNext The number of slots the buffer will cycle through once its current cycle wraps.
    /// @return lastTick The pool's current tick.
    function states(PoolId id)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext, int24 lastTick);

    /// @notice Observation `slot` of the pool `id`. Slots at or above the pool's cardinality are not live.
    /// @return blockTimestamp The block timestamp of the observation, truncated to uint32.
    /// @return tickCumulative The tick cumulative at that instant.
    /// @return initialized Whether the slot has been written; reserved slots have not.
    function observations(PoolId id, uint256 slot)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, bool initialized);
}
