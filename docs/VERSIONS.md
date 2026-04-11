# Darbitex version history

Chronological log of every release and on-chain upgrade. Each entry names the
source commit, the on-chain transactions, and a summary of what changed.

## V0 — Alpha (deprecated)

**Repo:** https://github.com/darbitex/alpha
**Publisher:** `0x85d1e4047bde5c02b1915e5677b44ff5a6ba13452184d794da4658a4814efd30`
(single-wallet publisher — god-mode over the package)
**Deployed:** 2026-04-10 morning
**Status:** retired 2026-04-10 afternoon

First mainnet deployment of Darbitex. Same contracts as V1 aside from the
admin/treasury mutability path. The protocol admin was transferred to a
3-of-5 multisig and the treasury to a 2-of-3 multisig the same day, but the
package upgrade authority stayed bound to a single wallet, which made the
admin multisig bypassable via a malicious upgrade. Shutdown and superseded
by alpha V1 for that reason. See the alpha repo's `DEPRECATED.md` for the
full rationale.

## V1.0 — Initial alpha-v1 deploy

**Repo:** https://github.com/darbitex/alpha-v1
**Publisher:** `0x810693eb5e17185ee7d80e548a48edcb60be4b1d56d33f8c1be716d9fb422d2e`
(Aptos `0x1::multisig_account` — 1-of-5 at bootstrap, raised to 3-of-5 the
same day)
**Deployed:** 2026-04-10 afternoon
**Source commit:** `4869af6` (initial commit)

Redeployment of the alpha contracts under a multisig publisher, so that any
future upgrade requires the same threshold as changing the protocol admin.
`admin` and `treasury` were converted from runtime-settable fields into
hardcoded constants in `pool.move`. `ProtocolConfig` was collapsed to
`{ factory_addr }`. `propose_admin`, `accept_admin`, `set_treasury`, and
`ProtocolConfigUpdated` were deleted. All audit-tag comments stripped from
source. No behavior changes beyond governance.

Init transactions:
- Multisig create: `0x965953b588b8dc3f792577916b083aba68b879a2d065173ffc6fb5f99af098a9`
- Publish: `0x50a94d17fe8a5d05802e66e38d508a9f791563e49b9c1cddbe366da2b0e08238`
- `lp_coin::init`, `pool_factory::init_factory`, `pool::init_protocol`,
  `hook_wrapper::init` — four propose+execute pairs, versions 4832184998
  through 4832188497
- Threshold raise 1/5 → 3/5: propose version 4832598389, execute version
  4832598607

Post-deploy state: 3 smoke-test pools (USDT/USDC, APT/USDT, APT/USDC), all
seeded at ~$1-2 TVL. `darbitex.apt` ANS target and ownership transferred to
the publisher multisig.

## V1.1 — Audit patch bundle

**Source commit:** `fdc084c`
**Deployed:** 2026-04-10 late evening

First on-chain upgrade, first real exercise of the 3-of-5 governance path.
Compatible upgrade — no struct layout changes, no signature changes. Seven
findings fixed from the V1 audit in a single bundle, plus one regression
test.

Changes:

| Module | Finding | Change |
|---|---|---|
| `pool.move` | H1 | Saturate `lp_fee = max(0, total_fee - hook_fee - protocol_fee)` instead of underflowing when `total_fee < extra_fee`. Sub-10k-raw swaps no longer abort. |
| `pool.move` | L1 | `withdraw_hook_fee` and `withdraw_protocol_fee` both assert `!pool.locked` up front. Removes a fragile reentrancy coupling with the flash-loan re-sync path. |
| `pool.move` | L2 | Move `update_twap(pool)` to *before* the reserve mutation in `swap_internal`, matching the ordering in `add_liquidity_internal` and `remove_liquidity_internal`. The prior interval now accrues at the pre-swap ratio. |
| `bridge.move` | M2 | `MAX_IMBALANCE_PCT` lowered from 80 to 60 so a pegged pair cannot skew past a 40/60 split before the depeg guard fires. |
| `bridge.move` | M3 | `create_bridge` now requires the initial deposit to be symmetric within 1%, preventing a first-depositor from seeding a skewed ratio on a pair marketed as pegged. |
| `router.move` | M4 | 2-hop and 3-hop routers reject repeated pool addresses, and the deadline check is strict-less-than. |
| `pool_factory.move` | M5 | New public `seller_cancel_resale` lets a lister pull a no-bid resale listing early by presenting the same `HookCap` they listed with, verified against `auction.seller`. |
| `tests.move` | H1 regression | `test_swap_below_total_fee_floor` walks `amount_in = 1, 500, 9999, 10000` — every value that used to abort under H1 now succeeds. |

On-chain transactions:

| Step | TX | Notes |
|---|---|---|
| Propose (seq#9, hash-only) | `0xfffbb1a493a6d1a81718027cf572c324d16ab42d334330f39143f61a73a35690` | creator `0x85d1e4…`, auto-vote 1/3 |
| Approval #2 | on-chain via Petra mobile | owner `0xf6e1d1fd…`, 2/3 |
| Approval #3 | on-chain via Petra mobile | owner `0xa1189e55…`, 3/3 |
| Execute | `0xe7804be3f1db9e60f5c4108f503c07f6d301767c296bab27571d4ffcc538ad91` | `is_upgrade: true`, version 4833188571 |

Verification swaps on the USDT/USDC pool: `amount_in = 500` and `amount_in = 1`
(both would have aborted pre-upgrade) succeeded and advanced
`protocol_fee_a` by 1 each time, confirming the H1 saturation fix and the
hardcoded `TREASURY` routing both work at runtime.

Coordination time from propose to execute: about 18 minutes. Petra Vault
desktop refused to display the inner `publish_package_txn`; approvals were
signed from Petra mobile instead.

**Version metadata note.** The `Move.toml` version field was still `1.0.0`
when the V1.1 patch was compiled and shipped, so the on-chain package
metadata for the V1.1 bytecode carries `1.0.0`. `Move.toml` was bumped to
`1.1.0` after the fact to align the repo label with the logical version
and give the next upgrade a clean increment. The behavioral version is
still V1.1 — logs, docs, and memory all use that label.

Deferred to a future upgrade:
- H2, H3, M1 — require struct layout changes on `Pool` and `HookCap` to add
  a `hook_epoch` field; therefore cannot ship in a compatible upgrade. These
  will roll in the breaking V2 redeploy.
- M6 — test coverage for auction, admin, bridge, hook wrapper, and router
  multi-hop paths. Ongoing test-engineering work, not blocked by the chain.

## V1.2 — Meta Router (2026-04-11)

**Repo:** https://github.com/darbitex/alpha-v1
**Publisher multisig:** `0x810693eb5e17185ee7d80e548a48edcb60be4b1d56d33f8c1be716d9fb422d2e` (3/5)
**Source commit:** see git tag `v1.2.0`
**Type:** compatible upgrade (new module only, no struct or storage changes)
**Status:** compiled + all 15 unit tests passing; upgrade proposal pending multisig coordination

### What changed

New module `darbitex::meta_router` adds auto-discovery multi-hop routing
on top of the existing `pool` and `pool_factory` primitives. It is
purely additive — no existing function or struct is touched, and the
existing `router` module stays in place for callers that prefer to
specify pool addresses manually.

The module exposes three functions:

- `#[view] best_route(md_in, md_out, amount_in) -> (pool1, pool2, expected_out)`
  enumerates the direct canonical pool for the pair plus 2-hop routes
  through each well-known bridge token (APT FA `@0xa`, lzUSDC canonical
  FA `@0x2b3be0…`, and native Circle USDC FA `@0xbae207…`), and returns
  whichever path yields the highest output. If the best route is direct,
  `pool2` is `@0x0`; if no route exists at all, both pool addresses are
  `@0x0` and `expected_out` is `0`. The bridge loop is wrapped in an
  `object::object_exists` check so the view never aborts on a chain
  state where a bridge token has been deleted or not yet deployed.

- `#[view] quote_direct(md_in, md_out, amount_in) -> u64` returns the
  direct-pool quote only. External aggregators that prefer to do their
  own multi-venue routing can use this to treat Darbitex as a single
  venue without paying for bridge-hop enumeration.

- `public entry swap_best(signer, md_in, md_out, amount_in, min_out, deadline)`
  runs `best_route` internally, aborts `E_NO_ROUTE` (2) if the pair is
  unreachable, `E_SLIPPAGE` (5) if the quoted output is below `min_out`,
  and `E_DEADLINE` (1) if the block clock is past `deadline`. When the
  chosen route is direct it issues a single `pool::swap`; when the route
  is 2-hop it issues two `pool::swap` calls and only enforces
  `min_out` against the final leg (intermediate hop runs with
  `min_out = 0`).

### Rationale

The meta_router is Darbitex's answer to "how do external aggregators
consume us without us having to spam them with adapter contracts?"
With the new view functions, a Panora or Kana integration becomes a
one-line call in their routing engine: `meta_router::best_route(…)`
returns both the price and the pool path in a single RPC. The hand-
rolled `router.move` multi-hop variants still exist for callers that
already know the exact pool path they want (e.g. flash-loan bots),
but for everyone else the single-entry `swap_best` is the new front
door.

Bridge token list is hardcoded to APT, lzUSDC (canonical framework
paired FA), and nUSDC (Circle CCTP native) because those are the three
assets with the highest cross-pair count on Darbitex today. The
addresses are module constants — adding a new bridge token later is
a one-line source change rolled in a compatible upgrade.

### Tests

Five new unit tests in `tests.move`:

- `test_meta_router_quote_direct` — direct-pool quote matches `pool::get_amount_out` exactly, and `best_route` agrees with `quote_direct` when the chosen route is direct
- `test_meta_router_no_route` — pair with no canonical pool and no bridge connection returns `(@0x0, @0x0, 0)` instead of aborting
- `test_meta_router_degenerate` — `amount_in == 0` and `md_in == md_out` both return the empty route
- `test_meta_router_swap_direct` — end-to-end `swap_best` through a direct pool updates user balance by exactly the quoted output and moves reserves in the expected direction
- `test_meta_router_slippage_abort` — `swap_best` with `min_out = expected + 1` aborts `E_SLIPPAGE`
- `test_meta_router_deadline_abort` — `swap_best` with a deadline in the past aborts `E_DEADLINE` before any state change

Full suite: **16 tests, 16 passing**, no warnings.

### Pre-deploy audit (2026-04-11)

One finding caught before the first push:

- **A1 (low, latent)** — `lookup_pool` originally returned any pool that
  `pool::pool_exists` reported as present, regardless of whether a hook
  was attached. Since `meta_router` calls plain `pool::swap` (which
  aborts `E_HOOK_REQUIRED` on hooked pools), a selected hooked pool
  would have caused `swap_best` to abort at execution rather than
  routing around it. Currently zero exposure in V1 (no hooked pools
  live), but the bug becomes real the moment an auction winner attaches
  a hook to any pool.

  **Fix applied before tagging**: `lookup_pool` now additionally checks
  `pool::pool_hook` and treats a `Some(_)` result as "pool does not
  exist" from the router's perspective. Callers who want hooked-pool
  routing should continue to use `darbitex::router::swap_2hop_mixed`
  directly, which already knows how to dispatch through
  `hook_wrapper::swap`.

Other review items — reentrancy (Move's `borrow_global_mut` prevents
it), slippage enforcement on the final hop only (matches
`router::swap_2hop`), deadline ordering (checked before any state
change), bridge token `object_exists` guard (view stays abort-free on
fresh chain state), deterministic bridge iteration order, factory
initialization assumption, signer handling, and fungible-store
withdraw/deposit symmetry — all pass by inspection against the
existing `router.move` conventions.

Test coverage for the hooked-pool filter itself is **documented but
not unit-tested**: writing a proper test would require driving a full
auction → `pool_factory` → `pool::set_hook` flow because `set_hook`
requires the factory resource-account signer, which isn't publicly
constructible. Tracked under M6 as a follow-up next to the existing
test-coverage gap.

### Deploy plan

Upgrade #2, same flow as Upgrade #1:

1. `aptos multisig create-transaction --store-hash-only …` with publish payload (gas ≥ 300k on execute)
2. Two more owners approve via Petra mobile or CLI
3. `aptos multisig execute-with-payload …` from any owner once 3/3 votes reached
4. Verification: call `meta_router::best_route` against pool #4 (lzUSDC ↔ nUSDC) to confirm the view returns the bridge pool and a sensible quote

Deferred to a later upgrade:
- Extending bridge list beyond APT / lzUSDC / nUSDC once new stablecoin or LST pools land
- 3-hop routing (currently capped at 2 hops — sufficient for the pairs we host in V1)
