// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module implements the accounting for the storage system across epochs.
module blob_storage::storage_accounting {

use mys::balance::{Self, Balance};
use mys::mys::MYS;

// Error codes
/// Invalid epoch for the accounting.
const EInvalidEpoch: u64 = 0;

/// Accounting for a specific epoch.
public struct EpochAccounting has store {
    /// Epoch for which this accounting is valid.
    epoch: u32,
    /// Total capacity used for this epoch.
    used_capacity: u64,
    /// Collected rewards for storage in this epoch.
    rewards: Balance<MYS>,
}

/// Ring buffer for future accounting.
/// Contains the accounting for the current epoch and future epochs.
public struct FutureAccountingRingBuffer has store {
    /// Ring buffer for accounting data.
    epochs: vector<EpochAccounting>,
    /// Maximum number of epochs ahead that can be stored.
    max_epochs_ahead: u32,
    /// Current head of the ring buffer, corresponding to the current epoch.
    head: u32,
}

// === Constructors ===

/// Create a new epoch accounting object.
public(package) fun new_epoch_accounting(epoch: u32): EpochAccounting {
    EpochAccounting {
        epoch,
        used_capacity: 0,
        rewards: balance::zero(),
    }
}

/// Create a new ring buffer for future accounting.
public(package) fun ring_new(max_epochs_ahead: u32): FutureAccountingRingBuffer {
    let mut epochs = vector[];
    let i = 0;
    while (i <= max_epochs_ahead) {
        epochs.push_back(new_epoch_accounting(i));
        i = i + 1;
    };
    
    FutureAccountingRingBuffer {
        epochs,
        max_epochs_ahead,
        head: 0,
    }
}

// === Accessors ===

/// Get the epoch for the accounting.
public fun epoch(self: &EpochAccounting): u32 {
    self.epoch
}

/// Get the used capacity for the accounting.
public fun used_capacity(self: &EpochAccounting): u64 {
    self.used_capacity
}

/// Get the rewards balance for the accounting.
public fun rewards_balance(self: &mut EpochAccounting): &mut Balance<MYS> {
    &mut self.rewards
}

/// Increases the used capacity for this epoch by `amount`.
/// Returns the new used capacity.
public fun increase_used_capacity(self: &mut EpochAccounting, amount: u64): u64 {
    self.used_capacity = self.used_capacity + amount;
    self.used_capacity
}

/// Decreases the used capacity for this epoch by `amount`.
/// Returns the new used capacity.
public fun decrease_used_capacity(self: &mut EpochAccounting, amount: u64): u64 {
    self.used_capacity = self.used_capacity - amount;
    self.used_capacity
}

/// Unwrap the rewards balance from the accounting.
public fun unwrap_balance(self: &mut EpochAccounting): Balance<MYS> {
    balance::withdraw_all(&mut self.rewards)
}

// === Ring Buffer Operations ===

/// Get the maximum number of epochs ahead in the ring buffer.
public fun max_epochs_ahead(self: &FutureAccountingRingBuffer): u32 {
    self.max_epochs_ahead
}

/// Look up epoch accounting at offset `offset` from the head of the ring buffer.
/// Offset 0 is the head of the ring, i.e., current epoch's accounting.
public fun ring_lookup(
    self: &FutureAccountingRingBuffer,
    offset: u32,
): &EpochAccounting {
    assert!(offset <= self.max_epochs_ahead, EInvalidEpoch);
    let idx = (self.head + offset) % (self.max_epochs_ahead + 1);
    &self.epochs[idx]
}

/// Look up epoch accounting at offset `offset` from the head of the ring buffer.
/// Offset 0 is the head of the ring, i.e., current epoch's accounting.
public fun ring_lookup_mut(
    self: &mut FutureAccountingRingBuffer,
    offset: u32,
): &mut EpochAccounting {
    assert!(offset <= self.max_epochs_ahead, EInvalidEpoch);
    let idx = (self.head + offset) % (self.max_epochs_ahead + 1);
    &mut self.epochs[idx]
}

/// Pop the current accounting from the head of the ring and expand the ring to
/// include accounting for an additional future epoch.
/// Returns the current epoch's accounting.
public fun ring_pop_expand(self: &mut FutureAccountingRingBuffer): EpochAccounting {
    // Extract and process the accounting from the head
    let current_idx = self.head;
    let current_epoch = self.epochs[current_idx].epoch;
    
    // Need to replace the current accounting with a future one
    let future_epoch = current_epoch + self.max_epochs_ahead + 1;
    let replacement = new_epoch_accounting(future_epoch);
    
    // Swap out the old accounting and update the head
    let current_accounting = std::vector::swap_remove(&mut self.epochs, current_idx);
    self.epochs.push_back(replacement);
    
    // Move the head to the next accounting
    self.head = (self.head + 1) % (self.max_epochs_ahead + 1);
    
    current_accounting
}

#[test_only]
use mys::test_utils::assert_eq;

#[test]
fun test_ring_buffer() {
    let max_epochs_ahead = 3;
    let mut ring = ring_new(max_epochs_ahead);
    
    // Check initial state
    assert_eq!(ring.max_epochs_ahead(), max_epochs_ahead);
    assert_eq!(ring.ring_lookup(0).epoch(), 0);
    assert_eq!(ring.ring_lookup(1).epoch(), 1);
    assert_eq!(ring.ring_lookup(2).epoch(), 2);
    assert_eq!(ring.ring_lookup(3).epoch(), 3);
    
    // Test lookup_mut by updating capacities
    ring.ring_lookup_mut(0).increase_used_capacity(100);
    ring.ring_lookup_mut(1).increase_used_capacity(200);
    ring.ring_lookup_mut(2).increase_used_capacity(300);
    ring.ring_lookup_mut(3).increase_used_capacity(400);
    
    assert_eq!(ring.ring_lookup(0).used_capacity(), 100);
    assert_eq!(ring.ring_lookup(1).used_capacity(), 200);
    assert_eq!(ring.ring_lookup(2).used_capacity(), 300);
    assert_eq!(ring.ring_lookup(3).used_capacity(), 400);
    
    // Test pop_expand
    let accounting = ring.ring_pop_expand();
    assert_eq!(accounting.epoch(), 0);
    assert_eq!(accounting.used_capacity(), 100);
    
    // Check that the head moved and a new future epoch was added
    assert_eq!(ring.ring_lookup(0).epoch(), 1);
    assert_eq!(ring.ring_lookup(1).epoch(), 2);
    assert_eq!(ring.ring_lookup(2).epoch(), 3);
    assert_eq!(ring.ring_lookup(3).epoch(), 4);
    
    assert_eq!(ring.ring_lookup(0).used_capacity(), 200);
    assert_eq!(ring.ring_lookup(1).used_capacity(), 300);
    assert_eq!(ring.ring_lookup(2).used_capacity(), 400);
    assert_eq!(ring.ring_lookup(3).used_capacity(), 0);
}
}