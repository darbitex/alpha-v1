/// Darbitex Pool Factory — canonical pools plus permanent hook auction.
/// One pair = one pool. Hook is awarded via auction; resale is supported.

module darbitex::pool_factory {
    use std::signer;
    use std::bcs;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_std::table::{Self, Table};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;

    use darbitex::pool::{Self, HookCap};
    use darbitex::lp_coin;

    // ===== Constants =====
    const POOL_SEED_PREFIX: vector<u8> = b"darbitex_pool_v3";
    const FACTORY_SEED: vector<u8> = b"darbitex_factory";
    const MIN_AUCTION_DURATION: u64 = 86400;     // 1 day
    const MAX_AUCTION_DURATION: u64 = 2592000;   // 30 days
    const MIN_BID_INCREMENT: u64 = 10;           // 10%
    const MIN_INITIAL_BID: u64 = 10_000_000_000; // 100 APT
    const ANTI_SNIPE_WINDOW: u64 = 600;          // 10 minutes

    // ===== Errors =====
    const E_NOT_ADMIN: u64 = 1;
    const E_ALREADY_INIT: u64 = 2;
    const E_NOT_INIT: u64 = 3;
    const E_WRONG_ORDER: u64 = 5;
    const E_AUCTION_ACTIVE: u64 = 6;
    const E_NO_AUCTION: u64 = 7;
    const E_AUCTION_NOT_ENDED: u64 = 8;
    const E_BID_TOO_LOW: u64 = 9;
    const E_ALREADY_HOOKED: u64 = 10;
    const E_ZERO: u64 = 11;
    const E_WRONG_POOL: u64 = 12;
    const E_AUCTION_ENDED: u64 = 13;
    const E_NO_BIDDER: u64 = 14;
    const E_DURATION: u64 = 15;

    // ===== Resources =====

    struct Factory has key {
        signer_cap: SignerCapability,
        factory_addr: address,
        pool_count: u64,
        pool_addresses: vector<address>,
        auctions: Table<address, Auction>,
    }

    struct Auction has store, drop {
        hook_addr: address,
        bidder: address,
        bid_amount: u64,
        end_time: u64,
        is_resale: bool,
        seller: Option<address>,
        has_bid: bool,
    }

    // ===== Events =====

    #[event]
    struct FactoryInitialized has drop, store { factory_addr: address }

    #[event]
    struct CanonicalPoolCreated has drop, store {
        pool_addr: address, metadata_a: address, metadata_b: address, creator: address,
    }

    #[event]
    struct AuctionStarted has drop, store {
        pool_addr: address, hook_addr: address, bidder: address,
        bid_amount: u64, end_time: u64, is_resale: bool,
    }

    #[event]
    struct BidPlaced has drop, store {
        pool_addr: address, bidder: address, bid_amount: u64, hook_addr: address,
    }

    #[event]
    struct AuctionFinalized has drop, store {
        pool_addr: address, winner: address, hook_addr: address, winning_bid: u64,
    }

    #[event]
    struct AuctionCancelled has drop, store { pool_addr: address }

    #[event]
    struct HookResaleListed has drop, store {
        pool_addr: address, seller: address, min_price: u64, end_time: u64,
    }

    // ===== Internal =====

    fun derive_pair_seed(
        metadata_a: Object<Metadata>, metadata_b: Object<Metadata>,
    ): vector<u8> {
        let seed = POOL_SEED_PREFIX;
        vector::append(&mut seed, bcs::to_bytes(&object::object_address(&metadata_a)));
        vector::append(&mut seed, bcs::to_bytes(&object::object_address(&metadata_b)));
        seed
    }

    fun assert_sorted(metadata_a: Object<Metadata>, metadata_b: Object<Metadata>) {
        let ba = bcs::to_bytes(&object::object_address(&metadata_a));
        let bb = bcs::to_bytes(&object::object_address(&metadata_b));
        assert!(ba < bb, E_WRONG_ORDER);
    }

    fun pool_addr_from_pair(
        factory: &Factory,
        metadata_a: Object<Metadata>, metadata_b: Object<Metadata>,
    ): address {
        object::create_object_address(&factory.factory_addr, derive_pair_seed(metadata_a, metadata_b))
    }

    // ===== Factory Init =====

    public entry fun init_factory(deployer: &signer) {
        let addr = signer::address_of(deployer);
        assert!(addr == @darbitex, E_NOT_ADMIN);
        assert!(!exists<Factory>(@darbitex), E_ALREADY_INIT);

        let (factory_signer, signer_cap) = account::create_resource_account(deployer, FACTORY_SEED);
        let factory_addr = signer::address_of(&factory_signer);

        // CoinStore holds escrowed APT bids.
        coin::register<AptosCoin>(&factory_signer);

        move_to(deployer, Factory {
            signer_cap, factory_addr, pool_count: 0,
            pool_addresses: vector::empty(),
            auctions: table::new(),
        });

        event::emit(FactoryInitialized { factory_addr });
    }

    // ===== Pool Creation =====

    public entry fun create_canonical_pool(
        creator: &signer,
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
        amount_a: u64,
        amount_b: u64,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert_sorted(metadata_a, metadata_b);
        assert!(amount_a > 0 && amount_b > 0, E_ZERO);

        let factory = borrow_global_mut<Factory>(@darbitex);
        let factory_signer = account::create_signer_with_capability(&factory.signer_cap);
        let factory_addr = factory.factory_addr;

        let seed = derive_pair_seed(metadata_a, metadata_b);
        let constructor_ref = object::create_named_object(&factory_signer, seed);
        let pool_addr = signer::address_of(&object::generate_signer(&constructor_ref));

        // Creator → factory → pool
        let creator_addr = signer::address_of(creator);
        let fa_a = primary_fungible_store::withdraw(creator, metadata_a, amount_a);
        let fa_b = primary_fungible_store::withdraw(creator, metadata_b, amount_b);
        primary_fungible_store::deposit(factory_addr, fa_a);
        primary_fungible_store::deposit(factory_addr, fa_b);

        pool::create_pool(&factory_signer, &constructor_ref, metadata_a, metadata_b, amount_a, amount_b);

        // Transfer LP from factory to creator (per-pool LP).
        let lp_bal = lp_coin::balance(@darbitex, pool_addr, factory_addr);
        if (lp_bal > 0) {
            lp_coin::burn(@darbitex, pool_addr, factory_addr, lp_bal);
            lp_coin::mint(@darbitex, pool_addr, creator_addr, lp_bal);
        };

        factory.pool_count = factory.pool_count + 1;
        vector::push_back(&mut factory.pool_addresses, pool_addr);

        event::emit(CanonicalPoolCreated {
            pool_addr,
            metadata_a: object::object_address(&metadata_a),
            metadata_b: object::object_address(&metadata_b),
            creator: creator_addr,
        });
    }

    // ===== Hook Auction =====

    /// Start auction for hook on a plain pool.
    public entry fun start_auction(
        bidder: &signer,
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
        hook_addr: address,
        bid_amount: u64,
        duration: u64,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert_sorted(metadata_a, metadata_b);
        assert!(bid_amount >= MIN_INITIAL_BID, E_BID_TOO_LOW);
        assert!(duration >= MIN_AUCTION_DURATION && duration <= MAX_AUCTION_DURATION, E_DURATION);

        let factory = borrow_global_mut<Factory>(@darbitex);
        let pool_addr = pool_addr_from_pair(factory, metadata_a, metadata_b);
        assert!(!table::contains(&factory.auctions, pool_addr), E_AUCTION_ACTIVE);

        let (current_hook, _) = pool::pool_hook(pool_addr);
        assert!(option::is_none(&current_hook), E_ALREADY_HOOKED);

        let bidder_addr = signer::address_of(bidder);
        coin::transfer<AptosCoin>(bidder, factory.factory_addr, bid_amount);

        let end_time = timestamp::now_seconds() + duration;
        table::add(&mut factory.auctions, pool_addr, Auction {
            hook_addr, bidder: bidder_addr, bid_amount, end_time,
            is_resale: false, seller: option::none(), has_bid: true,
        });

        event::emit(AuctionStarted {
            pool_addr, hook_addr, bidder: bidder_addr, bid_amount, end_time, is_resale: false,
        });
    }

    /// Place higher bid (>= current + 10%). Refunds previous bidder.
    public entry fun bid(
        bidder: &signer,
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
        hook_addr: address,
        bid_amount: u64,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert_sorted(metadata_a, metadata_b);

        let factory = borrow_global_mut<Factory>(@darbitex);
        let pool_addr = pool_addr_from_pair(factory, metadata_a, metadata_b);
        assert!(table::contains(&factory.auctions, pool_addr), E_NO_AUCTION);
        let auction = table::borrow_mut(&mut factory.auctions, pool_addr);

        assert!(timestamp::now_seconds() < auction.end_time, E_AUCTION_ENDED);

        // On a resale's first bid, bid_amount stores the floor price.
        let min_bid = if (!auction.has_bid) {
            auction.bid_amount
        } else {
            auction.bid_amount + auction.bid_amount * MIN_BID_INCREMENT / 100
        };
        assert!(bid_amount >= min_bid, E_BID_TOO_LOW);

        // Only refund if there was an actual previous bid (not the @0x0 placeholder).
        if (auction.has_bid) {
            let factory_signer = account::create_signer_with_capability(&factory.signer_cap);
            coin::transfer<AptosCoin>(&factory_signer, auction.bidder, auction.bid_amount);
        };

        let bidder_addr = signer::address_of(bidder);
        coin::transfer<AptosCoin>(bidder, factory.factory_addr, bid_amount);

        auction.bidder = bidder_addr;
        auction.bid_amount = bid_amount;
        auction.hook_addr = hook_addr;
        auction.has_bid = true;

        // Anti-snipe: extend deadline if bid lands inside the final window.
        let now = timestamp::now_seconds();
        let remaining = auction.end_time - now;
        if (remaining < ANTI_SNIPE_WINDOW) {
            auction.end_time = now + ANTI_SNIPE_WINDOW;
        };

        event::emit(BidPlaced { pool_addr, bidder: bidder_addr, bid_amount, hook_addr });
    }

    /// Finalize auction. Anyone can call after end_time.
    public entry fun finalize_auction(
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert_sorted(metadata_a, metadata_b);

        let factory = borrow_global_mut<Factory>(@darbitex);
        let pool_addr = pool_addr_from_pair(factory, metadata_a, metadata_b);
        assert!(table::contains(&factory.auctions, pool_addr), E_NO_AUCTION);
        let auction = table::remove(&mut factory.auctions, pool_addr);

        assert!(timestamp::now_seconds() >= auction.end_time, E_AUCTION_NOT_ENDED);

        // Must have at least one real bid to finalize.
        assert!(auction.has_bid, E_NO_BIDDER);

        let factory_signer = account::create_signer_with_capability(&factory.signer_cap);

        // Re-verify pool state before the hook swap.
        if (auction.is_resale) {
            pool::remove_hook(&factory_signer, pool_addr);
        } else {
            let (current_hook, _) = pool::pool_hook(pool_addr);
            assert!(option::is_none(&current_hook), E_ALREADY_HOOKED);
        };

        pool::set_hook(&factory_signer, pool_addr, auction.hook_addr);

        // Send proceeds to treasury or seller
        let recipient = if (option::is_some(&auction.seller)) {
            *option::borrow(&auction.seller)
        } else {
            let (_, treasury, _) = pool::protocol_config();
            treasury
        };
        coin::transfer<AptosCoin>(&factory_signer, recipient, auction.bid_amount);

        event::emit(AuctionFinalized {
            pool_addr, winner: auction.bidder, hook_addr: auction.hook_addr,
            winning_bid: auction.bid_amount,
        });
    }

    /// Cancel auction with no bids (resale only). Anyone can call after end_time.
    public entry fun cancel_auction(
        metadata_a: Object<Metadata>,
        metadata_b: Object<Metadata>,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert_sorted(metadata_a, metadata_b);

        let factory = borrow_global_mut<Factory>(@darbitex);
        let pool_addr = pool_addr_from_pair(factory, metadata_a, metadata_b);
        assert!(table::contains(&factory.auctions, pool_addr), E_NO_AUCTION);
        let auction = table::borrow(&factory.auctions, pool_addr);

        assert!(timestamp::now_seconds() >= auction.end_time, E_AUCTION_NOT_ENDED);
        // Only cancel if no bids have arrived.
        assert!(!auction.has_bid, E_AUCTION_ACTIVE);

        table::remove(&mut factory.auctions, pool_addr);
        event::emit(AuctionCancelled { pool_addr });
    }

    /// Seller-initiated resale cancel. The original lister proves ownership
    /// by presenting the same HookCap they listed with, and can pull the
    /// listing at any time as long as no bid has arrived yet. Called by the
    /// hook module; end users reach it through the hook's own entry point.
    public fun seller_cancel_resale(
        pool_addr: address,
        seller: address,
        cap: &HookCap,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert!(pool::hook_cap_pool(cap) == pool_addr, E_WRONG_POOL);

        let factory = borrow_global_mut<Factory>(@darbitex);
        assert!(table::contains(&factory.auctions, pool_addr), E_NO_AUCTION);
        let auction = table::borrow(&factory.auctions, pool_addr);

        assert!(auction.is_resale, E_AUCTION_ACTIVE);
        assert!(!auction.has_bid, E_AUCTION_ACTIVE);
        assert!(option::is_some(&auction.seller), E_AUCTION_ACTIVE);
        assert!(*option::borrow(&auction.seller) == seller, E_AUCTION_ACTIVE);

        table::remove(&mut factory.auctions, pool_addr);
        event::emit(AuctionCancelled { pool_addr });
    }

    // ===== Hook Resale =====

    /// List hook for resale. Called by the hook module via HookCap.
    /// No APT is escrowed at listing time — only once a first bid arrives.
    public fun list_for_resale(
        pool_addr: address,
        min_price: u64,
        duration: u64,
        seller: address,
        cap: &HookCap,
    ) acquires Factory {
        assert!(exists<Factory>(@darbitex), E_NOT_INIT);
        assert!(pool::hook_cap_pool(cap) == pool_addr, E_WRONG_POOL);
        assert!(min_price >= MIN_INITIAL_BID, E_BID_TOO_LOW);
        assert!(duration >= MIN_AUCTION_DURATION && duration <= MAX_AUCTION_DURATION, E_DURATION);

        let factory = borrow_global_mut<Factory>(@darbitex);
        assert!(!table::contains(&factory.auctions, pool_addr), E_AUCTION_ACTIVE);

        let end_time = timestamp::now_seconds() + duration;
        table::add(&mut factory.auctions, pool_addr, Auction {
            hook_addr: @0x0,      // bidders supply their hook on bid
            bidder: @0x0,
            bid_amount: min_price, // floor price until first bid
            end_time,
            is_resale: true,
            seller: option::some(seller),
            has_bid: false,
        });

        event::emit(HookResaleListed { pool_addr, seller, min_price, end_time });
    }

    // ===== Views =====

    #[view]
    public fun factory_address(): address acquires Factory {
        borrow_global<Factory>(@darbitex).factory_addr
    }

    #[view]
    public fun pool_count(): u64 acquires Factory {
        borrow_global<Factory>(@darbitex).pool_count
    }

    #[view]
    public fun canonical_pool_address(
        metadata_a: Object<Metadata>, metadata_b: Object<Metadata>,
    ): address acquires Factory {
        let f = borrow_global<Factory>(@darbitex);
        pool_addr_from_pair(f, metadata_a, metadata_b)
    }

    #[view]
    public fun has_active_auction(
        metadata_a: Object<Metadata>, metadata_b: Object<Metadata>,
    ): bool acquires Factory {
        let f = borrow_global<Factory>(@darbitex);
        let pa = pool_addr_from_pair(f, metadata_a, metadata_b);
        table::contains(&f.auctions, pa)
    }

    #[view]
    public fun get_all_pools(): vector<address> acquires Factory {
        borrow_global<Factory>(@darbitex).pool_addresses
    }

    #[view]
    /// Paginated pool list for large registries.
    public fun get_pools_paginated(offset: u64, limit: u64): vector<address> acquires Factory {
        let f = borrow_global<Factory>(@darbitex);
        let len = vector::length(&f.pool_addresses);
        let start = if (offset > len) { len } else { offset };
        let end = if (start + limit > len) { len } else { start + limit };
        let result = vector::empty<address>();
        let i = start;
        while (i < end) {
            vector::push_back(&mut result, *vector::borrow(&f.pool_addresses, i));
            i = i + 1;
        };
        result
    }
}
