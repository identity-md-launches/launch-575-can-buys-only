# Review notes: SurfToken and BuyGateHook

A self-review against the task's security references (the v4 hook security checklist and the ethskills
safety checklist) before hand-off. It is not an audit; the launch's separate adversarial review decides
admission.

## What was re-run

| Check | Result |
| --- | --- |
| `forge build --offline` | compiles, solc 0.8.26, no errors |
| `forge test --offline` | 47 tests pass (6 token, 38 hook, 3 script), 256 fuzz runs each |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | runs, hook lands on an address ending in flags `0x20C0` |
| Pinned `Hook.protected.t.sol` and `Token.protected.t.sol` (run from `test/scratch` with the built creation code, flags 8384) | 9 of 9 pass |

## Checklist walk-through

**Caller verification.** All three enabled callbacks carry `onlyPoolManager`. The eight unimplemented
callbacks revert unconditionally. Covered by `test_callbacksRefuseCallersOtherThanThePoolManager` and
`test_unimplementedCallbacksRevertEvenForThePoolManager`.

**Permissions and address.** `getHookPermissions` declares `beforeInitialize | beforeSwap | afterSwap`; the
constructor runs `Hooks.validateHookPermissions` so a wrong address cannot deploy
(`test_constructorRefusesAnAddressWithoutTheFlags`). No `*ReturnDelta` flag is set, so the NoOp vector does
not exist. `beforeSwap` returns `ZERO_DELTA` and fee override `0`; `afterSwap` returns `0`.

**Delta accounting.** The hook never calls `take`, `settle`, `mint` or `burn` on the manager. Deltas always
sum to zero because the hook adds nothing to them.

**Sender identity.** The `sender` parameter (the router) is unused. Every rule is global to the pool, so no
router allowlist is needed and none exists.

**Reentrancy.** The swap callbacks make no external calls. `deposit` and `withdraw` update state before the
token transfer (checks-effects-interactions). `vote` calls `totalSupply` and `balanceOf` on the launch token,
which is a plain OpenZeppelin ERC-20 with no callbacks. The token cannot be swapped for a different one after
binding, and only a native-ETH-quoted pool binds.

**Token handling.** The hook is designed for `SurfToken` (standard, 18 decimals, no fee on transfer).
Transfer return values are checked. It does not assume decimals anywhere: all amounts are raw units.

**Arithmetic.** Multiplication before division in `quorum` and `sellAllowance`. Casts from `int128` deltas
go through `int256` so the negation cannot overflow. All counters are `uint256`; with a `10^27` supply they
cannot overflow.

**Timestamps.** Used only to gate windows and lock deposits; no randomness. A validator's few seconds of
skew can shift a window edge by that much, which is stated in the README.

**Access control.** There are no privileged functions. "Who can change it: no one" holds by construction.

**No hardcoded addresses.** The PoolManager is a constructor argument; the token is read from the pool key
at initialization.

**Gas.** `beforeSwap` on a buy is one `SLOAD` (`genesis`) plus the modifier; on a sell it reads a handful of
slots. `afterSwap` writes one slot. No loops in any callback.

**Escape hatches.** No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in either runtime
(`test_runtimeCodeHasNoEscapeHatch`, and the pinned token test).

## Findings and dispositions

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

4. **Liquidity operations are unrestricted (informational).** A liquidity provider can withdraw SURF without a
   swap. The brief restricts swaps; the launch factory is the provider. Disposition: documented.

5. **Deposited SURF is custodied by the hook (low).** `withdraw` is the only way out and only the depositor
   can call it; there is no admin sweep. Fuzz `testFuzz_depositsAreAlwaysRecoverable` checks every deposit
   comes back after the lock. Disposition: accepted; it is what makes votes Sybil-resistant.

6. **Exact-output sells fail late (informational).** A sell that names its ETH output is only checked in
   `afterSwap`, after the pool computed the swap, because the SURF input is unknown before. The transaction
   still reverts cleanly and charges nothing. Disposition: documented; front-ends should prefer exact-input
   sells bounded by `sellRemaining()`.

No finding changes code.

## Open items for the launch

- The launch manifest must pass `["$poolManager"]` as the hook's constructor arguments, flags `8384`
  (`0x20C0`), the pool key with native ETH as `currency0`, fee `3000`, tick spacing `60`.
- Explorer verification and the fork rehearsal belong to the network's deployer.
- Slither and Mythril were not available in this environment and were not run.
