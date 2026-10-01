# SurfSurf launch: buys-only pool with daily sell votes

A Uniswap v4 launch made of two contracts:

| Contract | File | Role |
| --- | --- | --- |
| `SurfToken` | `src/SurfToken.sol` | The launch token. Fixed supply, 18 decimals, nothing else. |
| `BuyGateHook` | `src/BuyGateHook.sol` | The hook on the native-ETH / SURF pool. Lets people buy, blocks sells, runs the daily vote and the one-hour sell window. |

`src/HookFlags.sol` is a small helper library (permission bits, CREATE2 address mining) used by the deploy
script and the tests. `script/Deploy.s.sol` is a reviewable rehearsal of the deployment.

## The rules

The brief, and how each line of it is implemented:

**"can buys only."** A buy is a swap that pays ETH into the pool and takes SURF out (`zeroForOne`, since ETH
is `currency0` and SURF is `currency1`). Buys always pass, exact-input and exact-output alike. A sell is a
swap that pays SURF into the pool. `beforeSwap` refuses every sell with `SellsClosed()` unless a sell window
is open at that moment.

**"every day, people can vote if they want to open up sells for one hour (must hit majority or quorum
minimum)."** Time is divided into days of 86,400 seconds counted from the pool's initialization timestamp
(`genesis`). During day `d` anyone with SURF deposited in the hook may call `vote(true)` or `vote(false)` once,
with their whole deposit as weight. The vote decides whether day `d + 1` starts with a sell window. It passes
when both hold:

- majority: `yes > no` (a tie fails);
- quorum: `yes + no >= quorum`, where `quorum` is 5% (`QUORUM_BPS = 500`) of the circulating supply,
  snapshotted at the first vote of the day. Circulating supply is the token's total supply minus the
  PoolManager's SURF balance, so tokens sitting in the pool do not count against voters.

A day with no votes fails. The window, when it opens, is the first hour of day `d + 1`
(`[dayStart(d + 1), dayStart(d + 1) + 1 hours)`). Outside it, sells are closed again until the next passed
vote.

**"if sells open, 50% of the previous day's buys can be sold."** `afterSwap` adds the SURF amount every buy
received to `records[day].bought`. The allowance of day `d + 1`'s window is `records[d].bought / 2`
(`SELL_SHARE_BPS = 5000`), shared by everyone, first come first served. Every sell during the window adds the
SURF it paid to `records[d + 1].sold`; a sell that would push `sold` above the allowance reverts with
`SellAllowanceExceeded(requested, remaining)`. Exact-input sells are refused in `beforeSwap`, before the pool
does any work; exact-output sells (the trader names the ETH they want) are checked in `afterSwap`, once the
SURF input is known. Buys made during the window count towards the next day, not the current one.

**Fees.** The hook charges nothing, overrides no LP fee and returns no deltas. The pool uses the standard
static 0.3% LP fee (`fee = 3000`, `tickSpacing = 60`), which accrues to liquidity providers exactly as on any
pool. Nothing is routed to surfsurf.eth or anyone else, because there is nothing to route.

**Who can change it.** Nobody. There is no owner, no admin function, no upgrade path, and every parameter is
a compile-time constant. Day length, window length, 50% share and 5% quorum cannot be tuned after deployment.

## Interpretations and assumptions

The brief leaves these open; this is what was built.

- **"people" means SURF holders, weighted by deposit.** Balance-weighted voting without a lock lets the same
  tokens vote from many addresses; one-address-one-vote is free to Sybil. So voters deposit SURF into the
  hook (`deposit(amount)`, after an ERC-20 approval), vote with the full deposit, and the deposit is locked
  until the day they voted on ends. `withdraw(amount)` is allowed any time the caller has not voted today.
  Deposits are never counted as buys or sells.
- **"majority or quorum minimum" is read as majority *and* quorum.** A majority of a handful of tokens
  should not open sells for everyone, and a large turnout that votes no should not either.
- **Quorum is 5% of circulating supply**, snapshotted when the day's first vote is cast. The brief gives no
  number. A fixed share of total supply would be unreachable while almost all of the supply sits in the pool.
  Because the snapshot is taken at the first vote and circulating supply only grows during a day (buys move
  tokens out of the manager; sells only happen in the first hour), the first voter of the day fixes the
  lowest quorum that day could have had after the window closed. This is a bounded and visible effect
  (`QuorumSnapshot` event), not a hidden one.
- **The 50% cap is aggregate, not per address.** A hook cannot identify the end user: the `sender` it sees is
  the router. A per-user cap would be a per-router cap. The cap is therefore a global budget for the window.
- **Day boundaries run from `genesis`**, the block timestamp of pool initialization, not from UTC midnight.
  `dayStart(day)` and `currentDay()` expose them.
- **One vote per address per day, with the deposit at the time of the call.** Depositing more after voting
  does not add weight until the next day. Votes cannot be changed once cast.
- **The hook binds to exactly one pool.** `beforeInitialize` refuses a second pool (`AlreadyBound`), refuses
  any fee other than 3000 (`WrongFee`), any tick spacing other than 60 (`WrongTickSpacing`) and any pool whose
  `currency0` is not native ETH (`QuoteMustBeNativeEth`). A pool paired with WETH or a stablecoin cannot use
  this hook; IMD launch markets pair the token with native ETH.

## What the hook cannot do

- **It governs only its own pool.** SURF is a standard ERC-20. Anyone can open a hookless pool for it on any
  venue and sell there. The buys-only rule is a property of the launch pool, not of the token.
- **Liquidity providers are not swappers.** Adding and removing liquidity is not restricted: removing a
  position returns SURF and ETH without a swap. The launch factory is the liquidity provider.
- **The window is first come, first served.** The whole allowance can be consumed by the first sellers in
  the hour, including bots watching `dayStart`. Nothing in the brief asks for fair ordering.
- **Timestamps are the clock.** Validators can nudge `block.timestamp` by seconds, so the window edges are
  fuzzy by that much. No value is derived from timestamps beyond gating.

## What the brief asked that the token does not do

Nothing in the token restricts selling, charges a fee or gives anyone a special balance. The launch
requires a plain fixed-supply ERC-20 and refuses anything else, so every rule lives in the hook and binds the
hook's pool only (see above).

## Interface

### `SurfToken`

OpenZeppelin `ERC20` ("SurfSurf", "SURF"), 18 decimals. The constructor takes no arguments and mints
`1_000_000_000e18` (`10^27` minor units) to `msg.sender`. No other functions beyond ERC-20.

### `BuyGateHook`

Constructor: `constructor(IPoolManager poolManager)`. The manager is never hardcoded; the manifest passes it
as `"$poolManager"`. The constructor reverts if the deployed address does not carry exactly the permission bits
below, so a mis-mined deployment fails instead of yielding a pool that cannot swap.

Permissions (`getHookPermissions`): `beforeInitialize`, `beforeSwap`, `afterSwap`. Address flags:
`0x20C0` (decimal 8384). All `*ReturnDelta` flags are off.

Constants:

| Name | Value |
| --- | --- |
| `DAY` | 86,400 s |
| `SELL_WINDOW` | 3,600 s |
| `SELL_SHARE_BPS` | 5,000 (50%) |
| `QUORUM_BPS` | 500 (5%) |
| `POOL_FEE` | 3,000 |
| `POOL_TICK_SPACING` | 60 |

State and views:

- `poolManager()`, `poolId()`, `token()`, `genesis()`
- `records(day)` → `(yes, no, quorum, hasVotes, bought, sold)`
- `stakeOf(voter)`, `lockedUntil(voter)`, `hasVoted(voter, day)`
- `currentDay()`, `dayStart(day)`, `circulatingSupply()`
- `votePassed(day)` – whether day `day`'s vote opens day `day + 1`
- `sellAllowance(day)` – `records[day - 1].bought * 50%`
- `sellWindowOpen()` – true during an open window
- `sellRemaining()` – allowance left in the current window, 0 when closed

Governance:

- `deposit(uint256 amount)` – pulls SURF (needs approval); emits `Deposited`
- `withdraw(uint256 amount)` – returns SURF; reverts `StakeLocked(until)` if the caller voted today
- `vote(bool support)` – one per day; emits `VoteCast` and, on the day's first vote, `QuorumSnapshot`

Callbacks (PoolManager only, otherwise `NotPoolManager()`): `beforeInitialize`, `beforeSwap`, `afterSwap`.
The other eight `IHooks` functions revert `HookNotImplemented()`; the address carries no bit for them so the
manager never calls them.

Events: `PoolBound`, `Deposited`, `Withdrawn`, `VoteCast`, `QuorumSnapshot`, `Bought(day, amount)`,
`Sold(day, amount, remaining)`.

Errors: `NotPoolManager`, `HookNotImplemented`, `AlreadyBound`, `NotBound`, `WrongFee`, `WrongTickSpacing`,
`QuoteMustBeNativeEth`, `SellsClosed`, `SellAllowanceExceeded`, `ZeroAmount`, `NoStake`, `InsufficientStake`,
`AlreadyVoted`, `StakeLocked`, `TransferFailed`.

Note that the PoolManager wraps a hook revert: a trader sees
`WrappedError(hook, callbackSelector, reason, HookCallFailed())` with the hook's error in `reason`.

## Hook configuration record

The configuration in the OpenZeppelin Wizard's shape, for the record. The hook was written by hand on the
v4-core interfaces (no `BaseHook`, no OpenZeppelin `uniswap-hooks`), with no access control because nobody
administers it.

```json
{
  "hook": "BaseHook",
  "name": "BuyGateHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Token | `SurfToken`, no constructor arguments, supply `10^27` minted to the deployer (the factory) |
| Hook | `BuyGateHook`, constructor `["$poolManager"]`, CREATE2 salt mined for flags `0x20C0` |
| Pool | `currency0` = native ETH (`address(0)`), `currency1` = SURF, `fee` 3000, `tickSpacing` 60, `hooks` = the hook |
| Launch target | Sepolia (11155111) unless the launch says otherwise; the script also accepts 31337 |
| Hook fee / recipient | none / surfsurf.eth receives nothing because nothing is charged |
| Admin | none |

The hook must be deployed with CREATE2 at an address whose low 14 bits equal `0x20C0`. `Deploy.mineHookSalt`
finds the salt for a given deployer and manager; the constructor double-checks the result.

The pool's token side can be seeded alone (a range below the current price, e.g. `[MIN_TICK, -60]` at a
1:1 start). Buys work on such a pool with no ETH in the manager; `test_buyWorksOnATokensOnlyPool` covers it.

### Rehearsal script

`script/Deploy.s.sol:Deploy` reads two environment variables in `run()` and nothing else:

- `EXPECTED_CHAIN_ID`: `0` runs a local rehearsal (deploys its own PoolManager), `31337` for anvil,
  `11155111` for Sepolia. Any other value reverts, as does a mismatch with the connected chain.
- `POOL_MANAGER`: the chain's PoolManager. Required for Sepolia; optional for `0`/`31337`.

```sh
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

Operator-only, with a real manager and a signer supplied by the network's deployer (never in this repo):

```sh
EXPECTED_CHAIN_ID=11155111 POOL_MANAGER=0x... forge script script/Deploy.s.sol:Deploy \
  --rpc-url <sepolia> --broadcast
```

On the network the launch factory deploys the token and the hook and initializes the pool in one
transaction; the script exists so reviewers can reproduce the same code path offline.

## Building and testing offline

Every dependency is vendored as ordinary files under `lib/` (v4-core sources and its two test utilities,
forge-std, solmate, the five OpenZeppelin ERC-20 files). No submodules, no network.

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`foundry.toml` pins `solc = "0.8.26"` (v4-core's PoolManager requires it), `evm_version = "cancun"` (the
PoolManager uses transient storage), optimizer on at 200 runs, `ffi = false`, `fs_permissions = []`.

Tests (`test/`):

- `SurfToken.t.sol` – supply, decimals, transfer, no admin entry points, fuzzed conservation.
- `BuyGateHook.t.sol` – real PoolManager and v4 test routers: flags and permissions, caller checks,
  initialization guards, buys (exact in/out, tokens-only pool), closed sells, deposit/withdraw/lock,
  vote mechanics, quorum snapshot, majority/quorum outcomes, the one-hour window, the 50% cap for exact-in
  and exact-out sells, carry-over, repeated days, and fuzz over amounts, timing and vote weights.
- `Deploy.t.sol` – the script's `deploy` places the hook on a flagged address and mints the supply to the
  deployer.

## Operational responsibilities

- **Voters** must approve and `deposit` SURF before voting, and remember that a deposit that voted is locked
  until the day ends. Front-ends should show `currentDay()`, `dayStart(currentDay() + 1)`, today's tally,
  `votePassed(currentDay() - 1)`, `sellWindowOpen()` and `sellRemaining()`.
- **Traders** selling during a window should set `amountSpecified` as exact input no larger than
  `sellRemaining()`; exact-output sells may revert in `afterSwap` if the input turns out larger.
- **The deployer** supplies the chain's PoolManager and mines the salt. Nothing else is configurable, and
  nothing can be changed afterwards.
- **Nobody** holds keys to this system. There is no pause and no rescue function; SURF deposited for voting
  can only be withdrawn by its depositor.

## Independent review

See `REVIEW.md`.
