/// Darbitex Hook Wrapper — Mandatory aggregator gateway for hooked pools.
///
/// Pools with hook_addr = @darbitex use this wrapper.
/// Exposes public swap, liquidity, and flash loan for any caller.
/// Aggregators compose via hook_wrapper::swap() instead of pool::swap_hooked().

module darbitex::hook_wrapper {
    use std::signer;
    use std::option;
    use aptos_std::table::{Self, Table};
    use aptos_framework::object::Object;
    use aptos_framework::fungible_asset::{FungibleAsset, Metadata};
    use aptos_framework::primary_fungible_store;

    use darbitex::pool::{Self, HookCap, FlashReceipt};

    // ===== Errors =====
    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_INIT: u64 = 2;
    const E_ALREADY_INIT: u64 = 3;
    const E_NOT_REGISTERED: u64 = 4;
    const E_ALREADY_REGISTERED: u64 = 5;

    // ===== Witness for claim_hook_cap =====
    struct Witness has drop {}

    // ===== Registry =====

    struct WrapperRegistry has key {
        caps: Table<address, HookCap>,
    }

    // ===== Init =====

    public entry fun init(deployer: &signer) {
        let addr = signer::address_of(deployer);
        assert!(addr == @darbitex, E_NOT_ADMIN);
        assert!(!exists<WrapperRegistry>(@darbitex), E_ALREADY_INIT);
        move_to(deployer, WrapperRegistry {
            caps: table::new(),
        });
    }

    // ===== Pool Registration =====

    /// Claim HookCap for a pool whose hook_addr is @darbitex.
    /// Call after factory sets hook to @darbitex.
    public entry fun register_pool(pool_addr: address) acquires WrapperRegistry {
        assert!(exists<WrapperRegistry>(@darbitex), E_NOT_INIT);
        let reg = borrow_global_mut<WrapperRegistry>(@darbitex);
        assert!(!table::contains(&reg.caps, pool_addr), E_ALREADY_REGISTERED);
        let cap = pool::claim_hook_cap<Witness>(pool_addr, Witness {});
        table::add(&mut reg.caps, pool_addr, cap);
    }

    // ===== Swap (Composable) =====

    /// Aggregator-friendly swap through hooked pool. Returns FungibleAsset.
    public fun swap(
        pool_addr: address, swapper: address,
        fa_in: FungibleAsset, min_out: u64,
    ): FungibleAsset acquires WrapperRegistry {
        let reg = borrow_global<WrapperRegistry>(@darbitex);
        assert!(table::contains(&reg.caps, pool_addr), E_NOT_REGISTERED);
        let cap = table::borrow(&reg.caps, pool_addr);
        pool::swap_hooked(pool_addr, swapper, fa_in, min_out, cap)
    }

    /// Entry swap for direct user calls.
    public entry fun swap_entry(
        swapper: &signer, pool_addr: address,
        metadata_in: Object<Metadata>, amount_in: u64, min_out: u64,
    ) acquires WrapperRegistry {
        let addr = signer::address_of(swapper);
        let fa_in = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa_out = swap(pool_addr, addr, fa_in, min_out);
        primary_fungible_store::deposit(addr, fa_out);
    }

    // ===== Liquidity =====

    public entry fun add_liquidity(
        provider: &signer, pool_addr: address,
        amount_a: u64, amount_b: u64,
    ) acquires WrapperRegistry {
        let reg = borrow_global<WrapperRegistry>(@darbitex);
        assert!(table::contains(&reg.caps, pool_addr), E_NOT_REGISTERED);
        let cap = table::borrow(&reg.caps, pool_addr);
        pool::add_liquidity_hooked(provider, pool_addr, amount_a, amount_b, cap);
    }

    public entry fun remove_liquidity(
        provider: &signer, pool_addr: address, lp_amount: u64,
    ) acquires WrapperRegistry {
        let reg = borrow_global<WrapperRegistry>(@darbitex);
        assert!(table::contains(&reg.caps, pool_addr), E_NOT_REGISTERED);
        let cap = table::borrow(&reg.caps, pool_addr);
        pool::remove_liquidity_hooked(provider, pool_addr, lp_amount, cap);
    }

    // ===== Flash Loan (Hooked Pools Only) =====

    /// Flash borrow from hooked pool. Must call flash_repay in same tx.
    public fun flash_borrow(
        pool_addr: address, borrower: address,
        metadata: Object<Metadata>, amount: u64,
    ): (FungibleAsset, FlashReceipt) acquires WrapperRegistry {
        let reg = borrow_global<WrapperRegistry>(@darbitex);
        assert!(table::contains(&reg.caps, pool_addr), E_NOT_REGISTERED);
        let cap = table::borrow(&reg.caps, pool_addr);
        pool::flash_borrow_hooked(pool_addr, borrower, metadata, amount, cap)
    }

    /// Flash repay — consumes receipt (hot potato).
    public fun flash_repay(pool_addr: address, receipt: FlashReceipt) {
        pool::flash_repay(pool_addr, receipt)
    }

    // ===== Fee Withdrawal (Admin → Treasury) =====

    public entry fun withdraw_fees(
        admin: &signer, pool_addr: address,
    ) acquires WrapperRegistry {
        let (admin_addr, treasury, _) = pool::protocol_config();
        assert!(signer::address_of(admin) == admin_addr, E_NOT_ADMIN);
        let reg = borrow_global<WrapperRegistry>(@darbitex);
        assert!(table::contains(&reg.caps, pool_addr), E_NOT_REGISTERED);
        let cap = table::borrow(&reg.caps, pool_addr);
        pool::withdraw_hook_fee(pool_addr, treasury, cap);
    }

    // ===== Cleanup =====

    /// Unregister a pool whose hook has been removed or reassigned.
    /// Cleans up the stale HookCap; only callable when the pool's hook is
    /// no longer @darbitex.
    public entry fun unregister_pool(pool_addr: address) acquires WrapperRegistry {
        assert!(exists<WrapperRegistry>(@darbitex), E_NOT_INIT);
        let reg = borrow_global_mut<WrapperRegistry>(@darbitex);
        assert!(table::contains(&reg.caps, pool_addr), E_NOT_REGISTERED);
        let (hook_opt, _) = pool::pool_hook(pool_addr);
        let stale = if (option::is_none(&hook_opt)) { true }
        else { *option::borrow(&hook_opt) != @darbitex };
        assert!(stale, E_ALREADY_REGISTERED);
        let cap = table::remove(&mut reg.caps, pool_addr);
        pool::destroy_hook_cap(cap);
    }

    // ===== Views =====

    #[view]
    public fun is_registered(pool_addr: address): bool acquires WrapperRegistry {
        if (!exists<WrapperRegistry>(@darbitex)) return false;
        let reg = borrow_global<WrapperRegistry>(@darbitex);
        table::contains(&reg.caps, pool_addr)
    }
}
