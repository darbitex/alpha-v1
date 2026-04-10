# Darbitex

Permissionless hooks DEX on Aptos. Canonical pools, unowned, composable, 1 bps fee.

Published from a multisig account so upgrading the package requires the same
threshold as changing the protocol admin. No single key can drain reserves,
bypass admin checks, or add a rug entry.

## Layout

| Path | What |
|---|---|
| `contracts/sources/` | Six Move modules |
| `contracts/Move.toml` | Package manifest |

## Modules

- **`pool`** — Core AMM, constant-product swap, LP accounting, TWAP, flash loans
- **`pool_factory`** — Canonical pool creation (one per pair), hook auction, resale
- **`hook_wrapper`** — Mandatory aggregator gateway for hooked pools
- **`router`** — Multi-hop routing across plain and hooked pools
- **`bridge`** — Stableswap bridge for pegged assets
- **`lp_coin`** — Per-pool LP tracking, soulbound, friend-only

## Build

```
cd contracts
aptos move compile --named-addresses darbitex=<publisher>
aptos move test    --named-addresses darbitex=<publisher>
```

Where `<publisher>` is the Aptos multisig account the package is published
from. Upgrades are routed through that multisig via `aptos multisig
create-transaction` + `approve` + `execute`.

## Governance

- **Admin** and **treasury** are hardcoded constants in `pool.move`. Changing
  them requires a package upgrade, which itself requires the multisig
  threshold — so the two authorities are bound together by design.
- **Upgrade** is `compatible` policy. The publisher multisig is the only
  account that can upgrade. Compromise of any subset of owners below the
  threshold is safe.

## License

[The Unlicense](./LICENSE) — public domain.
