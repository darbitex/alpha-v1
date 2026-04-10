/// Darbitex Bridge — AMM bridge for pegged assets, FungibleAsset.
///
/// Uses constant-product (x*y=k) with depeg protection via MAX_IMBALANCE_PCT
/// (80%). Not a true StableSwap curve — the simple CPMM + imbalance cap is
/// sufficient for bridged asset pairs. A Curve-style A-parameter module
/// would be a future upgrade for ultra-low-slippage stable pairs.

module darbitex::bridge {
    use std::signer;
    use std::bcs;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::primary_fungible_store;

    use darbitex::lp_coin;
    use darbitex::pool; // for protocol admin check via protocol_config

    // ===== Constants =====
    const FEE_BPS: u64 = 1;
    const BPS_DENOM: u64 = 10_000;
    const MAX_IMBALANCE_PCT: u64 = 80;
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const BRIDGE_SEED: vector<u8> = b"darbitex_bridge";

    // ===== Errors =====
    const E_ZERO: u64 = 1;
    const E_IMBALANCED: u64 = 2;
    const E_PAUSED: u64 = 3;
    const E_SLIPPAGE: u64 = 4;
    const E_INSUFFICIENT_LP: u64 = 5;
    const E_INSUFFICIENT_RESERVE: u64 = 6;
    const E_WRONG_TOKEN: u64 = 7;
    const E_NOT_ADMIN: u64 = 8;
    const E_DISPROPORTIONAL: u64 = 9;
    const E_LOCKED: u64 = 10;

    // ===== Resources =====

    /// Bridge pool — unowned (no owner field); pause is protocol-admin only.
    struct BridgePool has key {
        metadata_from: Object<Metadata>,
        metadata_to: Object<Metadata>,
        extend_ref: ExtendRef,
        reserve_from: u64,
        reserve_to: u64,
        lp_supply: u64,
        total_bridged: u128,
        paused: bool,
        locked: bool,           // reentrancy guard
    }

    // ===== Events =====

    #[event]
    struct Bridged has drop, store {
        pool_addr: address, amount: u64, fee: u64, direction_from: bool,
    }

    #[event]
    struct BridgeLiquidityAdded has drop, store {
        provider: address, pool_addr: address,
        amount_from: u64, amount_to: u64, lp_minted: u64,
    }

    #[event]
    struct BridgeLiquidityRemoved has drop, store {
        provider: address, pool_addr: address,
        amount_from: u64, amount_to: u64, lp_burned: u64,
    }

    // ===== Internal =====

    fun derive_bridge_seed(
        metadata_from: Object<Metadata>, metadata_to: Object<Metadata>,
    ): vector<u8> {
        let seed = BRIDGE_SEED;
        vector::append(&mut seed, bcs::to_bytes(&object::object_address(&metadata_from)));
        vector::append(&mut seed, bcs::to_bytes(&object::object_address(&metadata_to)));
        seed
    }

    // ===== Create =====

    public entry fun create_bridge(
        creator: &signer,
        metadata_from: Object<Metadata>,
        metadata_to: Object<Metadata>,
        amount_from: u64,
        amount_to: u64,
    ) {
        let creator_addr = signer::address_of(creator);
        assert!(amount_from > 0 && amount_to > 0, E_ZERO);

        let seed = derive_bridge_seed(metadata_from, metadata_to);
        let constructor_ref = object::create_named_object(creator, seed);
        let bridge_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let pool_addr = signer::address_of(&bridge_signer);

        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        let fa_from = primary_fungible_store::withdraw(creator, metadata_from, amount_from);
        let fa_to = primary_fungible_store::withdraw(creator, metadata_to, amount_to);
        primary_fungible_store::deposit(pool_addr, fa_from);
        primary_fungible_store::deposit(pool_addr, fa_to);

        let lp_supply = amount_from + amount_to;
        assert!(lp_supply > MINIMUM_LIQUIDITY, E_ZERO);

        move_to(&bridge_signer, BridgePool {
            metadata_from, metadata_to, extend_ref,
            reserve_from: amount_from,
            reserve_to: amount_to,
            lp_supply,
            total_bridged: 0,
            paused: false,
            locked: false,
        });

        // Lock MINIMUM_LIQUIDITY as dead LP; rest goes to creator.
        lp_coin::mint(@darbitex, pool_addr, creator_addr, lp_supply - MINIMUM_LIQUIDITY);

        event::emit(BridgeLiquidityAdded {
            provider: creator_addr, pool_addr,
            amount_from, amount_to, lp_minted: lp_supply,
        });
    }

    // ===== Bridge =====

    public fun bridge(
        pool_addr: address,
        fa_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires BridgePool {
        let pool = borrow_global_mut<BridgePool>(pool_addr);
        assert!(!pool.paused, E_PAUSED);
        assert!(!pool.locked, E_LOCKED);
        pool.locked = true;

        let in_metadata = fungible_asset::asset_metadata(&fa_in);
        let amount_in = fungible_asset::amount(&fa_in);
        assert!(amount_in > 0, E_ZERO);

        let direction_from = if (in_metadata == pool.metadata_from) { true }
        else { assert!(in_metadata == pool.metadata_to, E_WRONG_TOKEN); false };

        let (reserve_in, reserve_out, metadata_out) = if (direction_from) {
            (pool.reserve_from, pool.reserve_to, pool.metadata_to)
        } else {
            (pool.reserve_to, pool.reserve_from, pool.metadata_from)
        };

        // Enforce a minimum fee of 1 so dust swaps still pay.
        let fee = amount_in * FEE_BPS / BPS_DENOM;
        let fee = if (fee == 0 && amount_in > 0) { 1 } else { fee };
        let input_after_fee = ((amount_in - fee) as u128);
        let amount_out = (input_after_fee * (reserve_out as u128) /
            ((reserve_in as u128) + input_after_fee) as u64);

        assert!(reserve_out >= amount_out, E_INSUFFICIENT_RESERVE);

        // Depeg guard: cap the heavier side at MAX_IMBALANCE_PCT of total.
        let reserve_in_after = reserve_in + amount_in;
        let total_after = reserve_in_after + reserve_out - amount_out;
        let in_pct = reserve_in_after * 100 / total_after;
        assert!(in_pct <= MAX_IMBALANCE_PCT, E_IMBALANCED);

        assert!(amount_out >= min_out, E_SLIPPAGE);

        primary_fungible_store::deposit(pool_addr, fa_in);
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa_out = primary_fungible_store::withdraw(&pool_signer, metadata_out, amount_out);

        if (direction_from) {
            pool.reserve_from = pool.reserve_from + amount_in;
            pool.reserve_to = pool.reserve_to - amount_out;
        } else {
            pool.reserve_to = pool.reserve_to + amount_in;
            pool.reserve_from = pool.reserve_from - amount_out;
        };

        pool.total_bridged = pool.total_bridged + (amount_in as u128);
        pool.locked = false;
        event::emit(Bridged { pool_addr, amount: amount_in, fee, direction_from });
        fa_out
    }

    public entry fun bridge_entry(
        user: &signer, pool_addr: address,
        metadata_in: Object<Metadata>, amount: u64, min_out: u64,
    ) acquires BridgePool {
        let fa_in = primary_fungible_store::withdraw(user, metadata_in, amount);
        let fa_out = bridge(pool_addr, fa_in, min_out);
        primary_fungible_store::deposit(signer::address_of(user), fa_out);
    }

    // ===== Liquidity =====

    /// Proportional LP minting (not a simple sum of amounts).
    public entry fun add_bridge_liquidity(
        provider: &signer, pool_addr: address,
        amount_from: u64, amount_to: u64,
    ) acquires BridgePool {
        let pool = borrow_global_mut<BridgePool>(pool_addr);
        assert!(!pool.paused, E_PAUSED);
        assert!(!pool.locked, E_LOCKED);
        assert!(amount_from > 0 && amount_to > 0, E_ZERO);

        // 5% tolerance on ratio; u128 comparison avoids overflow on extreme
        // ratios, and the addition form avoids u64 underflow when expected
        // is small.
        let expected_to = ((amount_from as u128) * (pool.reserve_to as u128) / (pool.reserve_from as u128) as u64);
        let tolerance = if (expected_to < 20) { 1 } else { expected_to / 20 };
        assert!((amount_to as u128) + (tolerance as u128) >= (expected_to as u128)
             && (amount_to as u128) <= (expected_to as u128) + (tolerance as u128), E_DISPROPORTIONAL);

        let lp_from = ((amount_from as u128) * (pool.lp_supply as u128) / (pool.reserve_from as u128) as u64);
        let lp_to = ((amount_to as u128) * (pool.lp_supply as u128) / (pool.reserve_to as u128) as u64);
        let lp_minted = if (lp_from < lp_to) { lp_from } else { lp_to };
        assert!(lp_minted > 0, E_ZERO);

        let provider_addr = signer::address_of(provider);
        let fa_from = primary_fungible_store::withdraw(provider, pool.metadata_from, amount_from);
        let fa_to = primary_fungible_store::withdraw(provider, pool.metadata_to, amount_to);
        primary_fungible_store::deposit(pool_addr, fa_from);
        primary_fungible_store::deposit(pool_addr, fa_to);

        pool.reserve_from = pool.reserve_from + amount_from;
        pool.reserve_to = pool.reserve_to + amount_to;
        pool.lp_supply = pool.lp_supply + lp_minted;
        lp_coin::mint(@darbitex, pool_addr, provider_addr, lp_minted);

        event::emit(BridgeLiquidityAdded {
            provider: provider_addr, pool_addr, amount_from, amount_to, lp_minted,
        });
    }

    public entry fun remove_bridge_liquidity(
        provider: &signer, pool_addr: address, lp_amount: u64,
    ) acquires BridgePool {
        assert!(lp_amount > 0, E_ZERO);
        let provider_addr = signer::address_of(provider);
        let lp_balance = lp_coin::balance(@darbitex, pool_addr, provider_addr);
        assert!(lp_balance >= lp_amount, E_INSUFFICIENT_LP);

        let pool = borrow_global_mut<BridgePool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        let amount_from = ((lp_amount as u128) * (pool.reserve_from as u128) / (pool.lp_supply as u128) as u64);
        let amount_to = ((lp_amount as u128) * (pool.reserve_to as u128) / (pool.lp_supply as u128) as u64);

        lp_coin::burn(@darbitex, pool_addr, provider_addr, lp_amount);
        pool.lp_supply = pool.lp_supply - lp_amount;
        assert!(pool.lp_supply >= MINIMUM_LIQUIDITY, E_INSUFFICIENT_LP);
        pool.reserve_from = pool.reserve_from - amount_from;
        pool.reserve_to = pool.reserve_to - amount_to;

        let ps = object::generate_signer_for_extending(&pool.extend_ref);
        let fa_from = primary_fungible_store::withdraw(&ps, pool.metadata_from, amount_from);
        let fa_to = primary_fungible_store::withdraw(&ps, pool.metadata_to, amount_to);
        primary_fungible_store::deposit(provider_addr, fa_from);
        primary_fungible_store::deposit(provider_addr, fa_to);

        event::emit(BridgeLiquidityRemoved {
            provider: provider_addr, pool_addr, amount_from, amount_to, lp_burned: lp_amount,
        });
    }

    // ===== Admin (protocol admin only) =====

    public entry fun pause_bridge(admin: &signer, pool_addr: address) acquires BridgePool {
        let (protocol_admin, _, _) = pool::protocol_config();
        assert!(signer::address_of(admin) == protocol_admin, E_NOT_ADMIN);
        borrow_global_mut<BridgePool>(pool_addr).paused = true;
    }

    public entry fun unpause_bridge(admin: &signer, pool_addr: address) acquires BridgePool {
        let (protocol_admin, _, _) = pool::protocol_config();
        assert!(signer::address_of(admin) == protocol_admin, E_NOT_ADMIN);
        borrow_global_mut<BridgePool>(pool_addr).paused = false;
    }

    // ===== Views =====

    #[view]
    public fun bridge_reserves(pool_addr: address): (u64, u64) acquires BridgePool {
        let p = borrow_global<BridgePool>(pool_addr);
        (p.reserve_from, p.reserve_to)
    }

    #[view]
    public fun bridge_info(pool_addr: address): (u64, u64, u64, bool) acquires BridgePool {
        let p = borrow_global<BridgePool>(pool_addr);
        (p.reserve_from, p.reserve_to, p.lp_supply, p.paused)
    }

    #[view]
    public fun bridge_tokens(pool_addr: address): (Object<Metadata>, Object<Metadata>) acquires BridgePool {
        let p = borrow_global<BridgePool>(pool_addr);
        (p.metadata_from, p.metadata_to)
    }
}
