# Deployment

Aptos mainnet.

## Package

| Item | Address |
|---|---|
| Publisher (multisig, 3-of-5) | `0x810693eb5e17185ee7d80e548a48edcb60be4b1d56d33f8c1be716d9fb422d2e` |
| Package `darbitex` | same as publisher |
| Factory resource account | `0xe7e5fb074799b3241ce5bb5ba88eadbe609c5093efd8b4e06db8c21d1cca32ca` |
| Admin (hardcoded in `pool.move`) | `0xf1b522effb90aef79395f97b9c39d6acbd8fdf84ec046361359a48de2e196566` |
| Treasury (hardcoded in `pool.move`) | `0xdbce89113a975826028236f910668c3ff99c8db8981be6a448caa2f8836f9576` |
| ANS `darbitex.apt` | points forward and reverse to the publisher |

Admin and treasury are independent 3-of-5 and 2-of-3 multisigs. The publisher
multisig is also 3-of-5, so upgrading the package requires the same threshold
as changing the protocol admin. No single key compromise is sufficient for
any privileged operation.

The publisher was bootstrapped as 1-of-5 for deploy-day ergonomics and raised
to 3-of-5 the same day, after smoke tests passed. Owner and threshold changes
do not alter the multisig address, so the package upgrade authority stays
bound to the same account across any future owner rotation.

## Publish flow

The package was built into a JSON payload and routed through the multisig:

```
aptos move build-publish-payload --named-addresses darbitex=<publisher> \
  --json-output-file publish.json

aptos multisig create-transaction --multisig-address <publisher> \
  --json-file publish.json --store-hash-only

aptos multisig execute-with-payload --multisig-address <publisher> \
  --json-file publish.json
```

Future upgrades follow the same pattern. Since the threshold is 3, two
additional owners run `aptos multisig approve` between the create-transaction
and execute steps.

Note: `aptos move run` from a terminal rejects a 39 KB publish payload at the
default 50 000 max-gas. Use `--max-gas 300000` on the execute step. Init
entry calls after the publish are cheap and the default max-gas is fine.

## Init

Four entry calls, each submitted as a multisig transaction:

1. `lp_coin::init`
2. `pool_factory::init_factory`
3. `pool::init_protocol(factory_addr)` — factory address read from the
   `Factory` resource after step 2
4. `hook_wrapper::init`

## Verify

```
aptos move view --function-id <publisher>::pool::protocol_config
# returns (admin, treasury, factory_addr)

aptos move view --function-id <publisher>::pool_factory::get_all_pools
# returns the list of canonical pools
```

## Pools

| # | Pair | Address | Seed | TVL |
|---|---|---|---|---|
| 1 | USDT / USDC native | `0x2d17a08cd2ee2da9c37b1cc3107bd56cf8d5fea0b959aa2840e951ed0e239a0a` | 1.0 USDT + 1.0 USDC | ~$2 |
| 2 | APT / USDT native | `0x2a9e11a6763fcc605a34e657be24d9a73f91c280f18ec420af1a854cade48b52` | 0.5747 APT + 0.5 USDT | ~$1 |
| 3 | APT / USDC native | `0x1d468111c8bacc02f4f6bc8ebb79378e25074897d38b274d662bd3947fdcdf0f` | 0.5747 APT + 0.5 USDC | ~$1 |

Seeds for pools 2 and 3 are sized at 1 APT ≈ $0.87 so each side carries
about $0.50 of value, matching the market rate at deploy time.

## Smoke test

All three pools were exercised end-to-end against mainnet immediately
after creation. Each ran the same six-step sequence: `swap_entry`,
`pending_fees` view, `add_liquidity`, `remove_liquidity` of half the added
LP, and final-state views.

All 18 calls succeeded. The constant-product swap math matched the
formula exactly. The first swap on each pool produced a protocol fee that
confirmed the hardcoded `TREASURY` routing works at runtime:

- Pool 1, `swap 10 000 USDT` → `protocol_fee_a = 1 raw USDT`
- Pool 2, `swap 1 000 000 octas APT` → `protocol_fee_a = 10 octas APT`
- Pool 3, `swap 1 000 000 octas APT` → `protocol_fee_a = 10 octas APT`

Pools 2 and 3 produced byte-identical deltas across every step because
they were seeded with the same values and swapped the same amounts in the
same direction. This confirms the math is deterministic under identical
inputs.

See `AUDIT-2026-04-10.md` for the audit run that followed the smoke
tests. One HIGH finding (H1) documents a swap underflow for amounts
below 10 000 raw units, observed at exactly this boundary — the smoke
tests sat right on the boundary and succeeded, but a swap of 9 999 raw
would have aborted.
