/// Darbitex LP Token — per-pool LP tracking via nested Table.
/// Soulbound (non-transferable). mint/burn restricted to friend modules.

module darbitex::lp_coin {
    use std::signer;
    use aptos_std::table::{Self, Table};

    friend darbitex::pool;
    friend darbitex::pool_factory;
    friend darbitex::bridge;

    // ===== Errors =====
    const E_INSUFFICIENT: u64 = 1;
    const E_NOT_INIT: u64 = 2;
    const E_NOT_DEPLOYER: u64 = 3;

    /// Per-pool LP balance registry.
    /// Outer key = pool_addr, inner key = user_addr, value = LP balance.
    struct LPRegistry has key {
        pools: Table<address, Table<address, u64>>,
    }

    /// Initialize registry (deployer only, once).
    public entry fun init(deployer: &signer) {
        assert!(signer::address_of(deployer) == @darbitex, E_NOT_DEPLOYER);
        move_to(deployer, LPRegistry {
            pools: table::new(),
        });
    }

    /// Mint LP tokens for a specific pool. Friend modules only.
    public(friend) fun mint(
        registry_addr: address,
        pool_addr: address,
        to: address,
        amount: u64,
    ) acquires LPRegistry {
        let reg = borrow_global_mut<LPRegistry>(registry_addr);
        if (!table::contains(&reg.pools, pool_addr)) {
            table::add(&mut reg.pools, pool_addr, table::new());
        };
        let pool_table = table::borrow_mut(&mut reg.pools, pool_addr);
        if (table::contains(pool_table, to)) {
            let bal = table::borrow_mut(pool_table, to);
            *bal = *bal + amount;
        } else {
            table::add(pool_table, to, amount);
        }
    }

    /// Burn LP tokens for a specific pool. Friend modules only.
    public(friend) fun burn(
        registry_addr: address,
        pool_addr: address,
        from: address,
        amount: u64,
    ) acquires LPRegistry {
        let reg = borrow_global_mut<LPRegistry>(registry_addr);
        assert!(table::contains(&reg.pools, pool_addr), E_NOT_INIT);
        let pool_table = table::borrow_mut(&mut reg.pools, pool_addr);
        assert!(table::contains(pool_table, from), E_NOT_INIT);
        let bal = table::borrow_mut(pool_table, from);
        assert!(*bal >= amount, E_INSUFFICIENT);
        *bal = *bal - amount;
    }

    #[view]
    /// Get LP balance for a specific pool.
    public fun balance(
        registry_addr: address,
        pool_addr: address,
        addr: address,
    ): u64 acquires LPRegistry {
        if (!exists<LPRegistry>(registry_addr)) return 0;
        let reg = borrow_global<LPRegistry>(registry_addr);
        if (!table::contains(&reg.pools, pool_addr)) return 0;
        let pool_table = table::borrow(&reg.pools, pool_addr);
        if (table::contains(pool_table, addr)) {
            *table::borrow(pool_table, addr)
        } else {
            0
        }
    }
}
