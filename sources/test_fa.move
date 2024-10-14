module MovernancePad::TestFA {
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use aptos_std::table::{Self, Table};
    use aptos_framework::fungible_asset;
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;

    // Error codes
    const ENOT_CREATOR: u64 = 1;
    const EFA_NOT_FOUND: u64 = 2;
    const EFA_ALREADY_EXISTS: u64 = 3;

    // Struct to store mint and transfer refs
    struct FARef has store {
        mint_ref: fungible_asset::MintRef,
        burn_ref: fungible_asset::BurnRef,
        transfer_ref: fungible_asset::TransferRef,
    }

    struct FACapabilities has key {
        fa_refs: Table<address, FARef>,
        symbol_to_address: Table<String, address>,
    }

    fun init_module(creator: &signer) {
        move_to(creator, FACapabilities {
            fa_refs: table::new(),
            symbol_to_address: table::new(),
        });
    }

    // Initialize a new fungible asset
    public entry fun create_fa(
        creator: &signer,
        name: String,
        symbol: String,
        decimals: u8,
    ) acquires FACapabilities {
        let caps = borrow_global_mut<FACapabilities>(@MovernancePad);
        if (table::contains(&caps.symbol_to_address, symbol)) {
            return
        };
        let constructor_ref = object::create_sticky_object(signer::address_of(creator));
        let metadata_address = object::address_from_constructor_ref(&constructor_ref);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            name,
            symbol,
            decimals,
            string::utf8(b""), // icon_uri
            string::utf8(b"")  // project_uri
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);

        table::add(&mut caps.fa_refs, metadata_address, FARef {
            mint_ref,
            burn_ref,
            transfer_ref,
        });
        table::add(&mut caps.symbol_to_address, symbol, metadata_address);
    }

    // Mint fungible assets (permissionless)
    public entry fun mint(account: &signer, symbol: String, amount: u64) acquires FACapabilities {
        let caps = borrow_global<FACapabilities>(@MovernancePad);
        assert!(table::contains(&caps.symbol_to_address, symbol), EFA_NOT_FOUND);
        let metadata_address = *table::borrow(&caps.symbol_to_address, symbol);
        assert!(table::contains(&caps.fa_refs, metadata_address), EFA_NOT_FOUND);
        let fa_ref = table::borrow(&caps.fa_refs, metadata_address);
        let fa = fungible_asset::mint(&fa_ref.mint_ref, amount);
        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa);
    }

    // Helper function to get metadata address by symbol
    #[view]
    public fun get_metadata_by_symbol(symbol: String): address acquires FACapabilities {
        let caps = borrow_global<FACapabilities>(@MovernancePad);
        assert!(table::contains(&caps.symbol_to_address, symbol), EFA_NOT_FOUND);
        *table::borrow(&caps.symbol_to_address, symbol)
    }

    #[test(account = @MovernancePad)]
    public fun test_create_and_mint(account: &signer) acquires FACapabilities {
        init_module(account);
        // Create a new FA
        create_fa(account, string::utf8(b"Test Asset"), string::utf8(b"TEST"), 6);

        // Check if the FA was created
        let metadata_address = get_metadata_by_symbol(string::utf8(b"TEST"));
        assert!(metadata_address != @0x0, 0);

        // Mint some tokens
        mint(account, string::utf8(b"TEST"), 1000000);

        // Check balance
        let metadata = object::address_to_object<fungible_asset::Metadata>(metadata_address);
        let balance = primary_fungible_store::balance(signer::address_of(account), metadata);
        assert!(balance == 1000000, 1);
    }

    #[test_only]
    public fun init_for_test(account: &signer) {
        init_module(account);
    }
}
