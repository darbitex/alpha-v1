/// Darbitex Router — multi-hop swap routing.
/// Supports plain pools (pool::swap) and wrapped hooked pools
/// (hook_wrapper::swap). Aggregators compose the `public fun` variants;
/// end users hit the `entry` variants.

module darbitex::router {
    use std::signer;
    use aptos_framework::timestamp;
    use aptos_framework::object::Object;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;

    use darbitex::pool;
    use darbitex::hook_wrapper;

    const E_DEADLINE: u64 = 1;
    const E_SAME_POOL: u64 = 2;

    fun assert_deadline(deadline: u64) {
        assert!(timestamp::now_seconds() < deadline, E_DEADLINE);
    }

    // ===== Single Hop =====

    /// Plain pool swap with deadline.
    public entry fun swap_with_deadline(
        swapper: &signer, pool_addr: address,
        metadata_in: Object<Metadata>,
        amount_in: u64, min_out: u64, deadline: u64,
    ) {
        assert_deadline(deadline);
        let addr = signer::address_of(swapper);
        let fa_in = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa_out = pool::swap(pool_addr, addr, fa_in, min_out);
        primary_fungible_store::deposit(addr, fa_out);
    }

    /// Wrapped hooked pool swap with deadline.
    public entry fun swap_wrapped_with_deadline(
        swapper: &signer, pool_addr: address,
        metadata_in: Object<Metadata>,
        amount_in: u64, min_out: u64, deadline: u64,
    ) {
        assert_deadline(deadline);
        let addr = signer::address_of(swapper);
        let fa_in = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa_out = hook_wrapper::swap(pool_addr, addr, fa_in, min_out);
        primary_fungible_store::deposit(addr, fa_out);
    }

    // ===== 2-Hop =====

    /// 2-hop through plain pools.
    public entry fun swap_2hop(
        swapper: &signer, pool1_addr: address, pool2_addr: address,
        metadata_in: Object<Metadata>,
        amount_in: u64, min_out: u64, deadline: u64,
    ) {
        assert_deadline(deadline);
        assert!(pool1_addr != pool2_addr, E_SAME_POOL);
        let addr = signer::address_of(swapper);
        let fa = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa = pool::swap(pool1_addr, addr, fa, 0);
        let fa = pool::swap(pool2_addr, addr, fa, min_out);
        primary_fungible_store::deposit(addr, fa);
    }

    /// 2-hop mixed: each hop can be plain or wrapped.
    /// wrapped1/wrapped2 = true → use hook_wrapper, false → use pool directly.
    public entry fun swap_2hop_mixed(
        swapper: &signer,
        pool1_addr: address, wrapped1: bool,
        pool2_addr: address, wrapped2: bool,
        metadata_in: Object<Metadata>,
        amount_in: u64, min_out: u64, deadline: u64,
    ) {
        assert_deadline(deadline);
        assert!(pool1_addr != pool2_addr, E_SAME_POOL);
        let addr = signer::address_of(swapper);
        let fa = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa = if (wrapped1) {
            hook_wrapper::swap(pool1_addr, addr, fa, 0)
        } else {
            pool::swap(pool1_addr, addr, fa, 0)
        };
        let fa = if (wrapped2) {
            hook_wrapper::swap(pool2_addr, addr, fa, min_out)
        } else {
            pool::swap(pool2_addr, addr, fa, min_out)
        };
        primary_fungible_store::deposit(addr, fa);
    }

    // ===== 3-Hop =====

    /// 3-hop through plain pools.
    public entry fun swap_3hop(
        swapper: &signer,
        pool1_addr: address, pool2_addr: address, pool3_addr: address,
        metadata_in: Object<Metadata>,
        amount_in: u64, min_out: u64, deadline: u64,
    ) {
        assert_deadline(deadline);
        assert!(pool1_addr != pool2_addr
             && pool2_addr != pool3_addr
             && pool1_addr != pool3_addr, E_SAME_POOL);
        let addr = signer::address_of(swapper);
        let fa = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa = pool::swap(pool1_addr, addr, fa, 0);
        let fa = pool::swap(pool2_addr, addr, fa, 0);
        let fa = pool::swap(pool3_addr, addr, fa, min_out);
        primary_fungible_store::deposit(addr, fa);
    }

    /// 3-hop mixed: each hop can be plain or wrapped.
    public entry fun swap_3hop_mixed(
        swapper: &signer,
        pool1_addr: address, wrapped1: bool,
        pool2_addr: address, wrapped2: bool,
        pool3_addr: address, wrapped3: bool,
        metadata_in: Object<Metadata>,
        amount_in: u64, min_out: u64, deadline: u64,
    ) {
        assert_deadline(deadline);
        assert!(pool1_addr != pool2_addr
             && pool2_addr != pool3_addr
             && pool1_addr != pool3_addr, E_SAME_POOL);
        let addr = signer::address_of(swapper);
        let fa = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa = if (wrapped1) {
            hook_wrapper::swap(pool1_addr, addr, fa, 0)
        } else {
            pool::swap(pool1_addr, addr, fa, 0)
        };
        let fa = if (wrapped2) {
            hook_wrapper::swap(pool2_addr, addr, fa, 0)
        } else {
            pool::swap(pool2_addr, addr, fa, 0)
        };
        let fa = if (wrapped3) {
            hook_wrapper::swap(pool3_addr, addr, fa, min_out)
        } else {
            pool::swap(pool3_addr, addr, fa, min_out)
        };
        primary_fungible_store::deposit(addr, fa);
    }
}
