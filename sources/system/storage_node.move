// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module implementing the storage node capability for the blob storage system.
module blob_storage::storage_node {

use std::option::{Self, Option};
use std::string::String;

// === Error Codes ===

/// Node is already registered.
const EAlreadyRegistered: u64 = 0;
/// Signature verification failed.
const EInvalidSignature: u64 = 1;
/// The sender is not authorized.
const EUnauthorized: u64 = 2;

// === Types ===

/// Attestation for event blob certifications.
public struct EventBlobAttestation has copy, drop, store {
    /// The checkpoint sequence number of the last attested event blob.
    last_attested_checkpoint_seq_num: u64,
    /// The epoch of the last attestation.
    last_attested_epoch: u32,
}

/// The capability object for a storage node, owned by the storage provider.
/// This authorizes operations on behalf of a specific storage node.
public struct StorageNodeCap has key, store {
    id: UID,
    /// ID of the storage node this capability belongs to
    node_id: ID,
    /// BLS public key of the storage node
    bls_key: vector<u8>,
    /// Name of the storage node
    name: String,
    /// URL of the storage node
    url: String,
    /// The Merkle root of the node's deny list
    deny_list_root: u256,
    /// Sequence number of the last deny list update
    deny_list_sequence: u64,
    /// Size of the deny list in bytes
    deny_list_size: u64,
    /// Information about the last event blob attestation
    last_event_blob_attestation: Option<EventBlobAttestation>,
}

// === Constructor ===

/// Create a new storage node capability object.
public(package) fun new_storage_node_cap(
    node_id: ID,
    bls_key: vector<u8>,
    name: String,
    url: String,
    ctx: &mut TxContext,
): StorageNodeCap {
    StorageNodeCap {
        id: object::new(ctx),
        node_id,
        bls_key,
        name,
        url,
        deny_list_root: 0,
        deny_list_sequence: 0,
        deny_list_size: 0,
        last_event_blob_attestation: option::none(),
    }
}

// === Accessors ===

/// Get the ID of the storage node.
public fun node_id(self: &StorageNodeCap): ID {
    self.node_id
}

/// Get the BLS public key of the storage node.
public fun bls_key(self: &StorageNodeCap): &vector<u8> {
    &self.bls_key
}

/// Get the name of the storage node.
public fun name(self: &StorageNodeCap): &String {
    &self.name
}

/// Get the URL of the storage node.
public fun url(self: &StorageNodeCap): &String {
    &self.url
}

/// Get the Merkle root of the node's deny list.
public fun deny_list_root(self: &StorageNodeCap): u256 {
    self.deny_list_root
}

/// Get the sequence number of the last deny list update.
public fun deny_list_sequence(self: &StorageNodeCap): u64 {
    self.deny_list_sequence
}

/// Get the size of the deny list in bytes.
public fun deny_list_size(self: &StorageNodeCap): u64 {
    self.deny_list_size
}

/// Get the last event blob attestation.
public fun last_event_blob_attestation(self: &StorageNodeCap): &Option<EventBlobAttestation> {
    &self.last_event_blob_attestation
}

// === Mutators ===

/// Set the deny list properties for the storage node.
public(package) fun set_deny_list_properties(
    self: &mut StorageNodeCap,
    root: u256,
    sequence: u64,
    size: u64,
) {
    self.deny_list_root = root;
    self.deny_list_sequence = sequence;
    self.deny_list_size = size;
}

/// Set the last event blob attestation.
public(package) fun set_last_event_blob_attestation(
    self: &mut StorageNodeCap,
    attestation: EventBlobAttestation,
) {
    self.last_event_blob_attestation = option::some(attestation);
}

// === Event Blob Attestation Functions ===

/// Create a new EventBlobAttestation.
public(package) fun new_event_blob_attestation(
    checkpoint_seq_num: u64,
    epoch: u32,
): EventBlobAttestation {
    EventBlobAttestation {
        last_attested_checkpoint_seq_num: checkpoint_seq_num,
        last_attested_epoch: epoch,
    }
}

/// Get the checkpoint sequence number from an attestation.
public fun last_attested_event_blob_checkpoint_seq_num(self: &EventBlobAttestation): u64 {
    self.last_attested_checkpoint_seq_num
}

/// Get the epoch from an attestation.
public fun last_attested_event_blob_epoch(self: &EventBlobAttestation): u32 {
    self.last_attested_epoch
}

// === Testing Functions ===

#[test_only]
public fun new_storage_node_cap_for_testing(
    node_id: ID,
    bls_key: vector<u8>,
    name: String,
    url: String,
    ctx: &mut TxContext,
): StorageNodeCap {
    new_storage_node_cap(node_id, bls_key, name, url, ctx)
}
}