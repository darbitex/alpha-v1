/// Darbitex Meta Router — auto-discovery multi-hop routing.
/// Given an input and output FA metadata, finds the best Darbitex path
/// (direct pool if it exists, or a 2-hop route via a bridge token) and
/// executes atomically. External aggregators can call the #[view]
/// best_route / quote_direct helpers to treat Darbitex as one venue
/// that always returns its best internal price.

module darbitex::meta_router {
    use std::signer;
    use std::bcs;
    use std::option;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;

    use darbitex::pool;
    use darbitex::pool_factory;

    // ===== Errors =====
    const E_DEADLINE: u64 = 1;
    const E_NO_ROUTE: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_SAME_TOKEN: u64 = 4;
    const E_SLIPPAGE: u64 = 5;

    // ===== Bridge token registry =====
    // Tokens that commonly appear in many Darbitex pairs and are therefore
    // useful as multi-hop intermediates. Hardcoded for determinism; callers
    // can always fall back to direct multi-hop via darbitex::router for
    // pairs that don't route through any of these.
    const APT_FA: address = @0xa;
    const LZ_USDC_FA: address = @0x2b3be0a97a73c87ff62cbdd36837a9fb5bbd1d7f06a73b7ed62ec15c5326c1b8;
    const N_USDC_FA: address = @0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b;

    // ===== Internal helpers =====

    fun md_eq(a: Object<Metadata>, b: Object<Metadata>): bool {
        object::object_address(&a) == object::object_address(&b)
    }

    fun sort_pair(a: Object<Metadata>, b: Object<Metadata>): (Object<Metadata>, Object<Metadata>) {
        let ba = bcs::to_bytes(&object::object_address(&a));
        let bb = bcs::to_bytes(&object::object_address(&b));
        if (ba < bb) { (a, b) } else { (b, a) }
    }

    /// Returns the canonical Darbitex pool address for (a, b) if it exists
    /// AND is not guarded by a hook, else @0x0. Hooked pools are filtered
    /// out because `meta_router` only calls `pool::swap` (plain path), and
    /// that path aborts `E_HOOK_REQUIRED` on any pool that has a hook
    /// attached. Callers who want hooked-pool routing should use
    /// `darbitex::router::swap_2hop_mixed` directly.
    ///
    /// Caller-safe: works regardless of the argument order.
    fun lookup_pool(a: Object<Metadata>, b: Object<Metadata>): address {
        if (md_eq(a, b)) return @0x0;
        let (sa, sb) = sort_pair(a, b);
        let addr = pool_factory::canonical_pool_address(sa, sb);
        if (!pool::pool_exists(addr)) return @0x0;
        let (hook, _) = pool::pool_hook(addr);
        if (option::is_some(&hook)) return @0x0;
        addr
    }

    /// Quote a single swap through `pool_addr`. Resolves `a_to_b` from the
    /// pool's actual token ordering so the caller doesn't need to sort.
    fun quote_hop(pool_addr: address, md_in: Object<Metadata>, amount_in: u64): u64 {
        if (pool_addr == @0x0 || amount_in == 0) return 0;
        let (md_a, _md_b) = pool::pool_tokens(pool_addr);
        let a_to_b = md_eq(md_in, md_a);
        pool::get_amount_out(pool_addr, amount_in, a_to_b)
    }

    fun bridge_list(): vector<address> {
        let v = vector::empty<address>();
        vector::push_back(&mut v, APT_FA);
        vector::push_back(&mut v, LZ_USDC_FA);
        vector::push_back(&mut v, N_USDC_FA);
        v
    }

    // ===== View: best_route =====

    #[view]
    /// Enumerate direct and 2-hop (via bridge token) routes for
    /// `md_in -> md_out` and return the one that yields the highest output.
    /// Result: (pool1_addr, pool2_addr, expected_out). If no route exists,
    /// both pool addresses are @0x0 and expected_out is 0. If the best
    /// route is direct, pool2_addr is @0x0.
    public fun best_route(
        md_in: Object<Metadata>,
        md_out: Object<Metadata>,
        amount_in: u64,
    ): (address, address, u64) {
        if (md_eq(md_in, md_out) || amount_in == 0) {
            return (@0x0, @0x0, 0)
        };

        let best_p1 = @0x0;
        let best_p2 = @0x0;
        let best_out = 0u64;

        // Direct
        let direct = lookup_pool(md_in, md_out);
        if (direct != @0x0) {
            let out = quote_hop(direct, md_in, amount_in);
            if (out > best_out) {
                best_p1 = direct;
                best_p2 = @0x0;
                best_out = out;
            }
        };

        // 2-hop via each bridge (skip bridges whose metadata object does not
        // exist on this chain state — keeps the view function abort-free on
        // fresh networks or after an asset is unexpectedly deleted).
        let bridges = bridge_list();
        let i = 0;
        let n = vector::length(&bridges);
        while (i < n) {
            let bridge_addr = *vector::borrow(&bridges, i);
            if (object::object_exists<Metadata>(bridge_addr)) {
                let bridge_md = object::address_to_object<Metadata>(bridge_addr);
                if (!md_eq(bridge_md, md_in) && !md_eq(bridge_md, md_out)) {
                    let p1 = lookup_pool(md_in, bridge_md);
                    let p2 = lookup_pool(bridge_md, md_out);
                    if (p1 != @0x0 && p2 != @0x0 && p1 != p2) {
                        let mid_out = quote_hop(p1, md_in, amount_in);
                        if (mid_out > 0) {
                            let final_out = quote_hop(p2, bridge_md, mid_out);
                            if (final_out > best_out) {
                                best_p1 = p1;
                                best_p2 = p2;
                                best_out = final_out;
                            }
                        }
                    }
                }
            };
            i = i + 1;
        };

        (best_p1, best_p2, best_out)
    }

    #[view]
    /// Direct-pool quote. Returns 0 if no canonical pool exists for the pair.
    /// Useful for external aggregators that only want to treat Darbitex as a
    /// single-hop venue and handle their own routing across venues.
    public fun quote_direct(
        md_in: Object<Metadata>,
        md_out: Object<Metadata>,
        amount_in: u64,
    ): u64 {
        let direct = lookup_pool(md_in, md_out);
        quote_hop(direct, md_in, amount_in)
    }

    // ===== Entry: swap_best =====

    /// Execute the best available Darbitex route from `md_in` to `md_out`.
    /// Picks direct or 2-hop via bridge token automatically and enforces
    /// slippage against `min_out` on the final output only.
    public entry fun swap_best(
        swapper: &signer,
        md_in: Object<Metadata>,
        md_out: Object<Metadata>,
        amount_in: u64,
        min_out: u64,
        deadline: u64,
    ) {
        assert!(timestamp::now_seconds() < deadline, E_DEADLINE);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(!md_eq(md_in, md_out), E_SAME_TOKEN);

        let (p1, p2, expected) = best_route(md_in, md_out, amount_in);
        assert!(p1 != @0x0, E_NO_ROUTE);
        assert!(expected >= min_out, E_SLIPPAGE);

        let addr = signer::address_of(swapper);
        let fa_in = primary_fungible_store::withdraw(swapper, md_in, amount_in);

        if (p2 == @0x0) {
            let fa_out = pool::swap(p1, addr, fa_in, min_out);
            primary_fungible_store::deposit(addr, fa_out);
        } else {
            let fa_mid = pool::swap(p1, addr, fa_in, 0);
            let fa_out = pool::swap(p2, addr, fa_mid, min_out);
            primary_fungible_store::deposit(addr, fa_out);
        }
    }
}
