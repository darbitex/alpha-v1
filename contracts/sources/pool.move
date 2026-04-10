/// Darbitex Pool — AMM with permissionless hooks, FungibleAsset.
///
/// Fee (FIXED): 0.01% total. LP 0.009%. Remaining 0.001%:
///   Plain -> 100% protocol. Hooked -> 50% hook + 50% protocol.
///
/// Pools UNOWNED. Created via pool_factory. Hook via auction.

module darbitex::pool {
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_std::type_info;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::primary_fungible_store;

    use darbitex::lp_coin;

    /// Hardcoded admin + treasury. Changing these requires a package upgrade.
    const ADMIN: address = @0xf1b522effb90aef79395f97b9c39d6acbd8fdf84ec046361359a48de2e196566;
    const TREASURY: address = @0xdbce89113a975826028236f910668c3ff99c8db8981be6a448caa2f8836f9576;

    // ===== Constants =====
    const SWAP_FEE_BPS: u64 = 1;
    const BPS_DENOM: u64 = 10_000;
    const EXTRA_FEE_DENOM: u64 = 100_000;
    const HOOK_SPLIT_PCT: u64 = 50;
    const MINIMUM_LIQUIDITY: u64 = 1000;

    // ===== Errors =====
    const E_ZERO_AMOUNT: u64 = 1;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 2;
    const E_SLIPPAGE: u64 = 3;
    const E_NOT_ADMIN: u64 = 4;
    const E_NOT_FACTORY: u64 = 5;
    const E_K_VIOLATED: u64 = 6;
    const E_LOCKED: u64 = 7;
    const E_PAUSED: u64 = 8;
    const E_DISPROPORTIONAL: u64 = 9;
    const E_WRONG_POOL: u64 = 10;
    const E_INSUFFICIENT_LP: u64 = 11;
    const E_WRONG_TOKEN: u64 = 12;
    const E_HOOK_REQUIRED: u64 = 13;
    const E_HOOK_ALREADY_CLAIMED: u64 = 14;
    const E_WRONG_HOOK: u64 = 15;
    const E_NO_HOOK: u64 = 16;
    const E_NO_FEE: u64 = 17;
    const E_ALREADY_INIT: u64 = 18;
    const E_NOT_INIT: u64 = 19;

    // ===== Protocol Config =====

    struct ProtocolConfig has key {
        factory_addr: address,
    }

    // ===== Hook Capability =====

    struct HookCap has store {
        pool_addr: address,
        hook_addr: address,
    }

    // ===== Pool =====

    struct Pool has key {
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
        extend_ref: ExtendRef,
        // Internal reserve tracking (decoupled from store balance so flash
        // loans and stray transfers cannot corrupt invariants).
        reserve_a: u64,
        reserve_b: u64,
        locked: bool,      // reentrancy guard (swap + flash)
        paused: bool,
        lp_supply: u64,
        total_swaps: u64,
        total_volume_a: u128,
        total_volume_b: u128,
        last_price_a_cumulative: u128,
        last_price_b_cumulative: u128,
        last_block_timestamp: u64,
        hook_addr: Option<address>,
        hook_claimed: bool,
        hook_fee_a: u64,
        hook_fee_b: u64,
        protocol_fee_a: u64,
        protocol_fee_b: u64,
    }

    struct FlashReceipt {
        pool_addr: address,
        k_before_hi: u128,
        k_before_lo: u128,
        borrowed_a: bool,
        borrow_amount: u64,
        store_before: u64,
    }

    // ===== Events =====

    #[event]
    struct PoolCreated has drop, store {
        pool_addr: address, metadata_a: address, metadata_b: address,
    }

    #[event]
    struct HookSet has drop, store { pool_addr: address, hook_addr: address }

    #[event]
    struct HookClaimed has drop, store { pool_addr: address, hook_addr: address }

    #[event]
    struct HookRemoved has drop, store { pool_addr: address, old_hook: address }

    #[event]
    struct Swapped has drop, store {
        swapper: address, pool_addr: address,
        amount_in: u64, amount_out: u64, a_to_b: bool,
        lp_fee: u64, hook_fee: u64, protocol_fee: u64,
        timestamp: u64,
    }

    #[event]
    struct LiquidityAdded has drop, store {
        provider: address, pool_addr: address,
        amount_a: u64, amount_b: u64, lp_minted: u64,
    }

    #[event]
    struct LiquidityRemoved has drop, store {
        provider: address, pool_addr: address,
        amount_a: u64, amount_b: u64, lp_burned: u64,
    }

    #[event]
    struct FlashBorrowed has drop, store {
        borrower: address, pool_addr: address, amount: u64,
    }

    #[event]
    struct FeeWithdrawn has drop, store {
        pool_addr: address, recipient: address,
        amount_a: u64, amount_b: u64, fee_type: u8,
    }

    #[event]
    struct PoolPaused has drop, store { pool_addr: address, paused: bool }

    // ===== Math =====

    fun mul_u128(a: u128, b: u128): (u128, u128) {
        let a_lo = a & 0xFFFFFFFFFFFFFFFF;
        let a_hi = a >> 64;
        let b_lo = b & 0xFFFFFFFFFFFFFFFF;
        let b_hi = b >> 64;
        let lo_lo = a_lo * b_lo;
        let lo_hi = a_lo * b_hi;
        let hi_lo = a_hi * b_lo;
        let hi_hi = a_hi * b_hi;
        let mid = lo_hi + hi_lo + (lo_lo >> 64);
        let lo = (lo_lo & 0xFFFFFFFFFFFFFFFF) | ((mid & 0xFFFFFFFFFFFFFFFF) << 64);
        let hi = hi_hi + (mid >> 64);
        (hi, lo)
    }

    /// Strict greater-than on u256 halves — used for flash-loan fee enforcement.
    fun gt_u256(a_hi: u128, a_lo: u128, b_hi: u128, b_lo: u128): bool {
        if (a_hi > b_hi) return true;
        if (a_hi < b_hi) return false;
        a_lo > b_lo
    }

    fun sqrt(x: u128): u64 {
        if (x == 0) return 0;
        let z = x;
        let y = (z + 1) / 2;
        while (y < z) { z = y; y = (x / y + y) / 2; };
        (z as u64)
    }

    // ===== Internal =====

    fun assert_admin(account: &signer) {
        assert!(signer::address_of(account) == ADMIN, E_NOT_ADMIN);
    }

    fun assert_factory(account: &signer) acquires ProtocolConfig {
        assert!(exists<ProtocolConfig>(@darbitex), E_NOT_INIT);
        let c = borrow_global<ProtocolConfig>(@darbitex);
        assert!(signer::address_of(account) == c.factory_addr, E_NOT_FACTORY);
    }

    fun assert_valid_cap(pool: &Pool, cap: &HookCap) {
        assert!(option::is_some(&pool.hook_addr), E_NO_HOOK);
        assert!(*option::borrow(&pool.hook_addr) == cap.hook_addr, E_WRONG_HOOK);
    }

    // ===== Protocol Config =====

    public entry fun init_protocol(deployer: &signer, factory_addr: address) {
        let addr = signer::address_of(deployer);
        assert!(addr == @darbitex, E_NOT_ADMIN);
        assert!(!exists<ProtocolConfig>(@darbitex), E_ALREADY_INIT);
        move_to(deployer, ProtocolConfig { factory_addr });
    }

    // ===== Pool Creation (factory only) =====

    public fun create_pool(
        factory_signer: &signer,
        constructor_ref: &object::ConstructorRef,
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
        amount_a: u64,
        amount_b: u64,
    ) acquires ProtocolConfig {
        assert_factory(factory_signer);
        assert!(amount_a > 0 && amount_b > 0, E_ZERO_AMOUNT);

        let pool_signer = object::generate_signer(constructor_ref);
        let extend_ref = object::generate_extend_ref(constructor_ref);
        let pool_address = signer::address_of(&pool_signer);

        let transfer_ref = object::generate_transfer_ref(constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        let fa_a = primary_fungible_store::withdraw(factory_signer, metadata_a, amount_a);
        let fa_b = primary_fungible_store::withdraw(factory_signer, metadata_b, amount_b);
        primary_fungible_store::deposit(pool_address, fa_a);
        primary_fungible_store::deposit(pool_address, fa_b);

        let initial_lp = sqrt((amount_a as u128) * (amount_b as u128));
        assert!(initial_lp > MINIMUM_LIQUIDITY, E_INSUFFICIENT_LIQUIDITY);

        move_to(&pool_signer, Pool {
            metadata_a, metadata_b, extend_ref,
            reserve_a: amount_a,
            reserve_b: amount_b,
            locked: false, paused: false,
            lp_supply: initial_lp,
            total_swaps: 0, total_volume_a: 0, total_volume_b: 0,
            last_price_a_cumulative: 0, last_price_b_cumulative: 0,
            last_block_timestamp: timestamp::now_seconds(),
            hook_addr: option::none(), hook_claimed: false,
            hook_fee_a: 0, hook_fee_b: 0, protocol_fee_a: 0, protocol_fee_b: 0,
        });

        event::emit(PoolCreated {
            pool_addr: pool_address,
            metadata_a: object::object_address(&metadata_a),
            metadata_b: object::object_address(&metadata_b),
        });

        // LP to factory — factory forwards it to the creator.
        lp_coin::mint(@darbitex, pool_address, signer::address_of(factory_signer), initial_lp - MINIMUM_LIQUIDITY);
    }

    public fun set_hook(
        factory_signer: &signer, pool_addr: address, hook_addr: address,
    ) acquires ProtocolConfig, Pool {
        assert_factory(factory_signer);
        let pool = borrow_global_mut<Pool>(pool_addr);
        pool.hook_addr = option::some(hook_addr);
        pool.hook_claimed = false;
        event::emit(HookSet { pool_addr, hook_addr });
    }

    public fun remove_hook(
        factory_signer: &signer, pool_addr: address,
    ) acquires ProtocolConfig, Pool {
        assert_factory(factory_signer);
        let pool = borrow_global_mut<Pool>(pool_addr);
        pool.protocol_fee_a = pool.protocol_fee_a + pool.hook_fee_a;
        pool.protocol_fee_b = pool.protocol_fee_b + pool.hook_fee_b;
        pool.hook_fee_a = 0;
        pool.hook_fee_b = 0;
        let old_hook = *option::borrow(&pool.hook_addr);
        pool.hook_addr = option::none();
        pool.hook_claimed = false;
        event::emit(HookRemoved { pool_addr, old_hook });
    }

    // ===== Hook Registration =====

    public fun claim_hook_cap<W: drop>(pool_addr: address, _witness: W): HookCap acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(option::is_some(&pool.hook_addr), E_NO_HOOK);
        assert!(!pool.hook_claimed, E_HOOK_ALREADY_CLAIMED);
        let witness_addr = type_info::account_address(&type_info::type_of<W>());
        assert!(witness_addr == *option::borrow(&pool.hook_addr), E_WRONG_HOOK);
        pool.hook_claimed = true;
        event::emit(HookClaimed { pool_addr, hook_addr: witness_addr });
        HookCap { pool_addr, hook_addr: witness_addr }
    }

    public fun hook_cap_pool(cap: &HookCap): address { cap.pool_addr }
    public fun hook_cap_addr(cap: &HookCap): address { cap.hook_addr }

    public fun destroy_hook_cap(cap: HookCap) {
        let HookCap { pool_addr: _, hook_addr: _ } = cap;
    }

    // ===== Fee Withdrawal =====

    public fun withdraw_hook_fee(
        pool_addr: address, recipient: address, cap: &HookCap,
    ) acquires Pool {
        assert!(cap.pool_addr == pool_addr, E_WRONG_POOL);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        assert_valid_cap(pool, cap);
        let fa = pool.hook_fee_a;
        let fb = pool.hook_fee_b;
        assert!(fa > 0 || fb > 0, E_NO_FEE);
        let ps = object::generate_signer_for_extending(&pool.extend_ref);
        if (fa > 0) {
            primary_fungible_store::deposit(recipient,
                primary_fungible_store::withdraw(&ps, pool.metadata_a, fa));
            pool.hook_fee_a = 0;
        };
        if (fb > 0) {
            primary_fungible_store::deposit(recipient,
                primary_fungible_store::withdraw(&ps, pool.metadata_b, fb));
            pool.hook_fee_b = 0;
        };
        event::emit(FeeWithdrawn { pool_addr, recipient, amount_a: fa, amount_b: fb, fee_type: 1 });
    }

    public entry fun withdraw_protocol_fee(
        admin: &signer, pool_addr: address,
    ) acquires Pool {
        assert_admin(admin);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        let fa = pool.protocol_fee_a;
        let fb = pool.protocol_fee_b;
        assert!(fa > 0 || fb > 0, E_NO_FEE);
        let ps = object::generate_signer_for_extending(&pool.extend_ref);
        if (fa > 0) {
            primary_fungible_store::deposit(TREASURY,
                primary_fungible_store::withdraw(&ps, pool.metadata_a, fa));
            pool.protocol_fee_a = 0;
        };
        if (fb > 0) {
            primary_fungible_store::deposit(TREASURY,
                primary_fungible_store::withdraw(&ps, pool.metadata_b, fb));
            pool.protocol_fee_b = 0;
        };
        event::emit(FeeWithdrawn { pool_addr, recipient: TREASURY, amount_a: fa, amount_b: fb, fee_type: 0 });
    }

    // ===== TWAP =====

    fun update_twap(pool: &mut Pool) {
        let now = timestamp::now_seconds();
        let elapsed = now - pool.last_block_timestamp;
        if (elapsed > 0 && pool.reserve_a > 0 && pool.reserve_b > 0) {
            let delta_a = (pool.reserve_b as u128) * (elapsed as u128) / (pool.reserve_a as u128);
            let delta_b = (pool.reserve_a as u128) * (elapsed as u128) / (pool.reserve_b as u128);
            let max_u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFu128;
            if (delta_a <= max_u128 - pool.last_price_a_cumulative) {
                pool.last_price_a_cumulative = pool.last_price_a_cumulative + delta_a;
            };
            if (delta_b <= max_u128 - pool.last_price_b_cumulative) {
                pool.last_price_b_cumulative = pool.last_price_b_cumulative + delta_b;
            };
            pool.last_block_timestamp = now;
        };
    }

    // ===== Swap Internal =====

    fun swap_internal(
        pool: &mut Pool,
        pool_addr: address,
        swapper: address,
        fa_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset {
        assert!(!pool.paused, E_PAUSED);
        assert!(!pool.locked, E_LOCKED);
        pool.locked = true;

        let in_metadata = fungible_asset::asset_metadata(&fa_in);
        let amount_in = fungible_asset::amount(&fa_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let a_to_b = if (in_metadata == pool.metadata_a) { true }
        else { assert!(in_metadata == pool.metadata_b, E_WRONG_TOKEN); false };

        let (reserve_in, reserve_out) = if (a_to_b) {
            (pool.reserve_a, pool.reserve_b)
        } else {
            (pool.reserve_b, pool.reserve_a)
        };

        let amount_in_with_fee = (amount_in as u128) * ((BPS_DENOM - SWAP_FEE_BPS) as u128);
        let numerator = amount_in_with_fee * (reserve_out as u128);
        let denominator = (reserve_in as u128) * (BPS_DENOM as u128) + amount_in_with_fee;
        let amount_out = ((numerator / denominator) as u64);

        assert!(amount_out >= min_out, E_SLIPPAGE);
        assert!(amount_out < reserve_out, E_INSUFFICIENT_LIQUIDITY);

        primary_fungible_store::deposit(pool_addr, fa_in);
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let metadata_out = if (a_to_b) { pool.metadata_b } else { pool.metadata_a };
        let fa_out = primary_fungible_store::withdraw(&pool_signer, metadata_out, amount_out);

        // Min extra_fee of 1 prevents zero-fee dust swaps.
        let extra_fee = amount_in / EXTRA_FEE_DENOM;
        let extra_fee = if (extra_fee == 0 && amount_in > 0) { 1 } else { extra_fee };
        let (hook_fee, protocol_fee) = if (option::is_some(&pool.hook_addr)) {
            let hs = extra_fee * HOOK_SPLIT_PCT / 100;
            let ps = extra_fee - hs;
            if (a_to_b) {
                pool.hook_fee_a = pool.hook_fee_a + hs;
                pool.protocol_fee_a = pool.protocol_fee_a + ps;
            } else {
                pool.hook_fee_b = pool.hook_fee_b + hs;
                pool.protocol_fee_b = pool.protocol_fee_b + ps;
            };
            (hs, ps)
        } else {
            if (a_to_b) { pool.protocol_fee_a = pool.protocol_fee_a + extra_fee; }
            else { pool.protocol_fee_b = pool.protocol_fee_b + extra_fee; };
            (0, extra_fee)
        };

        // total_fee floors to 0 for amount_in < 10_000 while extra_fee is
        // already floor-protected to 1, so a naive subtraction would
        // underflow. Saturate to 0 instead — lp_fee is only consumed by the
        // Swapped event, so the substitution is cosmetic.
        let total_fee = amount_in * SWAP_FEE_BPS / BPS_DENOM;
        let lp_fee = if (total_fee > hook_fee + protocol_fee) {
            total_fee - hook_fee - protocol_fee
        } else { 0 };

        // TWAP must accrue the prior interval at the pre-swap reserve ratio,
        // so update it before mutating reserves.
        update_twap(pool);

        // Internal reserves exclude accumulated fees.
        if (a_to_b) {
            pool.reserve_a = pool.reserve_a + amount_in - extra_fee;
            pool.reserve_b = pool.reserve_b - amount_out;
        } else {
            pool.reserve_a = pool.reserve_a - amount_out;
            pool.reserve_b = pool.reserve_b + amount_in - extra_fee;
        };

        pool.total_swaps = pool.total_swaps + 1;
        if (a_to_b) { pool.total_volume_a = pool.total_volume_a + (amount_in as u128); }
        else { pool.total_volume_b = pool.total_volume_b + (amount_in as u128); };

        pool.locked = false;

        event::emit(Swapped {
            swapper, pool_addr,
            amount_in, amount_out, a_to_b,
            lp_fee, hook_fee, protocol_fee,
            timestamp: timestamp::now_seconds(),
        });

        fa_out
    }

    // ===== Swap Public API =====

    public fun swap(
        pool_addr: address, swapper: address,
        fa_in: FungibleAsset, min_out: u64,
    ): FungibleAsset acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(option::is_none(&pool.hook_addr), E_HOOK_REQUIRED);
        swap_internal(pool, pool_addr, swapper, fa_in, min_out)
    }

    public fun swap_hooked(
        pool_addr: address, swapper: address,
        fa_in: FungibleAsset, min_out: u64, cap: &HookCap,
    ): FungibleAsset acquires Pool {
        assert!(cap.pool_addr == pool_addr, E_WRONG_POOL);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert_valid_cap(pool, cap);
        swap_internal(pool, pool_addr, swapper, fa_in, min_out)
    }

    public entry fun swap_entry(
        swapper: &signer, pool_addr: address,
        metadata_in: Object<Metadata>, amount_in: u64, min_out: u64,
    ) acquires Pool {
        let addr = signer::address_of(swapper);
        let fa_in = primary_fungible_store::withdraw(swapper, metadata_in, amount_in);
        let fa_out = swap(pool_addr, addr, fa_in, min_out);
        primary_fungible_store::deposit(addr, fa_out);
    }

    // ===== Liquidity Internal =====

    fun add_liquidity_internal(
        pool: &mut Pool, pool_addr: address,
        provider: &signer, amount_a: u64, amount_b: u64,
    ) {
        assert!(!pool.paused, E_PAUSED);
        assert!(!pool.locked, E_LOCKED);
        update_twap(pool);

        let expected_b = ((amount_a as u128) * (pool.reserve_b as u128) / (pool.reserve_a as u128) as u64);
        // Tolerance in u128 space to avoid u64 overflow on extreme ratios;
        // min tolerance of 1 handles very small expected_b.
        let tolerance = if (expected_b < 20) { 1 } else { expected_b / 20 };
        assert!((amount_b as u128) + (tolerance as u128) >= (expected_b as u128)
             && (amount_b as u128) <= (expected_b as u128) + (tolerance as u128), E_DISPROPORTIONAL);

        let lp_a = ((amount_a as u128) * (pool.lp_supply as u128) / (pool.reserve_a as u128) as u64);
        let lp_b = ((amount_b as u128) * (pool.lp_supply as u128) / (pool.reserve_b as u128) as u64);
        let lp_minted = if (lp_a < lp_b) { lp_a } else { lp_b };
        assert!(lp_minted > 0, E_ZERO_AMOUNT);

        let provider_addr = signer::address_of(provider);
        let fa_a = primary_fungible_store::withdraw(provider, pool.metadata_a, amount_a);
        let fa_b = primary_fungible_store::withdraw(provider, pool.metadata_b, amount_b);
        primary_fungible_store::deposit(pool_addr, fa_a);
        primary_fungible_store::deposit(pool_addr, fa_b);

        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        pool.lp_supply = pool.lp_supply + lp_minted;
        lp_coin::mint(@darbitex, pool_addr, provider_addr, lp_minted);

        event::emit(LiquidityAdded { provider: provider_addr, pool_addr, amount_a, amount_b, lp_minted });
    }

    /// Remove liquidity. Intentionally allowed during pause so users can
    /// exit in an emergency. Blocked only during an active flash loan.
    fun remove_liquidity_internal(
        pool: &mut Pool, pool_addr: address,
        provider: &signer, lp_amount: u64,
    ) {
        assert!(!pool.locked, E_LOCKED);
        update_twap(pool);
        assert!(lp_amount > 0, E_ZERO_AMOUNT);
        let provider_addr = signer::address_of(provider);
        let lp_balance = lp_coin::balance(@darbitex, pool_addr, provider_addr);
        assert!(lp_balance >= lp_amount, E_INSUFFICIENT_LP);

        let amount_a = ((lp_amount as u128) * (pool.reserve_a as u128) / (pool.lp_supply as u128) as u64);
        let amount_b = ((lp_amount as u128) * (pool.reserve_b as u128) / (pool.lp_supply as u128) as u64);

        lp_coin::burn(@darbitex, pool_addr, provider_addr, lp_amount);
        pool.lp_supply = pool.lp_supply - lp_amount;
        assert!(pool.lp_supply >= MINIMUM_LIQUIDITY, E_INSUFFICIENT_LIQUIDITY);
        pool.reserve_a = pool.reserve_a - amount_a;
        pool.reserve_b = pool.reserve_b - amount_b;

        let ps = object::generate_signer_for_extending(&pool.extend_ref);
        let fa_a = primary_fungible_store::withdraw(&ps, pool.metadata_a, amount_a);
        let fa_b = primary_fungible_store::withdraw(&ps, pool.metadata_b, amount_b);
        primary_fungible_store::deposit(provider_addr, fa_a);
        primary_fungible_store::deposit(provider_addr, fa_b);

        event::emit(LiquidityRemoved { provider: provider_addr, pool_addr, amount_a, amount_b, lp_burned: lp_amount });
    }

    // ===== Liquidity Public API =====

    public entry fun add_liquidity(
        provider: &signer, pool_addr: address, amount_a: u64, amount_b: u64,
    ) acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(option::is_none(&pool.hook_addr), E_HOOK_REQUIRED);
        add_liquidity_internal(pool, pool_addr, provider, amount_a, amount_b);
    }

    public fun add_liquidity_hooked(
        provider: &signer, pool_addr: address,
        amount_a: u64, amount_b: u64, cap: &HookCap,
    ) acquires Pool {
        assert!(cap.pool_addr == pool_addr, E_WRONG_POOL);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert_valid_cap(pool, cap);
        add_liquidity_internal(pool, pool_addr, provider, amount_a, amount_b);
    }

    public entry fun remove_liquidity(
        provider: &signer, pool_addr: address, lp_amount: u64,
    ) acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(option::is_none(&pool.hook_addr), E_HOOK_REQUIRED);
        remove_liquidity_internal(pool, pool_addr, provider, lp_amount);
    }

    public fun remove_liquidity_hooked(
        provider: &signer, pool_addr: address, lp_amount: u64, cap: &HookCap,
    ) acquires Pool {
        assert!(cap.pool_addr == pool_addr, E_WRONG_POOL);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert_valid_cap(pool, cap);
        remove_liquidity_internal(pool, pool_addr, provider, lp_amount);
    }

    // ===== Flash Loan =====
    // Flash loans ONLY on hooked pools (via HookCap or hook_wrapper).
    // Plain pools have no flash loans. Strict k increase is enforced.

    public fun flash_borrow_hooked(
        pool_addr: address, borrower: address,
        metadata: Object<Metadata>, amount: u64,
        cap: &HookCap,
    ): (FungibleAsset, FlashReceipt) acquires Pool {
        assert!(cap.pool_addr == pool_addr, E_WRONG_POOL);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.paused, E_PAUSED);
        assert!(!pool.locked, E_LOCKED);
        assert_valid_cap(pool, cap);

        // Metadata must be one of pool's tokens — prevents stray token theft.
        let borrowed_a = if (metadata == pool.metadata_a) { true }
        else { assert!(metadata == pool.metadata_b, E_WRONG_TOKEN); false };

        // Snapshot store balance before borrow for same-token fee enforcement.
        let store_before = primary_fungible_store::balance(pool_addr, metadata);

        pool.locked = true;

        let (k_hi, k_lo) = mul_u128((pool.reserve_a as u128), (pool.reserve_b as u128));

        let ps = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = primary_fungible_store::withdraw(&ps, metadata, amount);

        event::emit(FlashBorrowed { borrower, pool_addr, amount });
        (fa, FlashReceipt {
            pool_addr, k_before_hi: k_hi, k_before_lo: k_lo,
            borrowed_a, borrow_amount: amount, store_before,
        })
    }

    /// Strict k increase + same-token fee enforcement: the borrowed token
    /// must be repaid in the same token plus fee, so no zero-fee borrow-A/
    /// repay-B swaps are possible.
    public fun flash_repay(pool_addr: address, receipt: FlashReceipt) acquires Pool {
        let FlashReceipt {
            pool_addr: rp, k_before_hi, k_before_lo,
            borrowed_a, borrow_amount, store_before,
        } = receipt;
        assert!(pool_addr == rp, E_WRONG_POOL);

        let pool = borrow_global_mut<Pool>(pool_addr);

        let calc_fee = borrow_amount * SWAP_FEE_BPS / BPS_DENOM;
        let min_fee = if (calc_fee == 0 && borrow_amount > 0) { 1 } else { calc_fee };
        let metadata_borrowed = if (borrowed_a) { pool.metadata_a } else { pool.metadata_b };
        let store_now = primary_fungible_store::balance(pool_addr, metadata_borrowed);
        assert!(store_now >= store_before + min_fee, E_K_VIOLATED);

        // Sync reserves from store — flash loan may have shifted balances.
        let store_a = primary_fungible_store::balance(pool_addr, pool.metadata_a);
        let store_b = primary_fungible_store::balance(pool_addr, pool.metadata_b);
        pool.reserve_a = store_a - pool.hook_fee_a - pool.protocol_fee_a;
        pool.reserve_b = store_b - pool.hook_fee_b - pool.protocol_fee_b;

        let (k_hi, k_lo) = mul_u128((pool.reserve_a as u128), (pool.reserve_b as u128));
        assert!(gt_u256(k_hi, k_lo, k_before_hi, k_before_lo), E_K_VIOLATED);

        pool.locked = false;
    }

    // ===== Admin Hook Recovery =====

    /// Force-remove an unclaimed hook. Rescues stuck pools where hook_addr
    /// is invalid or the hook module never claimed. Only works while the
    /// hook is still unclaimed.
    public entry fun admin_force_remove_hook(
        admin: &signer, pool_addr: address,
    ) acquires Pool {
        assert_admin(admin);
        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(option::is_some(&pool.hook_addr), E_NO_HOOK);
        assert!(!pool.hook_claimed, E_HOOK_ALREADY_CLAIMED);
        pool.protocol_fee_a = pool.protocol_fee_a + pool.hook_fee_a;
        pool.protocol_fee_b = pool.protocol_fee_b + pool.hook_fee_b;
        pool.hook_fee_a = 0;
        pool.hook_fee_b = 0;
        let old_hook = *option::borrow(&pool.hook_addr);
        pool.hook_addr = option::none();
        pool.hook_claimed = false;
        event::emit(HookRemoved { pool_addr, old_hook });
    }

    // ===== Emergency Pause (admin only) =====

    public entry fun pause(admin: &signer, pool_addr: address) acquires Pool {
        assert_admin(admin);
        borrow_global_mut<Pool>(pool_addr).paused = true;
        event::emit(PoolPaused { pool_addr, paused: true });
    }

    public entry fun unpause(admin: &signer, pool_addr: address) acquires Pool {
        assert_admin(admin);
        borrow_global_mut<Pool>(pool_addr).paused = false;
        event::emit(PoolPaused { pool_addr, paused: false });
    }

    // ===== Views =====

    #[view]
    public fun reserves(pool_addr: address): (u64, u64) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        (p.reserve_a, p.reserve_b)
    }

    #[view]
    public fun get_amount_out(pool_addr: address, amount_in: u64, a_to_b: bool): u64 acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        let (ri, ro) = if (a_to_b) { (p.reserve_a, p.reserve_b) } else { (p.reserve_b, p.reserve_a) };
        let aiwf = (amount_in as u128) * ((BPS_DENOM - SWAP_FEE_BPS) as u128);
        ((aiwf * (ro as u128) / ((ri as u128) * (BPS_DENOM as u128) + aiwf)) as u64)
    }

    #[view]
    public fun pool_info(pool_addr: address): (u64, u64, u64, bool) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        (p.reserve_a, p.reserve_b, p.lp_supply, p.paused)
    }

    #[view]
    public fun pool_tokens(pool_addr: address): (Object<Metadata>, Object<Metadata>) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        (p.metadata_a, p.metadata_b)
    }

    #[view]
    public fun twap(pool_addr: address): (u128, u128, u64) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        (p.last_price_a_cumulative, p.last_price_b_cumulative, p.last_block_timestamp)
    }

    #[view]
    public fun pool_hook(pool_addr: address): (Option<address>, bool) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        (p.hook_addr, p.hook_claimed)
    }

    #[view]
    public fun pending_fees(pool_addr: address): (u64, u64, u64, u64) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        (p.hook_fee_a, p.hook_fee_b, p.protocol_fee_a, p.protocol_fee_b)
    }

    #[view]
    public fun fee_info(pool_addr: address): (u64, u64, u64, u64) acquires Pool {
        let p = borrow_global<Pool>(pool_addr);
        if (option::is_some(&p.hook_addr)) {
            (SWAP_FEE_BPS, 90, 5, 5)
        } else {
            (SWAP_FEE_BPS, 90, 0, 10)
        }
    }

    #[view]
    public fun protocol_config(): (address, address, address) acquires ProtocolConfig {
        let c = borrow_global<ProtocolConfig>(@darbitex);
        (ADMIN, TREASURY, c.factory_addr)
    }

    #[view]
    public fun pool_exists(pool_addr: address): bool {
        exists<Pool>(pool_addr)
    }

    // ===== Batch Quote Views (Aggregator) =====

    #[view]
    /// Batch quote: independent quotes for multiple pools in one call.
    public fun get_amounts_out(
        pool_addrs: vector<address>,
        amounts_in: vector<u64>,
        a_to_b_flags: vector<bool>,
    ): vector<u64> acquires Pool {
        let len = vector::length(&pool_addrs);
        assert!(len == vector::length(&amounts_in) && len == vector::length(&a_to_b_flags), E_ZERO_AMOUNT);
        let results = vector::empty<u64>();
        let i = 0;
        while (i < len) {
            let pool_addr = *vector::borrow(&pool_addrs, i);
            let amount_in = *vector::borrow(&amounts_in, i);
            let a_to_b = *vector::borrow(&a_to_b_flags, i);
            let p = borrow_global<Pool>(pool_addr);
            let (ri, ro) = if (a_to_b) { (p.reserve_a, p.reserve_b) } else { (p.reserve_b, p.reserve_a) };
            let aiwf = (amount_in as u128) * ((BPS_DENOM - SWAP_FEE_BPS) as u128);
            let out = ((aiwf * (ro as u128) / ((ri as u128) * (BPS_DENOM as u128) + aiwf)) as u64);
            vector::push_back(&mut results, out);
            i = i + 1;
        };
        results
    }

    #[view]
    /// Multi-hop quote: simulate sequential swaps through multiple pools.
    public fun get_amount_out_multihop(
        pool_addrs: vector<address>,
        amount_in: u64,
        a_to_b_flags: vector<bool>,
    ): u64 acquires Pool {
        let len = vector::length(&pool_addrs);
        assert!(len == vector::length(&a_to_b_flags), E_ZERO_AMOUNT);
        let current = amount_in;
        let i = 0;
        while (i < len) {
            let pool_addr = *vector::borrow(&pool_addrs, i);
            let a_to_b = *vector::borrow(&a_to_b_flags, i);
            let p = borrow_global<Pool>(pool_addr);
            let (ri, ro) = if (a_to_b) { (p.reserve_a, p.reserve_b) } else { (p.reserve_b, p.reserve_a) };
            let aiwf = (current as u128) * ((BPS_DENOM - SWAP_FEE_BPS) as u128);
            current = ((aiwf * (ro as u128) / ((ri as u128) * (BPS_DENOM as u128) + aiwf)) as u64);
            i = i + 1;
        };
        current
    }
}
