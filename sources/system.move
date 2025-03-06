// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// BlobStorage System Module
/// 
/// This module serves as the main interface for the blob storage system.
/// It manages the global blob storage state and provides functions to:
/// - Reserve storage space
/// - Register blobs
/// - Delete blobs
/// - Extend blob storage
/// - Certify blobs
/// - Register and manage storage nodes
/// 
/// It is integrated with the MYS epoch system to ensure proper epoch
/// progression and committee changes.
module blob_storage::system {

use mys::{balance::Balance, coin::Coin, vec_map::{Self, VecMap}};
use mys::mys::MYS;
use mys_system::validator_set::ValidatorSet;
use mys_system::validator::Validator;
use blob_storage::{
    blob::{Self, Blob},
    storage_resource::{Self, Storage},
    storage_accounting::{Self, EpochAccounting, FutureAccountingRingBuffer},
    bls_aggregate::{Self, BlsCommittee},
    storage_node::{Self, StorageNodeCap, EventBlobAttestation},
    messages::{Self, CertifiedMessage},
    event_blob::{Self, EventBlobCertificationState},
    epoch_parameters::{Self, EpochParams},
    system_state_inner::{Self, SystemStateInner},
    events
};

// Default values for storage parameters that can be adjusted per epoch
const DEFAULT_CAPACITY: u64 = 1_099_511_627_776; // 1 TiB
const DEFAULT_STORAGE_PRICE: u64 = 1_000_000; // 1 MYS per MiB per epoch
const DEFAULT_WRITE_PRICE: u64 = 500_000; // 0.5 MYS per MiB per write

/// Object containing the system resource.
public struct BlobStorageState has key {
    id: UID,
    inner: SystemStateInner,
}

// Error codes
const ENotSystemAddress: u64 = 0;
const ENotInitialized: u64 = 1;

/// Initialize the blob storage system as a singleton at the blob_storage module address
public fun initialize(
    max_epochs_ahead: u32,
    ctx: &mut TxContext
) {
    assert!(!exists<BlobStorageState>(@blob_storage), ENotInitialized);
    
    let inner = system_state_inner::create_empty(max_epochs_ahead, ctx);
    let id = object::new(ctx);
    
    let state = BlobStorageState {
        id,
        inner,
    };
    
    transfer::transfer(state, @blob_storage);
    events::emit_system_initialized(0); // Start at epoch 0
}

/// Reserve space in the blob storage system for a set period
public entry fun reserve_space(
    state: &mut BlobStorageState,
    storage_amount: u64,
    epochs_ahead: u32,
    payment: &mut Coin<MYS>,
    ctx: &mut TxContext,
) {
    let storage = state.inner.reserve_space(storage_amount, epochs_ahead, payment, ctx);
    transfer::public_transfer(storage, ctx.sender());
}

/// Register a new blob with the system
public entry fun register_blob(
    state: &mut BlobStorageState,
    storage: Storage,
    blob_id: u256,
    root_hash: u256,
    size: u64, 
    encoding_type: u8,
    deletable: bool,
    write_payment: &mut Coin<MYS>,
    ctx: &mut TxContext,
) {
    let blob = state.inner.register_blob(
        storage,
        blob_id,
        root_hash,
        size,
        encoding_type,
        deletable,
        write_payment,
        ctx
    );
    transfer::public_transfer(blob, ctx.sender());
}

/// Delete a blob and returns its storage resource to the caller
public entry fun delete_blob(
    state: &mut BlobStorageState,
    blob: Blob,
    ctx: &mut TxContext,
) {
    let storage = state.inner.delete_blob(blob);
    transfer::public_transfer(storage, ctx.sender());
}

/// Extend a blob's storage duration
public entry fun extend_blob(
    state: &mut BlobStorageState,
    blob: &mut Blob,
    extended_epochs: u32,
    payment: &mut Coin<MYS>,
) {
    state.inner.extend_blob(blob, extended_epochs, payment);
}

/// Submit a certification for a blob
public entry fun certify_blob(
    state: &mut BlobStorageState,
    blob: &mut Blob,
    signature: vector<u8>,
    signers_bitmap: vector<u8>,
    message: vector<u8>,
) {
    state.inner.certify_blob(blob, signature, signers_bitmap, message);
}

/// Invalidate a blob with a certificate
public entry fun invalidate_blob(
    state: &mut BlobStorageState,
    signature: vector<u8>,
    members_bitmap: vector<u8>,
    message: vector<u8>,
) {
    state.inner.invalidate_blob_id(signature, members_bitmap, message);
}

/// Update the deny list for a storage node
public entry fun update_deny_list(
    state: &mut BlobStorageState,
    cap: &mut StorageNodeCap,
    signature: vector<u8>,
    members_bitmap: vector<u8>,
    message: vector<u8>,
) {
    state.inner.update_deny_list(cap, signature, members_bitmap, message);
}

/// Certify an event blob
public entry fun certify_event_blob(
    state: &mut BlobStorageState,
    cap: &mut StorageNodeCap,
    blob_id: u256,
    root_hash: u256,
    size: u64,
    encoding_type: u8,
    ending_checkpoint_sequence_num: u64,
    epoch: u32,
    ctx: &mut TxContext,
) {
    state.inner.certify_event_blob(
        cap,
        blob_id,
        root_hash,
        size,
        encoding_type,
        ending_checkpoint_sequence_num,
        epoch,
        ctx
    );
}

/// Create a new committee based on the MYS validator set
public fun create_committee_from_validator_set(
    validator_set: &ValidatorSet,
    epoch: u32,
    ctx: &mut TxContext,
): (BlsCommittee, EpochParams) {
    // Extract active validator public keys and stakes
    let validators = validator_set.active_validators();
    let mut i = 0;
    let n = vector::length(&validators);
    
    // Prepare committee members and weights
    let mut committee_members = vector::empty<ID>();
    let mut committee_weights = vector::empty<u64>();
    
    while (i < n) {
        let validator = vector::borrow(&validators, i);
        let validator_address = validator.mys_address();
        
        // Use validator's ID as the committee member ID
        // In a real implementation, you'd use BLS public key derived from validator info
        let validator_id = object::id_from_address(validator_address);
        let validator_stake = validator.stake_amount();
        
        vector::push_back(&mut committee_members, validator_id);
        vector::push_back(&mut committee_weights, validator_stake);
        
        i = i + 1;
    };
    
    // Create committee with the collected members and weights
    let committee = bls_aggregate::new_bls_committee_weighted(
        epoch,
        committee_members,
        committee_weights
    );
    
    // Create epoch parameters based on current system state or configuration
    let params = epoch_parameters::new(
        DEFAULT_CAPACITY,
        DEFAULT_STORAGE_PRICE,
        DEFAULT_WRITE_PRICE
    );
    
    (committee, params)
}

/// Advance the epoch for the blob storage system
/// Called from the MYS system at epoch boundaries
public(package) fun advance_epoch(
    state: &mut BlobStorageState,
    new_committee: BlsCommittee,
    new_epoch_params: &EpochParams,
    ctx: &mut TxContext,
) {
    // Validator will make a special system call with sender set as 0x0.
    assert!(ctx.sender() == @0x0, ENotSystemAddress);
    
    // Advance the epoch in the inner state
    let reward_distribution = state.inner.advance_epoch(new_committee, new_epoch_params);
    
    // Process the reward distribution to validators
    // In a real implementation, this would transfer rewards to validators
    let (reward_ids, reward_balances) = vec_map::into_keys_values(reward_distribution);
    let n = vector::length(&reward_ids);
    let mut i = 0;
    
    while (i < n) {
        let validator_id = vector::pop_back(&mut reward_ids);
        let reward_balance = vector::pop_back(&mut reward_balances);
        
        // In production code, these would be transferred to validators
        // Here we just burn them as they're already accounted for in the MYS system
        balance::destroy_for_testing(reward_balance);
        
        i = i + 1;
    };
    
    // Emit epoch change event
    events::emit_epoch_changed(state.inner.epoch());
}

/// Create a new StorageNodeCap for a validator
public entry fun register_storage_node(
    state: &mut BlobStorageState,
    ctx: &mut TxContext,
) {
    // Verify the caller is a validator in the active set
    // This would need validation in a real implementation
    
    // Create a new storage node capability tied to the sender
    let sender_addr = ctx.sender();
    let sender_id = object::id_from_address(sender_addr);
    
    let cap = storage_node::new_storage_node_cap(
        sender_id,
        0, // Initial deny list root
        0, // Initial sequence number
        0, // Initial size
        ctx
    );
    
    // Transfer the capability to the sender
    transfer::public_transfer(cap, sender_addr);
}

/// Convenience function to store a blob in a single transaction
/// This function handles storage reservation and blob registration
public entry fun store_blob(
    state: &mut BlobStorageState,
    blob_id: u256,
    root_hash: u256,
    size: u64,
    encoding_type: u8,
    deletable: bool,
    epochs_ahead: u32,
    storage_payment: &mut Coin<MYS>,
    write_payment: &mut Coin<MYS>,
    ctx: &mut TxContext,
) {
    // Reserve storage
    let storage = reserve_space(
        state,
        size,
        epochs_ahead,
        storage_payment,
        ctx
    );
    
    // Register blob
    let blob = register_blob(
        state,
        storage,
        blob_id,
        root_hash,
        size,
        encoding_type,
        deletable,
        write_payment,
        ctx
    );
    
    // Transfer to sender
    transfer::public_transfer(blob, ctx.sender());
}

/// Calculate the storage payment required for a given size and epoch count
public fun calculate_storage_payment(size: u64, epochs: u32): u64 {
    // Convert size to storage units (MiB, rounded up)
    let storage_units = if (size % (1024 * 1024) == 0) {
        size / (1024 * 1024)
    } else {
        (size / (1024 * 1024)) + 1
    };
    
    // Calculate the payment amount
    DEFAULT_STORAGE_PRICE * storage_units * (epochs as u64)
}

/// Calculate the write payment required for a given size
public fun calculate_write_payment(size: u64): u64 {
    // Convert size to storage units (MiB, rounded up)
    let storage_units = if (size % (1024 * 1024) == 0) {
        size / (1024 * 1024)
    } else {
        (size / (1024 * 1024)) + 1
    };
    
    // Calculate the payment amount
    DEFAULT_WRITE_PRICE * storage_units
}

// === Accessors ===

/// Get the current epoch
public fun epoch(state: &BlobStorageState): u32 {
    state.inner.epoch()
}

/// Get the current capacity
public fun total_capacity(state: &BlobStorageState): u64 {
    state.inner.total_capacity_size()
}

/// Get the currently used capacity
public fun used_capacity(state: &BlobStorageState): u64 {
    state.inner.used_capacity_size()
}

/// Get the number of shards in the current committee
public fun n_shards(state: &BlobStorageState): u16 {
    state.inner.n_shards()
}

#[test_only]
/// Create a blob storage state for testing
public fun create_for_testing(ctx: &mut TxContext): BlobStorageState {
    let inner = system_state_inner::create_for_testing();
    let id = object::new(ctx);
    
    BlobStorageState {
        id,
        inner,
    }
}
}