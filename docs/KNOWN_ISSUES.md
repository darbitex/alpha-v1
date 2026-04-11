# Known Issues — deferred to V2.0 breaking redeploy

Findings from `AUDIT-2026-04-10.md` that cannot be fixed in a compatible upgrade
because they require Move struct layout changes. V2.0 will redeploy at a new
package address with state migration for existing pools.

Not urgent while zero hooked pools exist on mainnet. Blocker only becomes
exploitable once the first hook auction resolves.

## H2 — HookCap resurrection

`pool.move` `HookCap` has `store` ability and persists in hook-module storage
without an epoch stamp. After `remove_hook` followed by `set_hook` to the same
address, the stale cap still passes `assert_valid_cap`.

**Fix:** add `hook_epoch: u64` field on `Pool` and on `HookCap`, bump epoch on
every `remove_hook`, compare in `assert_valid_cap`. Struct layout change →
breaking.

## H3 — hook_wrapper lifecycle desync

`hook_wrapper.move` family of H2 from the wrapper side. On consecutive
`@darbitex` auctions the second winner cannot register because a stale wrapper
entry exists and cannot be unregistered. Fixed by the same epoch mechanism as
H2.

## M1 — witness auth by module address only

Witness-gated hook dispatch validates only the module address, not the
module+struct-name pair. A different module at the same address could forge a
witness of the expected type. Fix = bind witness to a phantom type parameter
carrying the struct identity. Struct-signature change → breaking.

## V2.0 design checklist

- [ ] `hook_epoch` field on `Pool` and `HookCap`, bumped in `remove_hook`
- [ ] `assert_valid_cap` checks epoch equality
- [ ] `hook_wrapper` registry keyed by `(addr, epoch)` instead of `addr` alone
- [ ] Witness type binding via phantom `W: drop + store` on the hook entry
- [ ] Migration: re-publish at new address, migrate 3 existing smoke pools
      (pool 1/2/3) by LP-out from V1 and LP-in to V2, or cold-freeze V1
- [ ] Update router + frontend to point at new package address
- [ ] Bump to `2.0.0` in `Move.toml`, `docs/VERSIONS.md`, git tag `v2.0.0`
