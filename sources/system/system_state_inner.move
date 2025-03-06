// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module blob_storage::system_state_inner {

use mys::{balance::Balance, coin::Coin, vec_map::{Self, VecMap}, dynamic_field};
use mys::mys::MYS;
use blob_storage::{
    blob::{Self, Blob},
    storage_resource::{Self, Storage},
    storage_accounting::{Self, EpochAccounting, FutureAccountingRingBuffer},
    bls_aggregate::{Self, BlsCommittee},
    storage_node::{Self, StorageNodeCap, EventBlobAttestation},
    messages::{Self, CertifiedMessage},
    event_blob::{Self, EventBlobCertificationState},
    epoch_parameters::{Self, EpochParams},
    events
};

/// An upper limit for the maximum number of epochs ahead for which a blob can be registered.
/// Needed to bound the size of the `future_accounting`.
const MAX_MAX_EPOCHS_AHEAD: u32 = 1000;

// Keep in sync with the same constant in Rust code.
const BYTES_PER_UNIT_SIZE: u64 = 1_024 * 1_024; // 1 MiB

// Default values for storage
const DEFAULT_MAX_EPOCHS_AHEAD: u32 = 104; // Approximately 2 years
const DEFAULT_STORAGE_PRICE: u64 = 1_000_000; // 1 MYS per MiB per epoch
const DEFAULT_WRITE_PRICE: u64 = 500_000; // 0.5 MYS per MiB per write
const DEFAULT_CAPACITY: u64 = 1_099_511_627_776; // 1 TiB

// Field names for dynamic fields
const DF_DENY_LIST_SIZES: vector<u8> = b"deny_list_sizes";

// Error codes
/// The system parameter for the maximum number of epochs ahead is invalid.
const EInvalidMaxEpochsAhead: u64 = 0;
/// The storage capacity of the system is exceeded.
const EStorageExceeded: u64 = 1;
/// The number of epochs in the future to reserve storage for exceeds the maximum.
const EInvalidEpochsAhead: u64 = 2;
/// Invalid epoch in the certificate.
const EInvalidIdEpoch: u64 = 3;
/// Trying to set an incorrect committee for the next epoch.
const EIncorrectCommittee: u64 = 4;
/// Incorrect epoch in the storage accounting.
const EInvalidAccountingEpoch: u64 = 5;
/// Incorrect event blob attestation.
const EIncorrectAttestation: u64 = 6;
/// Repeated attestation for an event blob.
const ERepeatedAttestation: u64 = 7;
/// The node is not a member of the committee.
const ENotCommitteeMember: u64 = 8;
/// Incorrect deny list sequence number.
const EIncorrectDenyListSequence: u64 = 9;
/// Deny list certificate contains the wrong node ID.
const EIncorrectDenyListNode: u64 = 10;
/// Trying to obtain a resource with an invalid size.
const EInvalidResourceSize: u64 = 11;

/// The inner object that is not present in signatures and can be versioned.
public struct SystemStateInner has store {
    /// The current committee, with the current epoch.
    committee: BlsCommittee,
    /// Maximum capacity size for the current and future epochs.
    /// Changed by voting on the epoch parameters.
    total_capacity_size: u64,
    /// Contains the used capacity size for the current epoch.
    used_capacity_size: u64,
    /// The price per unit size of storage.
    storage_price_per_unit_size: u64,
    /// The write price per unit size.
    write_price_per_unit_size: u64,
    /// Accounting ring buffer for future epochs.
    future_accounting: FutureAccountingRingBuffer,
    /// Event blob certification state
    event_blob_certification_state: EventBlobCertificationState,
    /// Dynamic field ID for storing sizes of deny lists for storage nodes
    id: UID,
}

/// Creates an empty system state with default capacity and parameters.
public(package) fun create_empty(max_epochs_ahead: u32, ctx: &mut TxContext): SystemStateInner {
    // Validate input parameters
    assert!(max_epochs_ahead <= MAX_MAX_EPOCHS_AHEAD, EInvalidMaxEpochsAhead);
    
    // Use default max_epochs_ahead if not specified
    let max_epochs_ahead = if (max_epochs_ahead == 0) { 
        DEFAULT_MAX_EPOCHS_AHEAD 
    } else { 
        max_epochs_ahead 
    };
    
    // Create empty committee for initial epoch
    let committee = bls_aggregate::new_bls_committee(0, vector[]);
    
    // Create ring buffer for future accounting
    let future_accounting = storage_accounting::ring_new(max_epochs_ahead);
    
    // Create event blob certification state
    let event_blob_certification_state = event_blob::create_with_empty_state();
    
    // Create UID for dynamic fields
    let id = object::new(ctx);
    
    // Create deny list sizes map and add as dynamic field
    let deny_list_sizes = vec_map::empty<ID, u64>();
    dynamic_field::add(&mut id, DF_DENY_LIST_SIZES, deny_list_sizes);
    
    SystemStateInner {
        committee,
        total_capacity_size: DEFAULT_CAPACITY,
        used_capacity_size: 0,
        storage_price_per_unit_size: DEFAULT_STORAGE_PRICE,
        write_price_per_unit_size: DEFAULT_WRITE_PRICE,
        future_accounting,
        event_blob_certification_state,
        id,
    }
}

/// Initializes the system state with the specified committee and parameters.
/// This is called during system initialization.
public(package) fun initialize(
    self: &mut SystemStateInner,
    committee: BlsCommittee,
    params: &EpochParams,
) {
    // Set the committee
    self.committee = committee;
    
    // Set the parameters
    self.total_capacity_size = params.capacity();
    self.storage_price_per_unit_size = params.storage_price();
    self.write_price_per_unit_size = params.write_price();
}

// === Accessors ===

/// Get epoch from the committee.
public(package) fun epoch(self: &SystemStateInner): u32 {
    self.committee.epoch()
}

/// Accessor for total capacity size.
public(package) fun total_capacity_size(self: &SystemStateInner): u64 {
    self.total_capacity_size
}

/// Accessor for used capacity size.
public(package) fun used_capacity_size(self: &SystemStateInner): u64 {
    self.used_capacity_size
}

/// Get the number of shards from the committee.
public(package) fun n_shards(self: &SystemStateInner): u16 {
    self.committee.n_shards()
}

/// Accessor for the current committee.
public(package) fun committee(self: &SystemStateInner): &BlsCommittee {
    &self.committee
}

/// Access to deny list sizes.
fun deny_list_sizes(self: &SystemStateInner): &VecMap<ID, u64> {
    dynamic_field::borrow(&self.id, DF_DENY_LIST_SIZES)
}

/// Mutable access to deny list sizes.
fun deny_list_sizes_mut(self: &mut SystemStateInner): &mut VecMap<ID, u64> {
    dynamic_field::borrow_mut(&mut self.id, DF_DENY_LIST_SIZES)
}

// === Storage Operations ===

/// Allow buying a storage reservation for a given period of epochs.
public(package) fun reserve_space(
    self: &mut SystemStateInner,
    storage_amount: u64,
    epochs_ahead: u32,
    payment: &mut Coin<MYS>,
    ctx: &mut TxContext,
): Storage {
    // Check the period is within the allowed range.
    assert!(epochs_ahead > 0, EInvalidEpochsAhead);
    assert!(epochs_ahead <= self.future_accounting.max_epochs_ahead(), EInvalidEpochsAhead);

    // Check that the storage has a non-zero size.
    assert!(storage_amount > 0, EInvalidResourceSize);

    // Pay rewards for each future epoch into the future accounting.
    self.process_storage_payments(storage_amount, 0, epochs_ahead, payment);

    // Account the space to reclaim in the future.
    let i = 0;
    while (i < epochs_ahead) {
        let used_capacity = self
            .future_accounting
            .ring_lookup_mut(i)
            .increase_used_capacity(storage_amount);

        // For the current epoch, update the used capacity size
        if (i == 0) {
            self.used_capacity_size = used_capacity;
        };

        // Check capacity is not exceeded
        assert!(used_capacity <= self.total_capacity_size, EStorageExceeded);
        
        i = i + 1;
    };

    storage_resource::create_storage(
        self.epoch(),
        self.epoch() + epochs_ahead,
        storage_amount,
        ctx,
    )
}

/// Registers a new blob in the system.
public(package) fun register_blob(
    self: &mut SystemStateInner,
    storage: Storage,
    blob_id: u256,
    root_hash: u256,
    size: u64,
    encoding_type: u8,
    deletable: bool,
    write_payment: &mut Coin<MYS>,
    ctx: &mut TxContext,
): Blob {
    let blob = blob::new(
        storage,
        blob_id,
        root_hash,
        size,
        encoding_type,
        deletable,
        self.epoch(),
        self.n_shards(),
        ctx,
    );
    
    let encoded_size = blob.encoded_size(self.n_shards());
    let write_price = self.write_price(encoded_size);
    
    // Process payment - add to rewards for the current epoch
    let payment = write_payment.balance_mut().split(write_price);
    self.future_accounting.ring_lookup_mut(0).rewards_balance().join(payment);
    
    blob
}

/// Certify that a blob will be available in the storage system until the end epoch of the
/// storage associated with it.
public(package) fun certify_blob(
    self: &SystemStateInner,
    blob: &mut Blob,
    signature: vector<u8>,
    signers_bitmap: vector<u8>,
    message: vector<u8>,
) {
    let certified_msg = self
        .committee()
        .verify_quorum_in_epoch(
            signature,
            signers_bitmap,
            message,
        );
    assert!(certified_msg.cert_epoch() == self.epoch(), EInvalidIdEpoch);

    let certified_blob_msg = messages::certify_blob_message(certified_msg);
    blob::certify_with_certified_msg(blob, self.epoch(), certified_blob_msg);
}

/// Deletes a deletable blob and returns the contained storage.
public(package) fun delete_blob(self: &SystemStateInner, blob: Blob): Storage {
    blob::delete(blob, self.epoch())
}

/// Extend the period of validity of a blob with a new storage resource.
public(package) fun extend_blob_with_resource(
    self: &SystemStateInner,
    blob: &mut Blob,
    extension: Storage,
) {
    blob::extend_with_resource(blob, extension, self.epoch())
}

/// Extend the period of validity of a blob by extended_epochs.
public(package) fun extend_blob(
    self: &mut SystemStateInner,
    blob: &mut Blob,
    extended_epochs: u32,
    payment: &mut Coin<MYS>,
) {
    // Check that the blob is certified and not expired.
    blob.assert_certified_not_expired(self.epoch());

    let start_offset = blob.storage().end_epoch() - self.epoch();
    let end_offset = start_offset + extended_epochs;

    // Check the period is within the allowed range.
    assert!(extended_epochs > 0, EInvalidEpochsAhead);
    assert!(end_offset <= self.future_accounting.max_epochs_ahead(), EInvalidEpochsAhead);

    // Pay rewards for each future epoch into the future accounting.
    let storage_size = blob.storage().size();
    self.process_storage_payments(
        storage_size,
        start_offset,
        end_offset,
        payment,
    );

    // Account the used space: increase the used capacity for each epoch in the future.
    let i = start_offset;
    while (i < end_offset) {
        let used_capacity = self
            .future_accounting
            .ring_lookup_mut(i)
            .increase_used_capacity(storage_size);

        assert!(used_capacity <= self.total_capacity_size, EStorageExceeded);
        
        i = i + 1;
    };

    blob.storage_mut().extend_end_epoch(extended_epochs);

    blob.emit_certified(true);
}

/// Adds rewards to the system for the specified number of epochs ahead.
/// The rewards are split equally across the future accounting ring buffer up to the
/// specified epoch.
public(package) fun add_subsidy(
    self: &mut SystemStateInner,
    subsidy: Coin<MYS>,
    epochs_ahead: u32,
) {
    // Check the period is within the allowed range.
    assert!(epochs_ahead > 0, EInvalidEpochsAhead);
    assert!(epochs_ahead <= self.future_accounting.max_epochs_ahead(), EInvalidEpochsAhead);

    let mut subsidy_balance = subsidy.into_balance();
    let reward_per_epoch = subsidy_balance.value() / (epochs_ahead as u64);
    let leftover_rewards = subsidy_balance.value() % (epochs_ahead as u64);

    let i = 0;
    while (i < epochs_ahead) {
        self
            .future_accounting
            .ring_lookup_mut(i)
            .rewards_balance()
            .join(subsidy_balance.split(reward_per_epoch));
        i = i + 1;
    };

    // Add leftover rewards to the first epoch's accounting.
    self.future_accounting.ring_lookup_mut(0).rewards_balance().join(subsidy_balance);
}

/// Invalidates a blob given an invalid blob certificate.
public(package) fun invalidate_blob_id(
    self: &SystemStateInner,
    signature: vector<u8>,
    members_bitmap: vector<u8>,
    message: vector<u8>,
): u256 {
    let certified_message = self
        .committee
        .verify_one_correct_node_in_epoch(
            signature,
            members_bitmap,
            message,
        );

    let epoch = certified_message.cert_epoch();
    let invalid_blob_message = messages::invalid_blob_id_message(certified_message);
    let blob_id = invalid_blob_message.invalid_blob_id();
    
    // Assert the epoch is correct.
    assert!(epoch == self.epoch(), EInvalidIdEpoch);

    // Emit the event about a blob id being invalid.
    events::emit_invalid_blob_id(epoch, blob_id);
    blob_id
}

/// Certifies a blob containing events.
public(package) fun certify_event_blob(
    self: &mut SystemStateInner,
    cap: &mut StorageNodeCap,
    blob_id: u256,
    root_hash: u256,
    size: u64,
    encoding_type: u8,
    ending_checkpoint_sequence_num: u64,
    epoch: u32,
    ctx: &mut TxContext,
) {
    assert!(self.committee().contains(&cap.node_id()), ENotCommitteeMember);
    assert!(epoch == self.epoch(), EInvalidIdEpoch);

    cap.last_event_blob_attestation().do!(|attestation| {
        assert!(
            attestation.last_attested_event_blob_epoch() < self.epoch() ||
                ending_checkpoint_sequence_num >
                    attestation.last_attested_event_blob_checkpoint_seq_num(),
            ERepeatedAttestation,
        );
        let latest_certified_checkpoint_seq_num = self
            .event_blob_certification_state
            .get_latest_certified_checkpoint_sequence_number();

        if (latest_certified_checkpoint_seq_num.is_some()) {
            let latest_certified_cp_seq_num = latest_certified_checkpoint_seq_num.destroy_some();
            assert!(
                attestation.last_attested_event_blob_epoch() < self.epoch() ||
                    attestation.last_attested_event_blob_checkpoint_seq_num()
                        <= latest_certified_cp_seq_num,
                EIncorrectAttestation,
            );
        } else {
            assert!(
                attestation.last_attested_event_blob_epoch() < self.epoch(),
                EIncorrectAttestation,
            );
        }
    });

    let attestation = event_blob::new_attestation(ending_checkpoint_sequence_num, epoch);
    cap.set_last_event_blob_attestation(attestation);

    let blob_certified = self
        .event_blob_certification_state
        .is_blob_already_certified(ending_checkpoint_sequence_num);

    if (blob_certified) {
        return
    };

    self.event_blob_certification_state.start_tracking_blob(blob_id);
    let weight = self.committee().get_member_weight(&cap.node_id());
    let agg_weight = self.event_blob_certification_state.update_aggregate_weight(blob_id, weight);
    let certified = self.committee().is_quorum(agg_weight);
    if (!certified) {
        return
    };

    let num_shards = self.n_shards();
    let epochs_ahead = self.future_accounting.max_epochs_ahead();
    
    // Reserve space for the event blob
    let encoded_size = storage_resource::encoded_blob_length(size, encoding_type, num_shards);
    let mut i = 0;
    while (i <= epochs_ahead) {
        let used_capacity = self
            .future_accounting
            .ring_lookup_mut(i)
            .increase_used_capacity(encoded_size);
            
        if (i == 0) {
            self.used_capacity_size = used_capacity;
        }
        
        i = i + 1;
    };
    
    let storage = storage_resource::create_storage(
        self.epoch(),
        self.epoch() + epochs_ahead,
        encoded_size,
        ctx,
    );
    
    let mut blob = blob::new(
        storage,
        blob_id,
        root_hash,
        size,
        encoding_type,
        false,
        self.epoch(),
        self.n_shards(),
        ctx,
    );
    
    let certified_blob_msg = messages::certified_event_blob_message(blob_id);
    blob::certify_with_certified_msg(blob, self.epoch(), certified_blob_msg);
    
    self
        .event_blob_certification_state
        .update_latest_certified_event_blob(
            ending_checkpoint_sequence_num,
            blob_id,
        );
        
    // Stop tracking all event blobs after certification
    self.event_blob_certification_state.reset();
    
    // Event blobs are burned after certification as the content is saved in the chain
    blob.burn();
}

/// Processes a deny list update for a storage node.
public(package) fun update_deny_list(
    self: &mut SystemStateInner,
    cap: &mut StorageNodeCap,
    signature: vector<u8>,
    members_bitmap: vector<u8>,
    message: vector<u8>,
) {
    assert!(self.committee().contains(&cap.node_id()), ENotCommitteeMember);

    let certified_message = self
        .committee
        .verify_quorum_in_epoch(signature, members_bitmap, message);

    let epoch = certified_message.cert_epoch();
    let message = messages::deny_list_update_message(certified_message);
    let node_id = message.storage_node_id();
    let size = message.size();

    assert!(epoch == self.epoch(), EInvalidIdEpoch);
    assert!(node_id == cap.node_id(), EIncorrectDenyListNode);
    assert!(cap.deny_list_sequence() < message.sequence_number(), EIncorrectDenyListSequence);

    let deny_list_root = message.root();
    let sequence_number = message.sequence_number();

    // Update deny_list properties in the cap
    cap.set_deny_list_properties(deny_list_root, sequence_number, size);

    // Then register the update in the system storage
    let sizes = self.deny_list_sizes_mut();
    if (sizes.contains(&node_id)) {
        *sizes.get_mut(&node_id) = message.size();
    } else {
        sizes.insert(node_id, message.size());
    };

    events::emit_deny_list_update(
        self.epoch(),
        deny_list_root,
        sequence_number,
        cap.node_id(),
    );
}

/// Processes storage payments for a period of epochs.
public(package) fun process_storage_payments(
    self: &mut SystemStateInner,
    storage_size: u64,
    start_offset: u32,
    end_offset: u32,
    payment: &mut Coin<MYS>,
) {
    let storage_units = storage_units_from_size(storage_size);
    let period_payment_due = self.storage_price_per_unit_size * storage_units;
    let coin_balance = payment.balance_mut();

    let i = start_offset;
    while (i < end_offset) {
        // Distribute rewards
        // Note this will abort if the balance is not enough.
        let epoch_payment = coin_balance.split(period_payment_due);
        self.future_accounting.ring_lookup_mut(i).rewards_balance().join(epoch_payment);
        i = i + 1;
    };
}

/// Update epoch to next epoch, and update the committee, price and capacity.
/// Called by the epoch change function that connects system storage to epoch changes.
/// Returns the mapping of node IDs from the old committee to the rewards they received.
public(package) fun advance_epoch(
    self: &mut SystemStateInner,
    new_committee: BlsCommittee,
    new_epoch_params: &EpochParams,
): VecMap<ID, Balance<MYS>> {
    // Check new committee is valid, the existence of a committee for the next
    // epoch is proof that the time has come to move epochs.
    let old_epoch = self.epoch();
    let new_epoch = old_epoch + 1;
    let old_committee = self.committee;

    assert!(new_committee.epoch() == new_epoch, EIncorrectCommittee);

    // === Update the system object ===
    self.committee = new_committee;

    let accounts_old_epoch = self.future_accounting.ring_pop_expand();

    // Make sure that we have the correct epoch
    assert!(accounts_old_epoch.epoch() == old_epoch, EInvalidAccountingEpoch);

    // Stop tracking all event blobs
    self.event_blob_certification_state.reset();

    // Update storage based on the accounts data.
    let old_epoch_used_capacity = accounts_old_epoch.used_capacity();

    // Update used capacity size to the new epoch
    self.used_capacity_size = self.future_accounting.ring_lookup_mut(0).used_capacity();

    // Update capacity and prices from the epoch parameters
    self.total_capacity_size = new_epoch_params.capacity().max(self.used_capacity_size);
    self.storage_price_per_unit_size = new_epoch_params.storage_price();
    self.write_price_per_unit_size = new_epoch_params.write_price();

    // === Rewards distribution ===
    
    let mut total_rewards = accounts_old_epoch.unwrap_balance();

    // Prepare for reward distribution based on stake and deny list sizes
    let deny_list_sizes = self.deny_list_sizes();
    let (node_ids, weights) = old_committee.to_vec_map().into_keys_values();
    let mut stored_amounts = vector[];
    let mut total_stored: u128 = 0;

    // Calculate the "stored amount" for each validator, which is the node's weight 
    // multiplied by the amount they actually stored (total minus denied)
    let mut i = 0;
    while (i < node_ids.length()) {
        let node_id = node_ids[i];
        let weight = weights[i];
        
        // Get deny list size or 0 if not found
        let deny_list_size = if (deny_list_sizes.contains(&node_id)) {
            *deny_list_sizes.get(&node_id)  
        } else {
            0
        };
        
        // The deny list size cannot exceed the used capacity
        let deny_list_size = deny_list_size.min(old_epoch_used_capacity);
        
        // The stored amount is the total encoded size minus what's denied
        let stored = old_epoch_used_capacity - deny_list_size;
        
        // Weight by validator stake
        let stored_weighted = (weight as u128) * (stored as u128);
        
        total_stored = total_stored + stored_weighted;
        stored_amounts.push_back(stored_weighted);
        
        i = i + 1;
    };

    // Avoid division by zero
    total_stored = total_stored.max(1);  
    
    let total_rewards_value = total_rewards.value() as u128;
    
    // Calculate and distribute rewards 
    let mut rewards = vec_map::empty<ID, Balance<MYS>>();
    
    let mut i = 0;
    while (i < node_ids.length()) {
        let node_id = node_ids[i];
        let stored = stored_amounts[i];
        
        // Calculate reward share and distribute
        let reward_value = (stored * total_rewards_value / total_stored) as u64;
        
        if (reward_value > 0) {
            let reward = total_rewards.split(reward_value);
            rewards.insert(node_id, reward);
        };
        
        i = i + 1;
    };

    // Add leftover rewards to the next epoch's accounting to avoid rounding errors
    self.future_accounting.ring_lookup_mut(0).rewards_balance().join(total_rewards);
    
    rewards
}

/// The write price for a given size.
public(package) fun write_price(self: &SystemStateInner, write_size: u64): u64 {
    let storage_units = storage_units_from_size(write_size);
    self.write_price_per_unit_size * storage_units
}

/// Converts storage size to storage units by dividing by MiB and rounding up.
fun storage_units_from_size(size: u64): u64 {
    if (size % BYTES_PER_UNIT_SIZE == 0) {
        size / BYTES_PER_UNIT_SIZE
    } else {
        (size / BYTES_PER_UNIT_SIZE) + 1
    }
}

// === Testing Functions ===

#[test_only]
/// Create a SystemStateInner for testing purposes with default values.
public fun create_for_testing(): SystemStateInner {
    let committee = bls_aggregate::create_committee_for_testing(0, vector[]);
    let future_accounting = storage_accounting::ring_new(104);
    let event_blob_state = event_blob::create_for_testing();
    let id = object::new(&mut tx_context::dummy());
    
    let deny_list_sizes = vec_map::empty<ID, u64>();
    dynamic_field::add(&mut id, DF_DENY_LIST_SIZES, deny_list_sizes);
    
    SystemStateInner {
        committee,
        total_capacity_size: DEFAULT_CAPACITY,
        used_capacity_size: 0,
        storage_price_per_unit_size: DEFAULT_STORAGE_PRICE,
        write_price_per_unit_size: DEFAULT_WRITE_PRICE,
        future_accounting,
        event_blob_certification_state: event_blob_state,
        id,
    }
}
}
}