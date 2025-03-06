// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module for managing epoch parameters for the blob storage system.
module blob_storage::epoch_parameters {

// === Error Codes ===

/// Invalid capacity.
const EInvalidCapacity: u64 = 0;
/// Invalid price.
const EInvalidPrice: u64 = 1;

// === Types ===

/// Parameters that can be voted on by validators for the next epoch.
public struct EpochParams has copy, drop, store {
    /// The total storage capacity for the next epoch.
    capacity: u64,
    /// The price per unit size for storage.
    storage_price: u64,
    /// The price per unit size for writing.
    write_price: u64,
}

// === Constructor ===

/// Creates a new set of epoch parameters.
public(package) fun new(
    capacity: u64,
    storage_price: u64,
    write_price: u64,
): EpochParams {
    assert!(capacity > 0, EInvalidCapacity);
    assert!(storage_price > 0, EInvalidPrice);
    assert!(write_price > 0, EInvalidPrice);
    
    EpochParams {
        capacity,
        storage_price,
        write_price,
    }
}

// === Accessors ===

/// Gets the total storage capacity.
public fun capacity(self: &EpochParams): u64 {
    self.capacity
}

/// Gets the price per unit size for storage.
public fun storage_price(self: &EpochParams): u64 {
    self.storage_price
}

/// Gets the price per unit size for writing.
public fun write_price(self: &EpochParams): u64 {
    self.write_price
}

// === Testing Functions ===

#[test_only]
public fun create_for_testing(
    capacity: u64,
    storage_price: u64,
    write_price: u64,
): EpochParams {
    new(capacity, storage_price, write_price)
}
}