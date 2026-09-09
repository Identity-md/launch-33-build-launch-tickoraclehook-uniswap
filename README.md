# TickOracleHook

A Uniswap v4 hook that gives every pool it is attached to an on-chain time-weighted tick oracle with
the semantics of the oracle built into Uniswap v3 pools, the fixed-supply ERC-20 the launch mints
(**Tick Oracle Signal**, `TOS`), and the script that launches both on Sepolia.

The hook has no owner, no fee, and never touches currency. Its only permissions are `afterInitialize`
and `afterSwap`, and its only state-changing entry point beyond those callbacks is growing a pool's
observation buffer, which anyone may do.

## Layout

```
src/
  TickOracleHook.sol      the hook
  TickOracleToken.sol     Tick Oracle Signal (TOS), a plain OpenZeppelin ERC20
  HookFlags.sol           the fourteen permission bits: constants, flagsOf, matches
  HookMiner.sol           CREATE2 salt search for an address carrying exactly a set of flags
  base/BaseHook.sol       PoolManager-only callbacks, adapted from v4-periphery
  libraries/Oracle.sol    the observation ring buffer, ported from v3's Oracle library
script/
  Deploy.s.sol            Sepolia launch: hook, token, and the TOS/USDC pool
test/
  TickOracleHook.t.sol    the hook driven through a live PoolManager
  Oracle.t.sol            the library on its own, with hand-picked timestamps and ticks
  TickOracleToken.t.sol   the token
  HookFlags.t.sol         flag helpers and the miner
  Deploy.fork.t.sol       the launch rehearsed on a Sepolia fork (skips without SEPOLIA_RPC_URL)
  mocks/, utils/          test ERC-20 and a bytecode scan helper
lib/                      dependencies, vendored as plain files (see below)
```

## How the oracle works

Per pool the hook keeps a ring buffer of observations. Each observation is a `uint32` block
timestamp, which wraps, and an `int56` tick cumulative. The buffer has an `index` (newest slot), a
`cardinality` (live slots) and a `cardinalityNext` (reserved slots). The rules are Uniswap v3's:

- `afterInitialize` writes observation 0 at the current block timestamp with a zero cumulative and
  records the pool's initial tick.
- `afterSwap` writes a new observation only when the block timestamp has moved past the newest
  observation's. The new observation accumulates the tick recorded by the *previous* swap, which is
  the tick that stood at the end of the previous block, over the seconds elapsed. Then it records the
  post-swap tick for the next write. So a pool gets at most one observation per block, and a swap's
  own price impact only starts counting from the next block.
- `increaseObservationCardinalityNext(key, n)` reserves slots up to a hard cap of 1024. Reserved
  slots come into use once the ring's current cycle wraps, exactly as v3 promotes cardinality. The
  initial cardinality is 1.
- `observe(key, secondsAgos)` returns tick cumulatives. Zero seconds ago extrapolates from the newest
  observation with the current tick. Any other value is read exactly when it lands on an observation
  and interpolated linearly between the two surrounding observations, found by binary search over the
  ring, when it does not. Reaching further back than the buffer holds reverts with
  `TargetPredatesOldestObservation(oldestTimestamp, targetTimestamp)`.
- `consult(key, window)` returns the arithmetic mean tick over the last `window` seconds as an
  `int24`, rounded toward negative infinity. A zero window reverts with `ZeroWindow()`.

Timestamp comparisons follow v3's `Oracle.lte`, so the ring keeps working across the `uint32`
wraparound in 2106. Reads and writes on a pool the hook never initialized revert with
`OracleCardinalityCannotBeZero()`; growing past the cap reverts with `CardinalityTooLarge`.

`afterSwap` returns a zero delta on every path, so a swap settles exactly as it would with no hook
attached. Every callback refuses any caller other than the PoolManager. The constructor takes only the
PoolManager and checks that the address the hook lands on carries exactly its two flags.

## Launch facts

These are fixed by the launch policy. The deploy script and the fork test carry the same values.

| Fact | Value |
| --- | --- |
| Token | Tick Oracle Signal, `TOS`, 18 decimals |
| Total supply | `1000000000000000000000000000` (1e27, one billion tokens), minted once to the deployer |
| Paired currency | USDC on Sepolia, `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Fee tier | 3000, tick spacing 60 |
| Initial price | `sqrtPriceX96 = 79228162514264337593543950336` (1:1) |
| PoolManager | Uniswap v4 on Sepolia, `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook flags | `afterInitialize` and `afterSwap` only, `0x1040` in the address |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) with solc 0.8.26 (pinned in `foundry.toml`).

```sh
forge build
forge test
```

The tests deploy a real `PoolManager`, place the hook by CREATE2 at an address carrying exactly its
flags, open several pools, and drive swaps across warped blocks. Every expected oracle value is
computed in the test from the ticks and timestamps it observed itself.

To rehearse the launch against real Sepolia state (the live PoolManager, the real USDC), point the
fork test at an RPC:

```sh
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path test/Deploy.fork.t.sol
```

## Deploy to Sepolia

The script mines a CREATE2 salt for the hook, deploys it through the deterministic CREATE2 factory,
deploys the token (whose whole supply goes to the broadcasting account), and initializes the TOS/USDC
pool at 1:1 on the hook. It prints the addresses and the pool id.

```sh
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com

# Simulate only
forge script script/Deploy.s.sol --rpc-url sepolia

# Broadcast, with a keystore account (or --private-key), and verify on Etherscan
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --account <name> \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

A broadcast leaves its record under `broadcast/`; simulations are not committed. The hook's address
is deterministic for a given salt and creation code, and the constructor refuses to run at an
address whose flags disagree with `getHookPermissions`, so a mis-mined deployment fails instead of
producing a broken hook.

Liquidity is not part of the launch script. USDC on Sepolia is Circle's, so seeding the pool is a
separate step for whoever holds it.

## Dependencies

Everything the build needs is committed as ordinary files under `lib/`, trimmed to sources plus
licence and version record. Nothing is a git submodule and nothing is fetched at build time.

| Dependency | Version | Kept |
| --- | --- | --- |
| [forge-std](https://github.com/foundry-rs/forge-std) | v1.16.2 | `src/` |
| [v4-core](https://github.com/Uniswap/v4-core) | main at `46c6834` (package 1.0.2) | `src/`, `test/utils/` (the `src/test` routers import `CurrencySettler` from there) |
| [solmate](https://github.com/transmissions11/solmate) | `4b47a19`, the commit v4-core pins (package 6.2.0) | `src/` |
| [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | v5.7.0 | `contracts/` |

Compiler settings match v4-core's (solc 0.8.26, Cancun, via-IR, 44,444,444 optimizer runs): that is
what keeps `PoolManager` under the EIP-170 limit, and the tests deploy one. CBOR metadata is disabled
so runtime bytecode contains nothing but code.

## Licences

`src/libraries/Oracle.sol` and `src/TickOracleHook.sol` are GPL-2.0-or-later, as ports of Uniswap
v3's oracle. Everything else in `src/`, `script/` and `test/` is MIT. Vendored dependencies keep their
own licences under `lib/`.
