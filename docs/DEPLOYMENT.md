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

## Smoke test

A single USDT / USDC native pool was created as a post-deploy smoke test:

| Item | Value |
|---|---|
| Pool | `0x2d17a08cd2ee2da9c37b1cc3107bd56cf8d5fea0b959aa2840e951ed0e239a0a` |
| Pair | USDT native / USDC native |
| Seed | 1.0 USDT + 1.0 USDC |
| LP minted to creator | 999 000 (1000 locked as minimum liquidity) |

The smoke test exercised `create_canonical_pool`, `swap_entry`,
`pending_fees`, `add_liquidity`, `remove_liquidity`, and the `protocol_config`
view. Swap math matched the constant-product formula exactly; the first swap
produced one raw unit of protocol fee, which confirmed the hardcoded
`TREASURY` routing works at runtime.
