module MovernancePad::LaunchpadV2 {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_std::math64::mul_div;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    #[test_only]
    use std::option;
    #[test_only]
    use std::string::{Self, utf8};
    #[test_only]
    use aptos_std::debug;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use MovernancePad::TestFA::{Self, create_fa, mint};

    // errors
    const ENOT_ADMIN: u64 = 1;
    const EPROTECTED_AMOUNT_EXCEEDS_HARD_CAP: u64 = 2;
    const EPOOL_NOT_READY: u64 = 3;
    const EPOOL_ALREADY_READY: u64 = 4;
    const EPOOL_ALREADY_STARTED: u64 = 5;
    const EINVALID_IDO_TIMES: u64 = 6;
    const EPOOL_NOT_STARTED: u64 = 7;
    const EPOOL_ALREADY_FINISHED: u64 = 8;
    const EMINIMUM_PURCHASE_AMOUNT: u64 = 9;
    const EINVALID_AMOUNT: u64 = 10;
    const EINVALID_IDO_SUPPLY: u64 = 11;
    const ECLAIM_NOT_STARTED: u64 = 12;
    const ENOT_CLAIMABLE: u64 = 13;
    const EALREADY_CLAIMED: u64 = 14;
    const ENOT_PURCHASED: u64 = 15;
    const ENOT_RECIPIENT: u64 = 16;
    const EPOOL_NOT_FOUND: u64 = 17;
    const EINVALID_PERIOD: u64 = 18;
    const EPOOL_PAUSED: u64 = 19;
    const EINVALID_FA: u64 = 20;
    const ETRANSFER_AMOUNT_LOSS_EXCEEDS_TOLERANCE: u64 = 21;

    // constants

    // timestamps: cratePool <-> setPoolReady <-> ido_start_time <-> ido_end_time <-> claim_start_time
    // periods:
    // 1. edit period: cratePool -> setPoolReady
    //    update_pool, deposit_supply_token, update_whitelist can only be called in this period
    // 2. ready: setPoolReady -> ido_start_time
    //    no action can be taken in this period
    // 3. ido: ido_start_time -> ido_end_time
    //    purchase can only be called in this period
    // 4. claim: claim_start_time -> end
    //    claim, withdraw_purchase_token can only be called in this period
    const POOL_PERIOD_EDIT: u64 = 1;
    const POOL_PERIOD_IDO: u64 = 2;
    const POOL_PERIOD_CLAIM: u64 = 3;

    // the tolerance for the math, if it's less than this, we still perform the withdraw/claim
    const TOLERANCE: u64 = 100;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Pool has key {
        admins: SmartTable<address, bool>,
        paused: bool,
        // used for emergency, stop all actions
        ready: bool,
        // mark as ready when all configs are set
        // config
        ido_start_time: u64,
        ido_end_time: u64,
        claim_start_time: u64,
        hard_cap: u64,
        ido_supply: u64,
        purchase_token_recipient: address,
        // who can withdraw the funds when the ido ends
        minimum_purchase_amount: u64,
        supply_token: Object<Metadata>,
        purchase_token: Object<Metadata>,
        // supply_token_store: Object<FungibleStore>,
        // purchase_token_store: Object<FungibleStore>,
        // whitelisted addresses
        whitelist: SmartTable<address, u64>,
        // address -> protected amount
        protected_amount: u64,
        // state
        purchased: SmartTable<address, u64>,
        // address -> purchase amount
        total_purchased: u64,
        total_purchased_protected: u64,
        claimed: SmartTable<address, bool>,
        // address -> claimed
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct ObjectController has key {
        extend_ref: object::ExtendRef,
    }

    struct Claimable has copy, drop {
        addr: address,
        protected_amount: u64,
        claimed: bool,
        claimable: u64,
        purchased: u64,
        refund: u64,
    }

    // events
    #[event]
    struct PoolCreated has store, drop {
        pool: address,
        supply_token: address,
        purchase_token: address,
    }

    #[event]
    struct TransferLoss has store, drop {
        token: Object<Metadata>,
        from: address,
        to: address,
        expected_amount: u64,
        actual_amount: u64,
    }

    // internal functions
    fun init_module(_deployer: &signer) {}

    fun check_params(ido_start_time: u64, ido_end_time: u64, claim_start_time: u64) {
        assert!(ido_start_time < ido_end_time, EINVALID_IDO_TIMES);
        assert!(ido_end_time <= claim_start_time, EINVALID_IDO_TIMES);
        let now = timestamp::now_seconds();
        assert!(ido_start_time > now, EPOOL_ALREADY_STARTED);
    }

    // assert in correct period
    fun assert_period(pool: &Pool, period: u64) {
        let now = timestamp::now_seconds();
        assert!(!pool.paused, EPOOL_PAUSED);
        if (period == POOL_PERIOD_EDIT) {
            assert!(!pool.ready, EPOOL_ALREADY_READY);
        } else if (period == POOL_PERIOD_IDO) {
            assert!(pool.ready, EPOOL_NOT_READY);
            assert!(pool.ido_start_time <= now, EPOOL_NOT_STARTED);
            assert!(now < pool.ido_end_time, EPOOL_ALREADY_FINISHED);
        } else if (period == POOL_PERIOD_CLAIM) {
            assert!(pool.ready, EPOOL_NOT_READY);
            assert!(pool.claim_start_time <= now, ECLAIM_NOT_STARTED);
        } else {
            assert!(false, EINVALID_PERIOD);
        }
    }

    inline fun is_pool_admin(pool: &Pool, addr: address): bool {
        smart_table::contains(&pool.admins, addr)
    }

    fun transfer_with_tolerance(token: Object<Metadata>, from: &signer, to: address, amount: u64): u64 {
        let balance = primary_fungible_store::balance(signer::address_of(from), token);
        let transfer_amount = if (amount > balance) {
            assert!(amount - balance <= TOLERANCE, ETRANSFER_AMOUNT_LOSS_EXCEEDS_TOLERANCE);
            event::emit(
                TransferLoss {
                    token,
                    from: signer::address_of(from),
                    to,
                    expected_amount: amount,
                    actual_amount: balance,
                }
            );
            balance
        } else {
            amount
        };
        primary_fungible_store::transfer(from, token, to, transfer_amount);
        transfer_amount
    }

    // public functions
    public entry fun create_pool(
        creator: &signer,
        supply_token: Object<Metadata>,
        purchase_token: Object<Metadata>,
        purchase_token_recipient: address,
        ido_start_time: u64,
        ido_end_time: u64,
        claim_start_time: u64,
        hard_cap: u64,
        ido_supply: u64,
        minimum_purchase_amount: u64,
    ) {
        // check params
        assert!(supply_token != purchase_token, EINVALID_FA);
        check_params(ido_start_time, ido_end_time, claim_start_time);
        let creator_address = signer::address_of(creator);
        // create object
        let constructor_ref = object::create_sticky_object(creator_address);
        let pool_address = object::address_from_constructor_ref(&constructor_ref);
        let pool_signer = object::generate_signer(&constructor_ref);
        // create pool
        let admins = smart_table::new();
        smart_table::add(&mut admins, creator_address, true);
        let pool = Pool {
            admins,
            ready: false,
            paused: false,
            ido_start_time,
            ido_end_time,
            claim_start_time,
            hard_cap,
            ido_supply,
            purchase_token_recipient,
            minimum_purchase_amount,
            supply_token,
            purchase_token,
            whitelist: smart_table::new(),
            protected_amount: 0,
            purchased: smart_table::new(),
            total_purchased: 0,
            total_purchased_protected: 0,
            claimed: smart_table::new(),
        };
        // move pool to object
        move_to(&pool_signer, pool);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&pool_signer, ObjectController { extend_ref });
        // emit event
        event::emit(
            PoolCreated {
                pool: pool_address,
                supply_token: object::object_address(&supply_token),
                purchase_token: object::object_address(&purchase_token),
            }
        );
    }

    public entry fun add_pool_admins(account: &signer, pool: Object<Pool>, admins: vector<address>) acquires Pool {
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        vector::for_each(admins, |admin| {
            smart_table::add(&mut pool.admins, admin, true);
        });
    }

    public entry fun remove_pool_admins(account: &signer, pool: Object<Pool>, admins: vector<address>) acquires Pool {
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        vector::for_each(admins, |admin| {
            smart_table::remove(&mut pool.admins, admin);
        });
    }

    public entry fun pause_pool(account: &signer, pool: Object<Pool>) acquires Pool {
        let pool = borrow_global_mut<Pool>(object::object_address(&pool));
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        pool.paused = true;
    }

    public entry fun unpause_pool(account: &signer, pool: Object<Pool>) acquires Pool {
        let pool = borrow_global_mut<Pool>(object::object_address(&pool));
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        pool.paused = false;
    }

    public entry fun deposit_supply_token(account: &signer, pool: Object<Pool>, amount: u64) acquires Pool {
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        primary_fungible_store::transfer(account, pool.supply_token, pool_address, amount);
    }

    public entry fun deposit_supply_token_with_coin<P>(
        account: &signer,
        pool: Object<Pool>,
        amount: u64
    ) acquires Pool {
        let supply_coin = coin::withdraw<P>(account, amount);
        let fa = coin::coin_to_fungible_asset(supply_coin);
        primary_fungible_store::deposit(signer::address_of(account), fa);
        deposit_supply_token(account, pool, amount);
    }

    public entry fun update_pool(
        account: &signer,
        pool: Object<Pool>,
        ido_start_time: u64,
        ido_end_time: u64,
        claim_start_time: u64,
        hard_cap: u64,
        ido_supply: u64,
        minimum_purchase_amount: u64,
    ) acquires Pool {
        check_params(ido_start_time, ido_end_time, claim_start_time);
        let pool = borrow_global_mut<Pool>(object::object_address(&pool));
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        assert_period(pool, POOL_PERIOD_EDIT);
        // check hard cap
        assert!(pool.hard_cap >= pool.protected_amount, EPROTECTED_AMOUNT_EXCEEDS_HARD_CAP);
        // update pool
        pool.ido_start_time = ido_start_time;
        pool.ido_end_time = ido_end_time;
        pool.claim_start_time = claim_start_time;
        pool.hard_cap = hard_cap;
        pool.ido_supply = ido_supply;
        pool.minimum_purchase_amount = minimum_purchase_amount;
    }

    public entry fun update_whitelist(
        account: &signer,
        pool: Object<Pool>,
        whitelist: vector<address>,
        protected_amount: u64
    ) acquires Pool {
        // check admin
        let pool = borrow_global_mut<Pool>(object::object_address(&pool));
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        assert_period(pool, POOL_PERIOD_EDIT);
        // update whitelist and total protected amount
        vector::for_each(whitelist, |address| {
            let current = smart_table::borrow_mut_with_default(&mut pool.whitelist, address, 0);
            if (*current != protected_amount) {
                pool.protected_amount = pool.protected_amount - *current + protected_amount;
                *current = protected_amount;
            }
        });
        assert!(pool.protected_amount <= pool.hard_cap, EPROTECTED_AMOUNT_EXCEEDS_HARD_CAP);
    }

    public entry fun set_pool_ready(account: &signer, pool: Object<Pool>) acquires Pool {
        // check admin
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(is_pool_admin(pool, signer::address_of(account)), ENOT_ADMIN);
        assert_period(pool, POOL_PERIOD_EDIT);
        // check time
        let now = timestamp::now_seconds();
        assert!(now < pool.ido_start_time, EPOOL_ALREADY_STARTED);
        // check supply token vault
        assert!(
            primary_fungible_store::balance(pool_address, pool.supply_token) == pool.ido_supply,
            EINVALID_IDO_SUPPLY
        );
        // check protected amount
        assert!(pool.protected_amount <= pool.hard_cap, EPROTECTED_AMOUNT_EXCEEDS_HARD_CAP);
        pool.ready = true;
    }

    public entry fun purchase(account: &signer, pool: Object<Pool>, amount: u64) acquires Pool {
        assert!(amount > 0, EINVALID_AMOUNT);
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        assert_period(pool, POOL_PERIOD_IDO);
        // assert amount
        assert!(amount >= pool.minimum_purchase_amount, EMINIMUM_PURCHASE_AMOUNT);
        // get coin from user and add to pool vault
        primary_fungible_store::transfer(account, pool.purchase_token, pool_address, amount);
        // record amount
        let current = smart_table::borrow_mut_with_default(&mut pool.purchased, signer::address_of(account), 0);
        let user_address = signer::address_of(account);
        let user_protected_amount = *smart_table::borrow_with_default(&pool.whitelist, user_address, &0);
        let user_total_purchased = *current + amount;
        if (user_protected_amount > *current) {
            let new_purchased_protected = if (user_total_purchased > user_protected_amount) {
                user_protected_amount
            } else {
                user_total_purchased
            };
            pool.total_purchased_protected = pool.total_purchased_protected + new_purchased_protected - *current;
        };
        *current = *current + amount;
        pool.total_purchased = pool.total_purchased + amount;
    }

    public entry fun purchase_with_coin<P>(account: &signer, pool: Object<Pool>, amount: u64) acquires Pool {
        // extract coin from user and convert to fa
        let purchase_coin = coin::withdraw<P>(account, amount);
        let fa = coin::coin_to_fungible_asset(purchase_coin);
        primary_fungible_store::deposit(signer::address_of(account), fa);
        purchase(account, pool, amount);
    }

    public entry fun claim(user_address: address, pool: Object<Pool>) acquires Pool, ObjectController {
        let claimable = get_claimable_amount(user_address, pool);
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        assert_period(pool, POOL_PERIOD_CLAIM);
        assert!(!claimable.claimed, EALREADY_CLAIMED);
        assert!(claimable.claimable > 0 || claimable.refund > 0, ENOT_CLAIMABLE);
        let pool_signer = object::generate_signer_for_extending(
            &borrow_global<ObjectController>(pool_address).extend_ref
        );
        if (claimable.claimable > 0) {
            primary_fungible_store::transfer(&pool_signer, pool.supply_token, user_address, claimable.claimable);
        };
        if (claimable.refund > 0) {
            transfer_with_tolerance(pool.purchase_token, &pool_signer, user_address, claimable.refund);
        };
        smart_table::add(&mut pool.claimed, user_address, true);
    }

    // withdraw purchase token and left supply token to the purchase token recipient
    public entry fun withdraw(account: &signer, pool: Object<Pool>) acquires Pool, ObjectController {
        let pool_address = object::object_address(&pool);
        let pool = borrow_global_mut<Pool>(pool_address);
        assert_period(pool, POOL_PERIOD_CLAIM);
        // assert recipient
        assert!(pool.purchase_token_recipient == signer::address_of(account), ENOT_RECIPIENT);
        let (purchase_amount, supply_left_amount) = if (pool.total_purchased > pool.hard_cap) {
            (pool.hard_cap, 0)
        } else {
            let claimable_supply = mul_div(pool.total_purchased, pool.ido_supply, pool.hard_cap);
            (pool.total_purchased, pool.ido_supply - claimable_supply)
        };
        let pool_signer = object::generate_signer_for_extending(
            &borrow_global<ObjectController>(pool_address).extend_ref
        );
        // get purchase token from pool vault
        if (purchase_amount > 0) {
            transfer_with_tolerance(pool.purchase_token, &pool_signer, pool.purchase_token_recipient, purchase_amount);
        };
        // get supply token from pool vault
        if (supply_left_amount > 0) {
            primary_fungible_store::transfer(
                &pool_signer,
                pool.supply_token,
                pool.purchase_token_recipient,
                supply_left_amount
            );
        };
    }

    // view functions
    struct PoolView {
        pool_address: address,
        ido_start_time: u64,
        ido_end_time: u64,
        claim_start_time: u64,
        hard_cap: u64,
        ido_supply: u64,
        minimum_purchase_amount: u64,
        total_purchased: u64,
        purchase_token_id: Object<Metadata>,
        supply_token_id: Object<Metadata>,
        ready: bool,
        paused: bool,
        purchase_token_symbol: String,
        purchase_token_decimal: u8,
        supply_token_symbol: String,
        supply_token_decimal: u8,
        purchase_token_icon: String,
        supply_token_icon: String,
    }

    #[view]
    public fun get_pools_view(pools: vector<Object<Pool>>): vector<PoolView> acquires Pool {
        let pool_views = vector::empty<PoolView>();
        vector::for_each(pools, |pool| {
            let pool_address = object::object_address(&pool);
            let pool = borrow_global<Pool>(pool_address);
            let purchase_token_id = object::object_address(&pool.purchase_token);
            let supply_token_id = object::object_address(&pool.supply_token);
            let purchase_token_obj = object::address_to_object<Metadata>(purchase_token_id);
            let supply_token_obj = object::address_to_object<Metadata>(supply_token_id);
            let purchase_token_symbol = fungible_asset::symbol(purchase_token_obj);
            let purchase_token_decimal = fungible_asset::decimals(purchase_token_obj);
            let supply_token_symbol = fungible_asset::symbol(supply_token_obj);
            let supply_token_decimal = fungible_asset::decimals(supply_token_obj);
            let purchase_token_icon = fungible_asset::icon_uri(purchase_token_obj);
            let supply_token_icon = fungible_asset::icon_uri(supply_token_obj);
            let pool_view = PoolView {
                pool_address,
                ido_start_time: pool.ido_start_time,
                ido_end_time: pool.ido_end_time,
                claim_start_time: pool.claim_start_time,
                hard_cap: pool.hard_cap,
                ido_supply: pool.ido_supply,
                minimum_purchase_amount: pool.minimum_purchase_amount,
                total_purchased: pool.total_purchased,
                purchase_token_id: pool.purchase_token,
                supply_token_id: pool.supply_token,
                ready: pool.ready,
                paused: pool.paused,
                purchase_token_symbol,
                purchase_token_decimal,
                supply_token_symbol,
                supply_token_decimal,
                purchase_token_icon,
                supply_token_icon,
            };
            vector::push_back(&mut pool_views, pool_view);
        });
        pool_views
    }

    #[view]
    public fun get_pool_admins(pool: Object<Pool>): vector<address> acquires Pool {
        let pool_address = object::object_address(&pool);
        let pool = borrow_global<Pool>(pool_address);
        smart_table::keys(&pool.admins)
    }

    #[view]
    public fun get_claimable_amount(user_address: address, pool: Object<Pool>): Claimable acquires Pool {
        let pool = borrow_global<Pool>(object::object_address(&pool));
        let user_protected_amount = *smart_table::borrow_with_default(&pool.whitelist, user_address, &0);
        // get user purchased amount
        let user_purchased_amount = *smart_table::borrow_with_default(&pool.purchased, user_address, &0);
        if (user_purchased_amount == 0) {
            return Claimable {
                addr: user_address,
                protected_amount: user_protected_amount,
                claimed: false,
                claimable: 0,
                refund: 0,
                purchased: 0,
            }
        };
        let claimed = *smart_table::borrow_with_default(&pool.claimed, user_address, &false);
        if (pool.total_purchased <= pool.hard_cap) {
            // condition 1: purchased amount is less than hard cap, everyone can claim according to the purchase amount
            Claimable {
                claimable: mul_div(user_purchased_amount, pool.ido_supply, pool.hard_cap),
                refund: 0,
                addr: user_address,
                protected_amount: user_protected_amount,
                claimed,
                purchased: user_purchased_amount,
            }
        } else {
            // condition 2: purchased amount is greater than hard cap, fill protected amount first, then calculate the claimable amount
            // according to the share of unprotected purchase amount
            let total_unprotected_amount = pool.total_purchased - pool.total_purchased_protected;
            let user_fill_amount = if (user_protected_amount >= user_purchased_amount) {
                user_purchased_amount
            } else {
                user_protected_amount + mul_div(
                    user_purchased_amount - user_protected_amount,
                    pool.hard_cap - pool.total_purchased_protected,
                    total_unprotected_amount
                )
            };
            let claimable_amount = mul_div(user_fill_amount, pool.ido_supply, pool.hard_cap);
            let refund_amount = user_purchased_amount - user_fill_amount;
            Claimable {
                addr: user_address,
                protected_amount: user_protected_amount,
                claimed: false,
                claimable: claimable_amount,
                refund: refund_amount,
                purchased: user_purchased_amount,
            }
        }
    }

    // ------------- tests ------------------
    // Test coins
    #[test_only]
    struct USDC {}

    #[test_only]
    struct IDO {}

    #[test_only]
    const ADMIN: address = @0xff01;
    #[test_only]
    const USER1: address = @0xff02;
    #[test_only]
    const USER2: address = @0xff03;
    #[test_only]
    const USER3: address = @0xff04;

    #[test_only]
    struct SetupParams {
        admin: signer,
        user1: signer,
        user2: signer,
        user3: signer,
        supply_token: Object<Metadata>,
        purchase_token: Object<Metadata>,
    }

    #[test_only]
    fun setup_test(): SetupParams {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let movernance_pad_signer = account::create_account_for_test(@MovernancePad);
        TestFA::init_for_test(&movernance_pad_signer);
        init_module(&movernance_pad_signer);

        // Create accounts
        let admin = account::create_account_for_test(ADMIN);
        let user1 = account::create_account_for_test(USER1);
        let user2 = account::create_account_for_test(USER2);
        let user3 = account::create_account_for_test(USER3);

        // Create FA
        let supply_token_symbol = utf8(b"IDO");
        let purchase_token_symbol = utf8(b"USDC");
        create_fa(&admin, supply_token_symbol, supply_token_symbol, 6);
        create_fa(&admin, purchase_token_symbol, purchase_token_symbol, 6);
        let supply_token_addr = TestFA::get_metadata_by_symbol(supply_token_symbol);
        let purchase_token_addr = TestFA::get_metadata_by_symbol(purchase_token_symbol);
        let supply_token = object::address_to_object<Metadata>(supply_token_addr);
        let purchase_token = object::address_to_object<Metadata>(purchase_token_addr);
        // mint tokens
        let mint_token_amount = 100_000_000_000_000;
        mint(&admin, supply_token_symbol, mint_token_amount);
        mint(&user1, purchase_token_symbol, mint_token_amount);
        mint(&user2, purchase_token_symbol, mint_token_amount);
        mint(&user3, purchase_token_symbol, mint_token_amount);

        SetupParams {
            admin,
            user1,
            user2,
            user3,
            supply_token,
            purchase_token,
        }
    }

    #[test_only]
    fun setup_test_with_coin(): SetupParams {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let movernance_pad_signer = account::create_account_for_test(@MovernancePad);
        TestFA::init_for_test(&movernance_pad_signer);
        init_module(&movernance_pad_signer);

        // Create accounts
        let admin = account::create_account_for_test(ADMIN);
        let user1 = account::create_account_for_test(USER1);
        let user2 = account::create_account_for_test(USER2);
        let user3 = account::create_account_for_test(USER3);

        // Register and mint test coins
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<USDC>(
            &movernance_pad_signer,
            string::utf8(b"USDC"),
            string::utf8(b"USDC"),
            6,
            false,
        );
        coin::register<USDC>(&user1);
        coin::register<USDC>(&user2);
        coin::register<USDC>(&user3);
        let coins = coin::mint(1000000000, &mint_cap);
        coin::deposit(USER1, coins);
        let coins = coin::mint(1000000000, &mint_cap);
        coin::deposit(USER2, coins);
        let coins = coin::mint(1000000000, &mint_cap);
        coin::deposit(USER3, coins);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<IDO>(
            &movernance_pad_signer,
            string::utf8(b"IDO"),
            string::utf8(b"IDO"),
            6,
            false,
        );
        coin::register<IDO>(&admin);
        let coins = coin::mint(1000000000, &mint_cap);
        coin::deposit(ADMIN, coins);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);

        let framework_signer = account::create_account_for_test(@aptos_framework);
        coin::create_coin_conversion_map(&framework_signer);
        coin::create_pairing<IDO>(&framework_signer);
        coin::create_pairing<USDC>(&framework_signer);
        let supply_token_option = coin::paired_metadata<IDO>();
        let supply_token = option::extract(&mut supply_token_option);
        let purchase_token_option = coin::paired_metadata<USDC>();
        let purchase_token = option::extract(&mut purchase_token_option);

        SetupParams {
            admin,
            user1,
            user2,
            user3,
            supply_token,
            purchase_token,
        }
    }

    #[test]
    fun test_launchpad_flow() acquires Pool, ObjectController {
        let SetupParams { admin, user1, user2, user3: _user3, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        debug::print(&pool_created_events);
        assert!(vector::length(&pool_created_events) == 1, 0);
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        // Deposit supply token
        let admin_supply_balance = primary_fungible_store::balance(ADMIN, supply_token);
        debug::print(&admin_supply_balance);
        deposit_supply_token(&admin, pool, 500000);

        // Update whitelist
        let whitelist = vector::empty<address>();
        vector::push_back(&mut whitelist, USER1);
        update_whitelist(&admin, pool, whitelist, 100000);

        // Set pool ready
        set_pool_ready(&admin, pool);

        // Set current time to IDO start time
        timestamp::update_global_time_for_test(1000000000);

        // Users purchase tokens
        purchase(&user1, pool, 150000);
        purchase(&user2, pool, 200000);

        // Set current time to claim start time
        timestamp::update_global_time_for_test(3000000000);

        // Users claim tokens
        claim(USER1, pool);
        claim(USER2, pool);

        // Admin withdraws purchase tokens
        withdraw(&admin, pool);

        // Check final balances
        let user1_supply_balance = primary_fungible_store::balance(USER1, supply_token);
        let user2_supply_balance = primary_fungible_store::balance(USER2, supply_token);
        let user1_purchase_balance = primary_fungible_store::balance(USER1, purchase_token);
        let user2_purchase_balance = primary_fungible_store::balance(USER2, purchase_token);
        let admin_purchase_balance = primary_fungible_store::balance(ADMIN, purchase_token);

        debug::print(&user1_supply_balance);
        debug::print(&user2_supply_balance);
        let mint_token_amount = 100_000_000_000_000;
        assert!(user1_purchase_balance == mint_token_amount - 150000, 0);
        assert!(user2_purchase_balance == mint_token_amount - 200000, 1);
        assert!(user1_supply_balance == 75000, 2);
        assert!(user2_supply_balance == 100000, 3);
        assert!(admin_purchase_balance == 350000, 4);
    }

    #[test]
    fun test_launchpad_flow_with_coin() acquires Pool, ObjectController {
        let SetupParams { admin, user1, user2, user3: _user3, supply_token, purchase_token } = setup_test_with_coin();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        debug::print(&pool_created_events);
        assert!(vector::length(&pool_created_events) == 1, 0);
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        // Deposit supply token
        let admin_supply_balance = primary_fungible_store::balance(ADMIN, supply_token);
        debug::print(&admin_supply_balance);
        deposit_supply_token_with_coin<IDO>(&admin, pool, 500000);

        // Update whitelist
        let whitelist = vector::empty<address>();
        vector::push_back(&mut whitelist, USER1);
        update_whitelist(&admin, pool, whitelist, 100000);

        // Set pool ready
        set_pool_ready(&admin, pool);

        // Set current time to IDO start time
        timestamp::update_global_time_for_test(1000000000);

        // Users purchase tokens
        purchase_with_coin<USDC>(&user1, pool, 150000);
        purchase_with_coin<USDC>(&user2, pool, 200000);

        // Set current time to claim start time
        timestamp::update_global_time_for_test(3000000000);

        let user1_claimable = get_claimable_amount(USER1, pool);
        let user2_claimable = get_claimable_amount(USER2, pool);
        debug::print(&user1_claimable);
        debug::print(&user2_claimable);

        // Users claim tokens
        claim(USER1, pool);
        claim(USER2, pool);

        // Admin withdraws purchase tokens
        withdraw(&admin, pool);

        // Check final balances
        let user1_supply_balance = primary_fungible_store::balance(USER1, supply_token);
        let user2_supply_balance = primary_fungible_store::balance(USER2, supply_token);
        let user1_purchase_balance = primary_fungible_store::balance(USER1, purchase_token);
        let user2_purchase_balance = primary_fungible_store::balance(USER2, purchase_token);
        let admin_purchase_balance = primary_fungible_store::balance(ADMIN, purchase_token);

        debug::print(&user1_supply_balance);
        debug::print(&user2_supply_balance);
        assert!(user1_purchase_balance == user1_claimable.refund, 0);
        assert!(user2_purchase_balance == user2_claimable.refund, 1);
        assert!(user1_supply_balance == 75000, 2);
        assert!(user2_supply_balance == 100000, 3);
        assert!(admin_purchase_balance == 350000, 4);
    }


    #[test]
    fun test_launchpad_math() acquires Pool, ObjectController {
        let SetupParams { admin, user1, user2, user3, supply_token, purchase_token } = setup_test();

        // Create pool
        let ido_supply = 5_000_000_000_000;
        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000, // ido_start_time
            2000, // ido_end_time
            3000, // claim_start_time
            1_000_000_000_000, // hard_cap
            ido_supply, // ido_supply
            10_000_000, // minimum_purchase_amount
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        // Deposit supply token
        deposit_supply_token(&admin, pool, ido_supply);

        // Update whitelist
        let whitelist_amount = 100_000_000;
        let whitelist = vector::empty<address>();
        vector::push_back(&mut whitelist, USER1);
        vector::push_back(&mut whitelist, USER2);
        update_whitelist(&admin, pool, whitelist, whitelist_amount);

        // Set pool ready
        set_pool_ready(&admin, pool);

        // Set current time to IDO start time
        timestamp::update_global_time_for_test(1000000000);

        // Users purchase tokens
        let user1_amount = 50_000_000;
        let user2_amount = 200_000_000;
        let user3_amount = 6_000_000_000_000;
        purchase(&user1, pool, user1_amount);
        purchase(&user2, pool, user2_amount);
        purchase(&user3, pool, user3_amount);

        // Set current time to claim start time
        timestamp::update_global_time_for_test(3000000000);

        let user1_claimable = get_claimable_amount(USER1, pool);
        debug::print(&user1_claimable);
        let user2_claimable = get_claimable_amount(USER2, pool);
        debug::print(&user2_claimable);
        let user3_claimable = get_claimable_amount(USER3, pool);
        debug::print(&user3_claimable);

        assert!(user1_claimable.purchased == user1_amount, 0);
        assert!(user2_claimable.purchased == user2_amount, 1);
        assert!(user3_claimable.purchased == user3_amount, 2);
        // assert!(user1_claimable.refund == 0, 3);
        // assert!(user2_claimable.refund == 50000, 4);
        // assert!(user3_claimable.refund == 800000, 5);
        // assert!(user1_claimable.claimable == 25000, 6);
        // assert!(user2_claimable.claimable == 75000, 7);
        // assert!(user3_claimable.claimable == 400000, 8);

        // Users claim tokens
        claim(USER1, pool);
        claim(USER2, pool);

        // Admin withdraws purchase tokens
        debug::print(&pool);
        debug::print(&primary_fungible_store::balance(pool_address, purchase_token));
        withdraw(&admin, pool);

        claim(USER3, pool);

        // transfer loss
        let transfer_loss_events = event::emitted_events<TransferLoss>();
        debug::print(&transfer_loss_events);
        assert!(vector::length(&transfer_loss_events) == 1, 0);

        // Check final balances
        // let init_amount = 1000000000;
        // assert!(primary_fungible_store::balance(USER1, purchase_token) == init_amount - user1_amount, 9);
        // assert!(
        //     primary_fungible_store::balance(
        //         USER2,
        //         purchase_token
        //     ) == init_amount - user2_amount + user2_claimable.refund,
        //     10
        // );
        // assert!(
        //     primary_fungible_store::balance(
        //         USER3,
        //         purchase_token
        //     ) == init_amount - user3_amount + user3_claimable.refund,
        //     11
        // );
        // assert!(primary_fungible_store::balance(USER1, supply_token) == user1_claimable.claimable, 12);
        // assert!(primary_fungible_store::balance(USER2, supply_token) == user2_claimable.claimable, 13);
        // assert!(primary_fungible_store::balance(USER3, supply_token) == user3_claimable.claimable, 14);
        // assert!(primary_fungible_store::balance(ADMIN, purchase_token) == 1000000, 15);
    }

    #[test]
    #[expected_failure(abort_code = EPOOL_ALREADY_READY)]
    fun test_update_pool_after_ready() acquires Pool {
        let SetupParams { admin, user1: _, user2: _, user3: _, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        deposit_supply_token(&admin, pool, 500000);
        set_pool_ready(&admin, pool);

        // This should fail
        update_pool(
            &admin,
            pool,
            2000,
            3000,
            4000,
            2000000,
            1000000,
            2000,
        );
    }

    #[test]
    #[expected_failure(abort_code = EPOOL_NOT_READY)]
    fun test_purchase_before_ready() acquires Pool {
        let SetupParams { admin, user1, user2: _, user3: _, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        timestamp::update_global_time_for_test(1000000000);

        // This should fail
        purchase(&user1, pool, 150000);
    }

    #[test]
    #[expected_failure(abort_code = EINVALID_IDO_TIMES)]
    fun test_invalid_ido_times() {
        let SetupParams { admin, user1: _, user2: _, user3: _, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            3000, // ido_start_time > ido_end_time
            2000,
            4000,
            1000000,
            500000,
            1000,
        );
    }

    #[test]
    #[expected_failure(abort_code = EMINIMUM_PURCHASE_AMOUNT)]
    fun test_purchase_below_minimum() acquires Pool {
        let SetupParams { admin, user1, user2: _, user3: _, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        deposit_supply_token(&admin, pool, 500000);
        set_pool_ready(&admin, pool);
        timestamp::update_global_time_for_test(1000000000);

        // Try to purchase below minimum amount
        purchase(&user1, pool, 999);
    }

    #[test]
    fun test_whitelist_purchase() acquires Pool {
        let SetupParams { admin, user1, user2, user3, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        deposit_supply_token(&admin, pool, 500000);

        // Update whitelist
        let whitelist = vector::empty<address>();
        vector::push_back(&mut whitelist, USER1);
        vector::push_back(&mut whitelist, USER2);
        update_whitelist(&admin, pool, whitelist, 100000);

        set_pool_ready(&admin, pool);
        timestamp::update_global_time_for_test(1000000000);

        // Whitelisted users purchase
        purchase(&user1, pool, 100000);
        purchase(&user2, pool, 150000);

        // Non-whitelisted user purchase
        purchase(&user3, pool, 50000);

        timestamp::update_global_time_for_test(3000000000);

        // Check claimable amounts
        let user1_claimable = get_claimable_amount(USER1, pool);
        let user2_claimable = get_claimable_amount(USER2, pool);
        let user3_claimable = get_claimable_amount(USER3, pool);

        assert!(user1_claimable.claimable > user3_claimable.claimable, 0);
        assert!(user2_claimable.claimable > user3_claimable.claimable, 1);
    }

    #[test]
    #[expected_failure(abort_code = EPOOL_ALREADY_FINISHED)]
    fun test_purchase_after_ido_end() acquires Pool {
        let SetupParams { admin, user1, user2: _, user3: _, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        deposit_supply_token(&admin, pool, 500000);
        set_pool_ready(&admin, pool);

        // Set time after IDO end
        timestamp::update_global_time_for_test(2000000001);

        // Try to purchase after IDO end
        purchase(&user1, pool, 10000);
    }

    #[test]
    #[expected_failure(abort_code = ECLAIM_NOT_STARTED)]
    fun test_claim_before_claim_start() acquires Pool, ObjectController {
        let SetupParams { admin, user1, user2: _, user3: _, supply_token, purchase_token } = setup_test();

        create_pool(
            &admin,
            supply_token,
            purchase_token,
            ADMIN,
            1000,
            2000,
            3000,
            1000000,
            500000,
            1000,
        );

        let pool_created_events = event::emitted_events<PoolCreated>();
        let pool_created_event = vector::borrow(&pool_created_events, 0);
        let pool_address = pool_created_event.pool;
        let pool = object::address_to_object<Pool>(pool_address);

        deposit_supply_token(&admin, pool, 500000);
        set_pool_ready(&admin, pool);

        timestamp::update_global_time_for_test(1000000000);
        purchase(&user1, pool, 10000);

        // Try to claim before claim start time
        timestamp::update_global_time_for_test(2999999999);
        claim(USER1, pool);
    }
}
