// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module blob_storage::client {
    use std::hash;
    use std::vector;
    
    use mys::{coin::Coin, object::ID};
    use mys::mys::MYS;
    use blob_storage::{
        system::{Self, BlobStorageState},
        blob::{Self, Blob},
        storage_resource::Storage,
        storage_node::StorageNodeCap
    };

    // Error codes
    const EInvalidBlobData: u64 = 0;
    const EInsufficientPayment: u64 = 1;
    
    /// Convenience function to store data directly with a single call
    /// Handles storage reservation and blob registration in one transaction
    public entry fun store_data(
        state: &mut BlobStorageState,
        data: vector<u8>,
        epochs_ahead: u32,
        storage_payment: &mut Coin<MYS>,
        write_payment: &mut Coin<MYS>,
        ctx: &mut TxContext
    ) {
        // Calculate the size needed for the data and compute the blob ID
        let size = vector::length(&data);
        let blob_id = calculate_blob_id(data);
        
        // Reserve storage space
        let storage = system::reserve_space(
            state,
            size,
            epochs_ahead,
            storage_payment,
            ctx
        );
        
        // Register the blob - using default encoding type (0) and making it deletable
        let blob = register_blob_with_id(
            state,
            storage,
            blob_id, 
            data,
            true, // deletable
            write_payment,
            ctx
        );
        
        // Transfer the blob to the sender
        transfer::public_transfer(blob, ctx.sender());
    }
    
    /// Store blob data with more control over parameters
    public fun store_data_with_options(
        state: &mut BlobStorageState,
        data: vector<u8>,
        epochs_ahead: u32,
        encoding_type: u8,
        deletable: bool,
        storage_payment: &mut Coin<MYS>,
        write_payment: &mut Coin<MYS>,
        ctx: &mut TxContext
    ): Blob {
        // Calculate the size needed for the data and compute the blob ID
        let size = vector::length(&data);
        let blob_id = calculate_blob_id(data);
        
        // Reserve storage space
        let storage = system::reserve_space(
            state,
            size,
            epochs_ahead,
            storage_payment,
            ctx
        );
        
        // Register the blob with the specified parameters
        register_blob_with_id(
            state,
            storage,
            blob_id,
            data,
            deletable,
            write_payment,
            ctx
        )
    }
    
    /// Helper to register a blob with a calculated ID based on content
    public fun register_blob_with_id(
        state: &mut BlobStorageState,
        storage: Storage,
        blob_id: u256,
        data: vector<u8>,
        deletable: bool,
        write_payment: &mut Coin<MYS>,
        ctx: &mut TxContext
    ): Blob {
        // Calculate a simple root hash based on the data (in production, use a proper Merkle root)
        let root_hash = calculate_root_hash(data);
        let size = vector::length(&data);
        
        // Default encoding type is 0 (raw data)
        let encoding_type: u8 = 0;
        
        // Register the blob using state interface
        system::register_blob(
            state,
            storage,
            blob_id,
            root_hash,
            size,
            encoding_type,
            deletable,
            write_payment,
            ctx
        )
    }
    
    /// Calculate a blob ID from the data contents
    public fun calculate_blob_id(data: vector<u8>): u256 {
        // Using SHA3-256 hash of data as the blob ID
        let hash_bytes = hash::sha3_256(data);
        
        // Convert the hash bytes to a u256
        let mut blob_id: u256 = 0;
        let mut i = 0;
        let n = vector::length(&hash_bytes);
        
        while (i < n && i < 32) {
            let byte = (*vector::borrow(&hash_bytes, i) as u256);
            let shift_amount = ((31 - i) * 8) as u8;
            blob_id = blob_id | (byte << shift_amount);
            i = i + 1;
        };
        
        blob_id
    }
    
    /// Calculate a simple root hash for a blob
    /// In a production system, this would be a proper Merkle tree root
    public fun calculate_root_hash(data: vector<u8>): u256 {
        // For simplicity, we're using the same hash algorithm as for blob_id
        // In a real implementation, this would be a proper Merkle root
        calculate_blob_id(data)
    }
    
    /// Extend a blob's storage period
    public entry fun extend_storage_period(
        state: &mut BlobStorageState,
        blob: &mut Blob,
        extended_epochs: u32,
        payment: &mut Coin<MYS>
    ) {
        system::extend_blob(state, blob, extended_epochs, payment);
    }
    
    /// Helper function to calculate the required storage payment for a given size and epoch count
    public fun calculate_storage_payment(
        state: &BlobStorageState,
        size: u64,
        epochs: u32
    ): u64 {
        // This is a simplified calculation - actual implementation would match system_state_inner logic
        let unit_price = 1_000_000; // 1 MYS per MiB per epoch
        let unit_size = 1024 * 1024; // 1 MiB
        
        // Calculate storage units (rounding up)
        let storage_units = if (size % unit_size == 0) {
            size / unit_size
        } else {
            (size / unit_size) + 1
        };
        
        unit_price * storage_units * (epochs as u64)
    }
    
    /// Helper function to calculate the required write payment for a given size
    public fun calculate_write_payment(
        state: &BlobStorageState,
        size: u64
    ): u64 {
        // This is a simplified calculation - actual implementation would match system_state_inner logic
        let unit_price = 500_000; // 0.5 MYS per MiB 
        let unit_size = 1024 * 1024; // 1 MiB
        
        // Calculate storage units (rounding up)
        let storage_units = if (size % unit_size == 0) {
            size / unit_size
        } else {
            (size / unit_size) + 1
        };
        
        unit_price * storage_units
    }
    
    /// Function for validators to call to register themselves as storage nodes
    public entry fun register_as_storage_node(
        state: &mut BlobStorageState,
        ctx: &mut TxContext
    ) {
        system::register_storage_node(state, ctx);
    }
    
    /// Function to certify a blob once it's been properly stored
    /// This would typically be called by a storage node
    public entry fun certify_stored_blob(
        state: &mut BlobStorageState,
        blob: &mut Blob,
        signature: vector<u8>,
        signers_bitmap: vector<u8>,
        message: vector<u8>
    ) {
        system::certify_blob(state, blob, signature, signers_bitmap, message);
    }
    
    // Additional convenience accessors
    
    /// Get the current epoch
    public fun current_epoch(state: &BlobStorageState): u32 {
        system::epoch(state)
    }
    
    /// Check if a blob is certified
    public fun is_blob_certified(blob: &Blob): bool {
        blob::is_certified(blob)
    }
    
    /// Get the remaining valid epochs for a blob
    public fun blob_remaining_epochs(blob: &Blob, state: &BlobStorageState): u32 {
        let end_epoch = blob::end_epoch(blob);
        let current_epoch = system::epoch(state);
        
        if (end_epoch <= current_epoch) {
            0
        } else {
            end_epoch - current_epoch
        }
    }
}