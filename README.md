# SurfSurf launch: buys-only pool with daily sell votes

A Uniswap v4 launch made of two contracts:

| Contract | File | Role |
| --- | --- | --- |
| `SurfToken` | `src/SurfToken.sol` | The launch token. Fixed supply, 18 decimals, nothing else. |
| `BuyGateHook` | `src/BuyGateHook.sol` | The hook on the native-ETH / SURF pool. Lets people buy, blocks sells, keeps liquidity to the launch, runs the daily vote and the one-hour sell window. |

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
  PoolManager's SURF balance, so tokens sitting in the pool do not count against voters. (The manager's
  balance is everything it holds, in this pool, in any other pool on the same manager, and as ERC-6909
  claims; see "Interpretations and assumptions".)

A vote is refused with `ManagerUnlocked()` while the PoolManager is unlocked. Inside an unlock anyone can
`take` the manager's whole SURF balance for the duration of the call and settle it back before the call
ends, which would let a single wei of stake snapshot a quorum of 5% of the *total* supply and block every
honest vote that day. Votes are therefore only accepted from ordinary transactions, never from inside a
swap, a liquidity change or any other unlock callback.

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

**Liquidity is the launch's alone.** A liquidity position just below the price is a resting sell order: a
buy walks the price down through it and converts its SURF into the buyer's ETH, and the position's owner
then removes it and holds ETH. On an open pool any holder could do that on day 0 with no vote, no window
and no cap, and could also buy from their own position to inflate `bought` and with it the next day's
allowance. So `beforeAddLiquidity` accepts a position only from the launch. An add passes when any of
these holds, and is refused with `LiquidityNotFromLaunch(sender)` otherwise:

- it happens in the transaction that initialized the pool (the factory initializes and seeds in one
  transaction, through whatever router it likes; the hook marks that transaction in transient storage);
- `sender` is the account that called `initialize` (`initializer()`), acting as its own router;
- the pool has never held a position (`seeded()` is false): the first position ever is the seed.

Every accepted add sets `seeded`, which closes the third case for good. The hook cannot tell the users of a
shared router apart (the `sender` it sees is the router), so after the seed the launch can add more only
from its own address or in the initialization transaction, not through a public position manager.
Removing liquidity is not restricted: only the launch can hold a position, and it may unwind it.

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
- **"Circulating" is measured as supply outside the PoolManager**, not outside this pool. SURF that someone
  parks in a hookless pool on the same manager, or holds as an ERC-6909 claim, lowers the quorum by 5% of
  the parked amount; staking the same tokens would add their full weight instead, so parking never beats
  voting and this is not an exploit, but it is a deviation from "tokens in the pool". Conversely, every
  SURF the launch keeps outside the pool (treasury, team, unsold allocation) counts as circulating and
  raises the quorum. The launch operator should check 5% of the planned outside-the-pool supply against
  the stake that voters can realistically bring, since the hook cannot be tuned afterwards. The quorum
  is only ever snapshotted while the manager is locked, so the base cannot be moved by a flash `take`.
- **Majority and quorum are both required.** With most of the supply in the pool and holders who do not
  stake, 5% of the circulating supply may be hard to reach and the sell feature then stays closed. That is
  the conservative reading; a "majority *or* quorum" reading would let a handful of tokens open sells.
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
- **The hook binds to whichever qualifying pool is initialized first.** It cannot pin the token in its
  constructor (the manifest substitutes only `$poolManager`), so it adopts `currency1` of the first
  ETH/3000/60 pool that initializes with it. `initialize` is permissionless, so this is safe only because
  the factory deploys the hook and initializes the pool in one transaction; a hook left deployed and
  unbound could be bound to another token by anyone. The launch must keep deployment and initialization
  atomic.
- **The seed should be in the initialization transaction.** If the factory seeds in a later transaction,
  the first position to arrive is accepted whoever sends it (`seeded()` is still false), and the launch
  would have to add its own liquidity as its own router afterwards. Seeding in the initialization
  transaction leaves no such gap.

## What the hook cannot do

- **It governs only its own pool.** SURF is a standard ERC-20. Anyone can open a hookless pool for it on any
  venue and sell there. The buys-only rule is a property of the launch pool, not of the token.
- **Removing liquidity is not gated.** Only the launch can hold a position (see above), and it may remove
  it at any time, which returns SURF and ETH without a swap. That is the launch's prerogative, not a
  trading path for holders.
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

Permissions (`getHookPermissions`): `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`.
Address flags: `0x28C0` (decimal 10432). All `*ReturnDelta` flags are off.

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

- `poolManager()`, `poolId()`, `token()`, `genesis()`, `initializer()`, `seeded()`
- `records(day)` → `(yes, no, quorum, hasVotes, bought, sold)`
- `stakeOf(voter)`, `lockedUntil(voter)`, `hasVoted(voter, day)` (true for every day the voter voted on)
- `currentDay()`, `dayStart(day)`, `circulatingSupply()`
- `votePassed(day)` – whether day `day`'s vote opens day `day + 1`
- `sellAllowance(day)` – `records[day - 1].bought * 50%`
- `sellWindowOpen()` – true during an open window
- `sellRemaining()` – allowance left in the current window, 0 when closed

Governance:

- `deposit(uint256 amount)` – pulls SURF (needs approval); emits `Deposited`
- `withdraw(uint256 amount)` – returns SURF; reverts `StakeLocked(until)` if the caller voted today
- `vote(bool support)` – one per day; refused while the PoolManager is unlocked; emits `VoteCast` and, on
  the day's first vote, `QuorumSnapshot`

Callbacks (PoolManager only, otherwise `NotPoolManager()`): `beforeInitialize`, `beforeAddLiquidity`,
`beforeSwap`, `afterSwap`. The other seven `IHooks` functions revert `HookNotImplemented()`; the address
carries no bit for them so the manager never calls them.

Events: `PoolBound(poolId, token, genesis, initializer)`, `Seeded(sender)`, `Deposited`, `Withdrawn`,
`VoteCast`, `QuorumSnapshot`, `Bought(day, amount)`, `Sold(day, amount, remaining)`.

Errors: `NotPoolManager`, `HookNotImplemented`, `AlreadyBound`, `NotBound`, `WrongFee`, `WrongTickSpacing`,
`QuoteMustBeNativeEth`, `LiquidityNotFromLaunch(sender)`, `ManagerUnlocked`, `SellsClosed`,
`SellAllowanceExceeded`, `ZeroAmount`, `NoStake`, `InsufficientStake`, `AlreadyVoted`, `StakeLocked`,
`TransferFailed`.

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
  "transientStorage": true,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": true,
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
| Hook | `BuyGateHook`, constructor `["$poolManager"]`, CREATE2 salt mined for flags `0x28C0` (decimal 10432) |
| Pool | `currency0` = native ETH (`address(0)`), `currency1` = SURF, `fee` 3000, `tickSpacing` 60, `hooks` = the hook |
| Liquidity | seeded by the factory in the initialization transaction (any router), or later by the initializer acting as its own router |
| Launch target | Sepolia (11155111) unless the launch says otherwise; the script also accepts 31337 |
| Hook fee / recipient | none / surfsurf.eth receives nothing because nothing is charged |
| Admin | none |

The hook must be deployed with CREATE2 at an address whose low 14 bits equal `0x28C0`. `Deploy.mineHookSalt`
finds the salt for a given deployer and manager; the constructor double-checks the result and reverts
(`HookAddressNotValid`) on an address that does not carry exactly these bits. A hook at an address without
the `beforeAddLiquidity` bit would never be asked about positions, so the check is what keeps the
liquidity rule real. The launch manifest's permission flags must say `10432`.

The pool's token side can be seeded alone (a range below the current price, e.g. `[MIN_TICK, -60]` at a
1:1 start). Buys work on such a pool with no ETH in the manager; `test_buyWorksOnATokensOnlyPool` covers it.
Seed in the same transaction as `initialize`: that transaction may add any number of positions through
any router (`test_launchSeedsSeveralPositionsInTheInitializationTransaction`). A seed in a later
transaction is accepted only as the pool's very first position, from whoever sends it first.

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
  initialization guards, buys (exact in/out, tokens-only pool), the liquidity rule (third-party adds
  refused, the single-sided exit and the self-liquidity wash from the independent review, a mock factory
  that initializes and seeds in one transaction, first-position seed, launch removal, fuzzed ranges),
  closed sells, deposit/withdraw/lock, vote mechanics, the vote refused inside an unlock, `hasVoted` across
  days, quorum snapshot, majority/quorum outcomes, the one-hour window, the 50% cap for exact-in and
  exact-out sells, carry-over, repeated days, and fuzz over amounts, timing and vote weights.
- `Deploy.t.sol` – the script's `deploy` places the hook on a flagged address and mints the supply to the
  deployer.

## Operational responsibilities

- **Voters** must approve and `deposit` SURF before voting, and remember that a deposit that voted is locked
  until the day ends. Votes must come from ordinary transactions, not from inside a PoolManager unlock
  (a contract that swaps and votes in one callback is refused). Front-ends should show `currentDay()`,
  `dayStart(currentDay() + 1)`, today's tally, `votePassed(currentDay() - 1)`, `sellWindowOpen()` and
  `sellRemaining()`.
- **Traders** selling during a window should set `amountSpecified` as exact input no larger than
  `sellRemaining()`. The exact-input check in `beforeSwap` compares the full `amountSpecified` with the
  remaining allowance even when a tight `sqrtPriceLimitX96` would fill only part of it, so a price-limited
  sell should request no more than `sellRemaining()`; exact-output sells may revert in `afterSwap` if the
  input turns out larger.
- **The deployer** supplies the chain's PoolManager and mines the salt for flags `0x28C0`. Deployment,
  initialization and the liquidity seed belong in one transaction (see "Deployment parameters"). Nothing
  else is configurable, and nothing can be changed afterwards.
- **The launch** is the only liquidity provider. It should hold its positions through a router it controls
  (or its own address) and expect `LiquidityNotFromLaunch` if it later tries to add through a public
  position manager, since the hook cannot distinguish that router's users.
- **Nobody** holds keys to this system. There is no pause and no rescue function; SURF deposited for voting
  can only be withdrawn by its depositor.

## Independent review

See `REVIEW.md`.
