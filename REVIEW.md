# Review notes: SurfToken and BuyGateHook

A self-review against the task's security references (the v4 hook security checklist and the ethskills
safety checklist) before hand-off, updated after the independent review of 2026-10-01. It is not an audit;
the launch's separate adversarial review decides admission.

## What was re-run

| Check | Result |
| --- | --- |
| `forge build --offline` | compiles, solc 0.8.26, no errors |
| `forge test --offline` | 56 tests pass (6 token, 47 hook, 3 script), 256 fuzz runs each |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | runs, hook lands on an address ending in flags `0x28C0` |
| Pinned `Hook.protected.t.sol` and `Token.protected.t.sol` (run from `test/scratch` with the built creation code, flags 10432) | all pass |
| The three reviewer proofs, re-mined for flags `0x28C0` (copies under `test/scratch`) | 3 of 3 pass; the originals fail in `setUp` because they mine the pre-fix flag set, see finding 7 |

## Checklist walk-through

**Caller verification.** All four enabled callbacks carry `onlyPoolManager`. The seven unimplemented
callbacks revert unconditionally. Covered by `test_callbacksRefuseCallersOtherThanThePoolManager` and
`test_unimplementedCallbacksRevertEvenForThePoolManager`.

**Permissions and address.** `getHookPermissions` declares `beforeInitialize | beforeAddLiquidity |
beforeSwap | afterSwap` (`0x28C0`, decimal 10432); the constructor runs `Hooks.validateHookPermissions` so a
wrong address cannot deploy (`test_constructorRefusesAnAddressWithoutTheFlags`). This check matters more
now: a hook at an address without the `beforeAddLiquidity` bit would silently never be asked about
positions. No `*ReturnDelta` flag is set, so the NoOp vector does not exist. `beforeSwap` returns
`ZERO_DELTA` and fee override `0`; `afterSwap` returns `0`.

**Delta accounting.** The hook never calls `take`, `settle`, `mint` or `burn` on the manager. Deltas always
sum to zero because the hook adds nothing to them.

**Sender identity.** The `sender` parameter (the router) is used in exactly two places: `beforeInitialize`
records it as the launch (`initializer`), and `beforeAddLiquidity` compares against it. Swaps remain
global to the pool, so no router allowlist is needed for trading. The limitation that a shared router's
users are indistinguishable is documented; it is why the launch must seed in the initialization
transaction or add as its own router.

**Reentrancy.** The swap callbacks make no external calls. `deposit` and `withdraw` update state before the
token transfer (checks-effects-interactions). `vote` reads `totalSupply` and `balanceOf` on the launch
token, a plain OpenZeppelin ERC-20 with no callbacks, and `exttload` on the manager. `vote` refuses to run
while the manager is unlocked, so no unlock callback can vote.

**Transient storage.** `beforeInitialize` writes one transient slot (`INITIALIZING_SLOT`) and
`beforeAddLiquidity` reads it. Transient storage is zero at the start of every transaction, so the flag
cannot leak into a later transaction (`test_launchSeedsSeveralPositionsInTheInitializationTransaction`
checks a later add through a fresh router is refused). Requires `evm_version = "cancun"`, which the
PoolManager already requires.

**Token handling.** The hook is designed for `SurfToken` (standard, 18 decimals, no fee on transfer).
Transfer return values are checked. It does not assume decimals anywhere: all amounts are raw units.

**Arithmetic.** Multiplication before division in `quorum` and `sellAllowance`. Casts from `int128` deltas
go through `int256` so the negation cannot overflow. All counters are `uint256`; with a `10^27` supply they
cannot overflow.

**Timestamps.** Used only to gate windows and lock deposits; no randomness. A validator's few seconds of
skew can shift a window edge by that much, which is stated in the README.

**Access control.** There are no privileged functions. "Who can change it: no one" holds by construction.
The `initializer` is not an admin: it may only add liquidity, which it could do anyway as the launch.

**No hardcoded addresses.** The PoolManager is a constructor argument; the token is read from the pool key
at initialization; the launch is read from the `initialize` call.

**Gas.** `beforeSwap` on a buy is one `SLOAD` (`genesis`) plus the modifier; on a sell it reads a handful of
slots. `afterSwap` writes one slot. `beforeAddLiquidity` is one `TLOAD` and two `SLOAD`s, plus one `SSTORE`
on the first ever add. No loops in any callback.

**Escape hatches.** No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in either runtime
(`test_runtimeCodeHasNoEscapeHatch`, and the pinned token test).

## Findings and dispositions

Items 1 to 6 are from the first self-review; items 7 to 12 come from the independent review and were
reproduced here before anything changed.

1. **Quorum snapshot timing is chosen by the first voter (low).** The first `vote` of a day fixes the
   quorum from circulating supply at that moment. Circulating supply can only rise during a day after the
   first hour, so a voter who acts right after the window closes gets the lowest quorum of the day; buys that
   happen later make no difference. Disposition: accepted and documented. The alternative (a fixed share of
   total supply) is unreachable while the pool holds most of the supply, and a snapshot at day end would need
   a keeper. The `QuorumSnapshot` event makes the number public.

2. **Sell allowance is first come, first served (informational).** Bots can consume the whole window's
   allowance in the first blocks. The brief asks for a cap, not for fair allocation. Disposition: documented.

3. **The rules bind only this pool (informational).** A standard token cannot stop sells elsewhere, and the
   launch refuses a non-standard token. Disposition: documented in the README under "What the hook cannot do".

4. **Liquidity operations were unrestricted (was informational, reopened as high, fixed).** The first review
   treated open liquidity as outside the brief. The independent review showed it is not: a SURF-only
   position just below the price is a resting sell order that any buy fills, so any holder could exit to
   ETH on day 0 with no vote, no window and no cap, and could inflate `bought` by buying from their own
   position. Disposition: fixed. `beforeAddLiquidity` is enabled and accepts a position only in the
   initialization transaction, from the initializer, or as the pool's first position. See item 7.

5. **Deposited SURF is custodied by the hook (low).** `withdraw` is the only way out and only the depositor
   can call it; there is no admin sweep. Fuzz `testFuzz_depositsAreAlwaysRecoverable` checks every deposit
   comes back after the lock. Disposition: accepted; it is what makes votes Sybil-resistant.

6. **Exact-output sells fail late (informational).** A sell that names its ETH output is only checked in
   `afterSwap`, after the pool computed the swap, because the SURF input is unknown before. The transaction
   still reverts cleanly and charges nothing. Disposition: documented; front-ends should prefer exact-input
   sells bounded by `sellRemaining()`.

7. **Single-sided positions bypass the buys-only rule, and self-liquidity inflates `bought` (high, two
   findings, fixed together).** Reproduced with the reviewers' tests: a holder with 1,000 SURF left with
   about 1,003 ETH on day 0; a wash through a dense own position recorded about 997,483 SURF bought when
   about 30 SURF left the pool. Fix: `beforeAddLiquidity` as described in the README. With it, the holder's
   add reverts with `LiquidityNotFromLaunch`, no ETH reaches the holder, and the wash's `bought` equals the
   SURF that really left the pool (`test_holderCannotExitThroughASingleSidedPositionWhileSellsAreClosed`,
   `test_selfLiquidityWashCannotInflateBought`, `testFuzz_thirdPartyPositionsAreAlwaysRefused`).
   Note on the reviewers' proofs: they mine the hook address for the pre-fix flags `0x20C0`, and the
   constructor's permission check refuses that address once `beforeAddLiquidity` is declared
   (`HookAddressNotValid`). Relaxing the check would not help: the PoolManager only calls the callbacks the
   address advertises, so a hook at `0x20C0` could never refuse a position. Copies of the proofs that
   differ only in the mined flags pass; the originals cannot pass against any fix that uses the one
   mechanism v4 offers for refusing a position.

8. **Quorum snapshot could be inflated by a flash `take` inside an unlock (high, fixed).** Reproduced:
   a griefer with 1 wei of stake took the manager's whole SURF balance inside `unlock`, voted, and paid it
   back; the snapshot was 5% of total supply and a 20M-SURF yes vote failed. Fix: `vote` reverts
   `ManagerUnlocked` when `poolManager.exttload(Lock.IS_UNLOCKED_SLOT)` is non-zero. The manager's balance
   can only be moved through `take`/`settle`/`mint`/`burn`, all of which require an unlock, so a locked
   manager's balance is an honest base. `test_voteIsRefusedWhileTheManagerIsUnlocked` covers the griefer
   and the honest path. The re-mined reviewer proof passes.

9. **`hasVoted(voter, day)` forgot earlier days (low, fixed).** It compared a single "last vote day" slot.
   Now a `voter => day => bool` mapping; `test_hasVotedRemembersEveryDayAVoterVotedOn`. The one-vote-per-day
   rule is unchanged.

10. **Majority AND quorum (informational, kept).** The brief says "majority or quorum minimum"; the stricter
    conjunctive reading is deliberate and documented, with the consequence (sells may stay closed if 5% of
    the circulating supply does not stake) spelled out for the requester.

11. **`circulatingSupply()` subtracts the manager's whole SURF balance (informational, documented).** SURF in
    hookless pools or ERC-6909 claims lowers the quorum by 5% of the parked amount, and launch allocations
    outside the pool raise it. Staking always beats parking, so no exploit; the README now describes the
    base accurately and asks the operator to check the quorum against the planned distribution. The
    manipulable variant (flash `take`) is item 8.

12. **Exact-input pre-check uses the nominal amount (informational, documented).** A price-limited sell that
    would fill only part of `amountSpecified` is still checked on the full amount. Conservative; routers
    should request no more than `sellRemaining()`.

13. **`beforeInitialize` binds to the first qualifying pool (informational, documented).** Safe only because
    the factory deploys the hook and initializes the pool in one transaction; the README records this as a
    deployment guarantee the launch must keep.

## Open items for the launch

- The launch manifest must pass `["$poolManager"]` as the hook's constructor arguments, flags `10432`
  (`0x28C0`), the pool key with native ETH as `currency0`, fee `3000`, tick spacing `60`.
- The factory must deploy the hook, initialize the pool and seed liquidity in one transaction. Any
  position added in that transaction, through any router, is accepted; afterwards only the initializer as
  its own router may add.
- Explorer verification and the fork rehearsal belong to the network's deployer.
- Slither and Mythril were not available in this environment and were not run.
