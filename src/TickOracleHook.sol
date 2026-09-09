// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "./base/BaseHook.sol";
import {Oracle, MAX_CARDINALITY as ORACLE_MAX_CARDINALITY} from "./libraries/Oracle.sol";

/// @title TickOracleHook
/// @notice A Uniswap v4 hook that keeps an on-chain time-weighted tick oracle for every pool it is attached
/// to, with the semantics of the oracle built into Uniswap v3 pools.
/// @dev Permissions are afterInitialize and afterSwap, nothing else. The hook never takes, settles or holds
/// currency, returns a zero delta from afterSwap, and has no owner and no setter beyond growing a pool's
/// observation buffer. Anyone may grow a buffer and anyone may read.
///
/// The observation model is Uniswap v3's:
/// - afterInitialize writes observation 0 at the current block timestamp with a zero cumulative and records
///   the pool's initial tick.
/// - afterSwap writes a new observation only if the block timestamp has moved past the newest observation's.
///   The new observation accumulates the tick recorded by the previous swap, which is the tick that stood at
///   the end of the previous block, over the seconds elapsed. Then the post-swap tick is recorded for the
///   next write. So a pool gets at most one observation per block, and a swap's own price impact only starts
///   counting from the next block, which is what makes the oracle expensive to manipulate within a block.
contract TickOracleHook is BaseHook {
    using Oracle for Oracle.Observation[ORACLE_MAX_CARDINALITY];
    using StateLibrary for IPoolManager;

    /// @notice Bookkeeping for a pool's ring buffer, plus the tick that stood after its latest swap.
    /// @dev Packs into one storage slot, so afterSwap reads and writes it once.
    struct ObservationState {
        /// @dev Slot of the newest observation.
        uint16 index;
        /// @dev Number of live slots the buffer currently cycles through.
        uint16 cardinality;
        /// @dev Number of slots the buffer will cycle through once its current cycle wraps.
        uint16 cardinalityNext;
        /// @dev Tick after the pool's latest swap, or its initial tick before any swap.
        int24 lastTick;
    }

    /// @notice Emitted when a pool's buffer is asked to grow.
    event IncreaseObservationCardinalityNext(PoolId indexed id, uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    /// @notice Thrown by consult when asked for the mean over zero seconds.
    error ZeroWindow();

    /// @notice The largest observation buffer any pool may have.
    uint16 public constant MAX_CARDINALITY = ORACLE_MAX_CARDINALITY;

    /// @notice Observation buffer per pool. Only slots below the pool's cardinality are live.
    mapping(PoolId id => Oracle.Observation[ORACLE_MAX_CARDINALITY]) public observations;

    /// @notice Buffer bookkeeping and latest tick per pool.
    mapping(PoolId id => ObservationState) public states;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks (PoolManager only, enforced by BaseHook)
    // ---------------------------------------------------------------------------------------------

    /// @dev Writes the pool's first observation and records its initial tick.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = key.toId();
        (uint16 cardinality, uint16 cardinalityNext) = observations[id].initialize(_blockTimestamp());
        states[id] =
            ObservationState({index: 0, cardinality: cardinality, cardinalityNext: cardinalityNext, lastTick: tick});
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Writes an observation for this block if none exists yet, using the tick recorded by the previous
    /// swap, then records the post-swap tick. Returns a zero delta on every path.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        ObservationState memory state = states[id];

        (uint16 index, uint16 cardinality) = observations[id].write(
            state.index, _blockTimestamp(), state.lastTick, state.cardinality, state.cardinalityNext
        );

        (, int24 tick,,) = poolManager.getSlot0(id);

        states[id] = ObservationState({
            index: index, cardinality: cardinality, cardinalityNext: state.cardinalityNext, lastTick: tick
        });

        return (BaseHook.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Buffer growth (anyone)
    // ---------------------------------------------------------------------------------------------

    /// @notice Reserves room for `cardinalityNext` observations in `key`'s buffer, up to MAX_CARDINALITY.
    /// @dev A no-op if the buffer already reserves at least that many. The new slots come into use once the
    /// buffer's current cycle wraps. Reverts if the pool was never initialized with this hook, or if
    /// `cardinalityNext` exceeds MAX_CARDINALITY.
    /// @return cardinalityNextOld The number of slots reserved before the call.
    /// @return cardinalityNextNew The number of slots reserved after the call.
    function increaseObservationCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = key.toId();
        ObservationState storage state = states[id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);

        if (cardinalityNextNew != cardinalityNextOld) {
            state.cardinalityNext = cardinalityNextNew;
            emit IncreaseObservationCardinalityNext(id, cardinalityNextOld, cardinalityNextNew);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------------

    /// @notice The tick cumulative of `key`'s pool as of each of `secondsAgos` seconds ago.
    /// @dev Zero means now, extrapolated from the newest observation with the current tick. Any other value
    /// is read exactly when it lands on an observation and interpolated between the two surrounding
    /// observations otherwise. Reverts with TargetPredatesOldestObservation if it reaches further back than
    /// the buffer holds, and with OracleCardinalityCannotBeZero if the pool has no observations.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives)
    {
        return _observe(key.toId(), secondsAgos);
    }

    /// @notice The arithmetic mean tick of `key`'s pool over the last `window` seconds.
    /// @dev Reverts with ZeroWindow if `window` is zero, and otherwise as `observe` does. The mean rounds
    /// toward negative infinity, as Uniswap v3-periphery's OracleLibrary does.
    function consult(PoolKey calldata key, uint32 window) external view returns (int24 arithmeticMeanTick) {
        if (window == 0) revert ZeroWindow();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        int56[] memory tickCumulatives = _observe(key.toId(), secondsAgos);

        unchecked {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 windowSigned = int56(uint56(window));

            // The mean of ticks that all fit in int24 fits in int24 itself.
            // forge-lint: disable-next-line(unsafe-typecast)
            arithmeticMeanTick = int24(delta / windowSigned);
            if (delta < 0 && (delta % windowSigned != 0)) arithmeticMeanTick--;
        }
    }

    function _observe(PoolId id, uint32[] memory secondsAgos) internal view returns (int56[] memory) {
        ObservationState memory state = states[id];
        return observations[id].observe(_blockTimestamp(), secondsAgos, state.lastTick, state.index, state.cardinality);
    }

    function _blockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp);
    }
}
