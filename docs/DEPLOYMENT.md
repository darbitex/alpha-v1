# Deployment

Aptos mainnet.

## Package

| Item | Address |
|---|---|
| Publisher (multisig, 1-of-5 → will scale to 3-of-5) | `0x810693eb5e17185ee7d80e548a48edcb60be4b1d56d33f8c1be716d9fb422d2e` |
| Package `darbitex` | same as publisher |
| Factory resource account | `0xe7e5fb074799b3241ce5bb5ba88eadbe609c5093efd8b4e06db8c21d1cca32ca` |
| Admin (hardcoded in `pool.move`) | `0xf1b522effb90aef79395f97b9c39d6acbd8fdf84ec046361359a48de2e196566` |
| Treasury (hardcoded in `pool.move`) | `0xdbce89113a975826028236f910668c3ff99c8db8981be6a448caa2f8836f9576` |

Admin and treasury are independent 3-of-5 and 2-of-3 multisigs respectively.
The publisher multisig currently holds 1-of-5 for bootstrap ergonomics and
will be raised to 3-of-5 once the production pools and smoke tests are
in place. Adding owners and raising the threshold does not change the
publisher address, so the package upgrade authority stays bound to the same
account.

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

Future upgrades follow the same pattern. Once the threshold is raised above
one, additional owners run `aptos multisig approve` between the
create-transaction and execute steps.

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
# returns []  after init, before any pools are created
```
