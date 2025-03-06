// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module blob_storage::integration_test {
    use mys::test_scenario::{Self, Scenario};
    use mys::coin::{Self, Coin};
    use mys::mys::MYS;
    use mys::test_utils::assert_eq;
    use mys_system::mys_system_state_inner::SystemParameters;
    use mys_system::mys_system::MysSystemState;
    use mys_system::validator_set::ValidatorSet;
    use mys_system::validator::Validator;
    
    use blob_storage::{
        system::{Self, BlobStorageState},
        blob::{Self, Blob},
        storage_resource::Storage,
        storage_node::StorageNodeCap
    };

    // Test constants
    const VALIDATOR_ADDR_1: address = @0x1;
    const VALIDATOR_ADDR_2: address = @0x2;
    const USER_ADDR: address = @0x3;
    const EPOCH_DURATION_MS: u64 = 86400000; // 1 day in milliseconds

    // Create a test scenario with a MYS system and blob storage system
    public fun setup_test_with_blob_storage(): Scenario {
        let scenario = test_scenario::begin(VALIDATOR_ADDR_1);
        let ctx = test_scenario::ctx(&mut scenario);
        
        // Create genesis validators
        let validators = vector[
            create_validator(VALIDATOR_ADDR_1, 100, ctx),
            create_validator(VALIDATOR_ADDR_2, 100, ctx)
        ];
        
        // Create a MYS system
        create_mys_system(validators, ctx);
        
        // Initialize blob storage system
        test_scenario::next_tx(&mut scenario, VALIDATOR_ADDR_1);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            system::initialize(104, ctx); // 104 epochs ahead (2 years)
        };
        
        scenario
    }
    
    // Create a test validator with given stake amount
    fun create_validator(addr: address, stake: u64, ctx: &mut TxContext): Validator {
        // This is a simplification - would need proper validator setup with keys
        // In a real test, we would need to setup proper validator metadata
        Validator {
            mys_address: addr,
            protocol_pubkey_bytes: vector[1, 2, 3], // Dummy bytes
            network_pubkey_bytes: vector[1, 2, 3], // Dummy bytes
            worker_pubkey_bytes: vector[1, 2, 3], // Dummy bytes
            proof_of_possession: vector[1, 2, 3], // Dummy bytes
            name: b"Test Validator",
            description: b"Test Validator Description",
            image_url: b"https://example.com/image.png",
            project_url: b"https://example.com",
            net_address: b"127.0.0.1:8080",
            p2p_address: b"127.0.0.1:8080",
            primary_address: b"127.0.0.1:8080",
            worker_address: b"127.0.0.1:8080",
            gas_price: 1000,
            commission_rate: 1000,
            next_epoch_stake: stake,
            next_epoch_gas_price: 1000,
            next_epoch_commission_rate: 1000,
            verified: true,
            extra_fields: object::new(ctx)
        }
    }
    
    // Create a MYS system state for testing
    fun create_mys_system(validators: vector<Validator>, ctx: &mut TxContext) {
        // Create storage fund
        let storage_fund = balance::create_for_testing<MYS>(1000000000);
        
        // Create system parameters
        let parameters = SystemParameters {
            epoch_duration_ms: EPOCH_DURATION_MS,
            stake_subsidy_start_epoch: 0,
            max_validator_count: 100,
            min_validator_joining_stake: 1,
            validator_low_stake_threshold: 0,
            validator_very_low_stake_threshold: 0,
            validator_low_stake_grace_period: 0,
        };
        
        // Create stake subsidy
        let stake_subsidy = mys_system::stake_subsidy::create_for_testing();
        
        // Create MYS system state
        let mys_system_id = object::id_from_address(@0x5);
        let mys_system_id = object::new_with_id(mys_system_id, ctx);
        
        mys_system::mys_system::create(
            mys_system_id,
            validators,
            storage_fund,
            1, // Protocol version
            1000, // Epoch start timestamp
            parameters,
            stake_subsidy,
            ctx
        );
    }
    
    #[test]
    fun test_blob_storage_epoch_integration() {
        let mut scenario = setup_test_with_blob_storage();
        
        // Register validator as storage node
        test_scenario::next_tx(&mut scenario, VALIDATOR_ADDR_1);
        {
            let state = test_scenario::take_shared<BlobStorageState>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            system::register_storage_node(&mut state, ctx);
            
            test_scenario::return_shared(state);
        };
        
        // User creates a storage resource and blob
        test_scenario::next_tx(&mut scenario, USER_ADDR);
        {
            let state = test_scenario::take_shared<BlobStorageState>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create payment coins
            let storage_payment = coin::mint_for_testing<MYS>(10000000, ctx);
            let write_payment = coin::mint_for_testing<MYS>(5000000, ctx);
            
            // Reserve storage space
            let storage = system::reserve_space(
                &mut state, 
                1024 * 1024, // 1MB
                10, // 10 epochs
                &mut storage_payment,
                ctx
            );
            
            // Register a blob
            let blob = system::register_blob(
                &mut state,
                storage,
                0x123456, // Blob ID
                0x654321, // Root hash
                1024 * 1024, // 1MB size
                0, // Raw encoding
                true, // Deletable
                &mut write_payment,
                ctx
            );
            
            // Transfer the blob to the user
            transfer::public_transfer(blob, USER_ADDR);
            
            // Destroy payment coins
            coin::burn_for_testing(storage_payment);
            coin::burn_for_testing(write_payment);
            
            test_scenario::return_shared(state);
        };
        
        // Advance epoch
        test_scenario::next_tx(&mut scenario, @0x0); // 0x0 is the system address
        {
            let system_state = test_scenario::take_shared<MysSystemState>(&scenario);
            let blob_state = test_scenario::take_shared<BlobStorageState>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create storage reward
            let storage_reward = balance::create_for_testing<MYS>(1000000);
            let computation_reward = balance::create_for_testing<MYS>(1000000);
            
            // Advance epoch in MYS system
            let storage_rebate = mys_system::mys_system::advance_epoch_for_testing(
                &mut system_state,
                1, // new epoch
                1, // protocol version
                1000000, // storage charge
                1000000, // computation charge
                100000, // storage rebate
                10000, // non-refundable storage fee
                5000, // storage fund reinvest rate
                1000, // reward slashing rate
                2000, // epoch start timestamp
                ctx
            );
            
            // Check that blob storage state advanced
            let current_epoch = system::epoch(&blob_state);
            assert_eq(current_epoch, 1);
            
            // Cleanup
            balance::destroy_for_testing(storage_rebate);
            
            test_scenario::return_shared(system_state);
            test_scenario::return_shared(blob_state);
        };
        
        // User can use their blob in the new epoch
        test_scenario::next_tx(&mut scenario, USER_ADDR);
        {
            let state = test_scenario::take_shared<BlobStorageState>(&scenario);
            let blob = test_scenario::take_from_sender<Blob>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create payment for extension
            let payment = coin::mint_for_testing<MYS>(5000000, ctx);
            
            // Extend the blob storage period
            system::extend_blob(&mut state, &mut blob, 5, &mut payment);
            
            // Check that the blob is still valid
            let is_certified = blob::is_certified(&blob);
            assert!(!is_certified, 0); // It's not certified yet
            
            // Return objects
            test_scenario::return_to_sender(&scenario, blob);
            test_scenario::return_shared(state);
            
            // Destroy payment coin
            coin::burn_for_testing(payment);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_storage_node_capabilities() {
        let mut scenario = setup_test_with_blob_storage();
        
        // Register validator as storage node
        test_scenario::next_tx(&mut scenario, VALIDATOR_ADDR_1);
        {
            let state = test_scenario::take_shared<BlobStorageState>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            system::register_storage_node(&mut state, ctx);
            
            test_scenario::return_shared(state);
        };
        
        // Validator can use storage node capabilities
        test_scenario::next_tx(&mut scenario, VALIDATOR_ADDR_1);
        {
            let state = test_scenario::take_shared<BlobStorageState>(&scenario);
            let cap = test_scenario::take_from_sender<StorageNodeCap>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Validators would certify event blobs
            // This is a simplified simulation
            let node_id = cap.node_id();
            assert_eq(node_id, object::id_from_address(VALIDATOR_ADDR_1));
            
            test_scenario::return_to_sender(&scenario, cap);
            test_scenario::return_shared(state);
        };
        
        test_scenario::end(scenario);
    }
}