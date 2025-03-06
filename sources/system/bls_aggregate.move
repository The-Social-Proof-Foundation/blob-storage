// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module implementing the BLS committee for the blob storage system.
/// The committee is responsible for verifying signatures on blob certificates.
module blob_storage::bls_aggregate {

use std::option::{Self, Option};
use mys::{bcs, bls12381, vec_map::{Self, VecMap}};
use mys::dynamic_field;
use blob_storage::messages::{Self, CertifiedMessage};

// === Constants and Errors ===

// Standard weights for Byzantine fault tolerance
const QUORUM_THRESHOLD: u16 = 6667; // 2f+1 out of 10000
const VALIDITY_THRESHOLD: u16 = 3334; // f+1 out of 10000
const TOTAL_STAKE: u16 = 10000; // Basis points - normalizing to 10000

// Error codes
/// The stake is zero.
const EZeroStake: u64 = 0;
/// The provided total stake is invalid.
const EInvalidTotalStake: u64 = 1;
/// The committee epoch does not match.
const EWrongEpoch: u64 = 2;
/// The signature verification failed.
const ESignatureVerificationFailed: u64 = 3;
/// The provided bitmap is invalid.
const EInvalidBitmap: u64 = 4;
/// Not enough stake to reach the threshold.
const EInsufficientStake: u64 = 5;
/// Invalid message type received.
const EInvalidMessageType: u64 = 6;
/// The signature is not for the provided message.
const EInvalidSignature: u64 = 7;

// === Committee Object ===

/// The committee used for blob storage consensus.
/// Represents the set of validators for a given epoch.
public struct BlsCommittee has store {
    /// The epoch number for this committee
    epoch: u32,
    /// The map from validator IDs to their weights (in basis points)
    validator_stakes: VecMap<ID, u16>,
    /// The map from validator IDs to their BLS public keys
    validator_keys: VecMap<ID, vector<u8>>,
    /// The number of shards used for blob encoding
    n_shards: u16,
}

// === Constructor ===

/// Creates a new BLS committee for the given epoch.
public(package) fun new_bls_committee(
    epoch: u32,
    validators: vector<(ID, u16, vector<u8>)>, // (node_id, stake, public_key)
): BlsCommittee {
    let mut validator_stakes = vec_map::empty();
    let mut validator_keys = vec_map::empty();
    let mut total_stake: u16 = 0;
    
    // Process each validator
    validators.do!(|(node_id, stake, public_key)| {
        assert!(stake > 0, EZeroStake);
        validator_stakes.insert(node_id, stake);
        validator_keys.insert(node_id, public_key);
        total_stake = total_stake + stake;
    });
    
    // Ensure total stake matches our expected total
    assert!(total_stake == TOTAL_STAKE, EInvalidTotalStake);
    
    BlsCommittee {
        epoch,
        validator_stakes,
        validator_keys,
        n_shards: validators.length() as u16, // Number of validators = number of shards
    }
}

// === Accessors ===

/// Gets the epoch number for this committee.
public fun epoch(self: &BlsCommittee): u32 {
    self.epoch
}

/// Gets the number of shards for this committee.
public fun n_shards(self: &BlsCommittee): u16 {
    self.n_shards
}

/// Get the map of validator IDs to their stakes.
public fun to_vec_map(self: &BlsCommittee): &VecMap<ID, u16> {
    &self.validator_stakes
}

/// Checks if a validator is part of the committee.
public fun contains(self: &BlsCommittee, validator_id: &ID): bool {
    self.validator_stakes.contains(validator_id)
}

/// Gets the weight of a validator in the committee.
public fun get_member_weight(self: &BlsCommittee, validator_id: &ID): u16 {
    *self.validator_stakes.get(validator_id)
}

/// Checks if the given stake is enough to reach the quorum threshold.
public fun is_quorum(self: &BlsCommittee, stake: u16): bool {
    stake >= QUORUM_THRESHOLD
}

/// Checks if the given stake is enough to reach the validity threshold.
public fun is_validity_threshold(self: &BlsCommittee, stake: u16): bool {
    stake >= VALIDITY_THRESHOLD
}

// === Signature Verification ===

/// Verifies a multisignature from a quorum of validators for the given message.
/// Returns a CertifiedMessage if the verification succeeds.
public fun verify_quorum_in_epoch(
    self: &BlsCommittee,
    signature: vector<u8>,
    signers_bitmap: vector<u8>,
    message: vector<u8>,
): CertifiedMessage {
    self.verify_stake_in_epoch(signature, signers_bitmap, message, QUORUM_THRESHOLD)
}

/// Verifies a multisignature from at least one correct validator for the given message.
/// Returns a CertifiedMessage if the verification succeeds.
public fun verify_one_correct_node_in_epoch(
    self: &BlsCommittee,
    signature: vector<u8>,
    signers_bitmap: vector<u8>,
    message: vector<u8>,
): CertifiedMessage {
    self.verify_stake_in_epoch(signature, signers_bitmap, message, VALIDITY_THRESHOLD)
}

/// Verifies a multisignature from validators with at least `threshold` stake for the given message.
/// Returns a CertifiedMessage if the verification succeeds.
public fun verify_stake_in_epoch(
    self: &BlsCommittee,
    signature: vector<u8>,
    signers_bitmap: vector<u8>,
    message: vector<u8>,
    threshold: u16,
): CertifiedMessage {
    // Check that the committee exists and matches the epoch
    let (public_keys, weights) = self.get_keys_and_weights(signers_bitmap);
    
    // Verify the signature
    let is_valid = bls12381::bls12381_min_sig_verify(&signature, &public_keys, &message);
    assert!(is_valid, ESignatureVerificationFailed);
    
    // Sum the weights of the signers
    let mut total_weight = 0;
    weights.do!(|weight| { total_weight = total_weight + weight; });
    
    // Check if the signers have enough stake to meet the threshold
    assert!(total_weight >= threshold, EInsufficientStake);
    
    // Create the certified message
    messages::new_certified_message(message, self.epoch, total_weight)
}

// === Internal Functions ===

/// Gets the BLS public keys and weights of validators included in the bitmap.
fun get_keys_and_weights(
    self: &BlsCommittee,
    bitmap: vector<u8>,
): (vector<vector<u8>>, vector<u16>) {
    let mut public_keys = vector[];
    let mut weights = vector[];
    let validator_ids = self.validator_stakes.keys();
    
    // Process each bit in the bitmap
    let mut i = 0;
    while (i < validator_ids.length()) {
        let byte_idx = i / 8;
        let bit_idx = i % 8;
        
        if (byte_idx < bitmap.length()) {
            let byte = bitmap[byte_idx];
            let bit_mask = 1 << bit_idx;
            
            if ((byte & bit_mask) != 0) {
                // This validator is included in the signature
                let validator_id = validator_ids[i];
                public_keys.push_back(*self.validator_keys.get(&validator_id));
                weights.push_back(*self.validator_stakes.get(&validator_id));
            };
        };
        
        i = i + 1;
    };
    
    (public_keys, weights)
}

// === Testing Functions ===

#[test_only]
public fun create_committee_for_testing(
    epoch: u32,
    validators: vector<(ID, u16, vector<u8>)>,
): BlsCommittee {
    new_bls_committee(epoch, validators)
}
}