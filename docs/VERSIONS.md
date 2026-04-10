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
