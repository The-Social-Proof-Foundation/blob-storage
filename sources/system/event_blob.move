// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module for handling event blob certification.
module blob_storage::event_blob {

use std::option::{Self, Option};
use mys::vec_map::{Self, VecMap};
use blob_storage::storage_node::{Self, EventBlobAttestation};

// === Error Codes ===

/// Blob is already being tracked.
const EBlobAlreadyTracked: u64 = 0;

// === Types ===

/// State for tracking event blob certification.
public struct EventBlobCertificationState has store {
    /// Map of blob_id to aggregate weight of validators attesting to it.
    attestation_weights: VecMap<u256, u16>,
    /// The latest certified checkpoint sequence number.
    latest_certified_checkpoint_sequence_number: Option<u64>,
    /// The latest certified blob ID.
    latest_certified_blob_id: Option<u256>,
}

// === Constructor ===

/// Creates a new event blob certification state with empty tracking.
public(package) fun create_with_empty_state(): EventBlobCertificationState {
    EventBlobCertificationState {
        attestation_weights: vec_map::empty(),
        latest_certified_checkpoint_sequence_number: option::none(),
        latest_certified_blob_id: option::none(),
    }
}

// === Accessors ===

/// Gets the latest certified checkpoint sequence number.
public fun get_latest_certified_checkpoint_sequence_number(
    self: &EventBlobCertificationState,
): &Option<u64> {
    &self.latest_certified_checkpoint_sequence_number
}

/// Gets the latest certified blob ID.
public fun get_latest_certified_blob_id(
    self: &EventBlobCertificationState,
): &Option<u256> {
    &self.latest_certified_blob_id
}

/// Checks if a blob ID is already being tracked for certification.
public fun is_blob_being_tracked(self: &EventBlobCertificationState, blob_id: u256): bool {
    self.attestation_weights.contains(&blob_id)
}

/// Checks if a blob is already certified.
public fun is_blob_already_certified(
    self: &EventBlobCertificationState,
    checkpoint_sequence_number: u64,
): bool {
    self.latest_certified_checkpoint_sequence_number.is_some() &&
    *self.latest_certified_checkpoint_sequence_number.borrow() == checkpoint_sequence_number
}

// === Mutators ===

/// Starts tracking a blob ID for certification.
public(package) fun start_tracking_blob(self: &mut EventBlobCertificationState, blob_id: u256) {
    if (!self.attestation_weights.contains(&blob_id)) {
        self.attestation_weights.insert(blob_id, 0);
    }
}

/// Updates the aggregate weight for a blob ID and returns the new weight.
public(package) fun update_aggregate_weight(
    self: &mut EventBlobCertificationState,
    blob_id: u256,
    weight: u16,
): u16 {
    assert!(self.attestation_weights.contains(&blob_id), EBlobAlreadyTracked);
    let current_weight = *self.attestation_weights.get(&blob_id);
    let new_weight = current_weight + weight;
    *self.attestation_weights.get_mut(&blob_id) = new_weight;
    new_weight
}

/// Updates the latest certified event blob information.
public(package) fun update_latest_certified_event_blob(
    self: &mut EventBlobCertificationState,
    checkpoint_sequence_number: u64,
    blob_id: u256,
) {
    self.latest_certified_checkpoint_sequence_number = option::some(checkpoint_sequence_number);
    self.latest_certified_blob_id = option::some(blob_id);
}

/// Resets the certification state to empty.
public(package) fun reset(self: &mut EventBlobCertificationState) {
    self.attestation_weights = vec_map::empty();
}

// === Create Attestation ===

/// Creates a new event blob attestation.
public(package) fun new_attestation(
    checkpoint_sequence_number: u64,
    epoch: u32,
): EventBlobAttestation {
    storage_node::new_event_blob_attestation(checkpoint_sequence_number, epoch)
}

// === Testing Functions ===

#[test_only]
public fun create_for_testing(): EventBlobCertificationState {
    create_with_empty_state()
}
}