# 📦 MySocial's Blob Storage

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A decentralized, validator-based storage solution for the MySocial blockchain. Store your data securely with fixed-duration commitments and certified availability.

## 🌟 Features

- **Content-addressed storage**: Data is identified by its content hash
- **Fixed-duration storage**: Pay upfront for a specific storage period
- **Decentralized validation**: MYS validators serve as storage nodes
- **BLS multisignature certification**: Validators certify data availability
- **Epoch-based accounting**: Storage costs and rewards are managed per epoch
- **Validator rewards**: Storage providers earn in proportion to their stake

## 📄 Documentation

- [Architecture](./ARCHITECTURE.md): Detailed system architecture and economic model
- [Integration Guide](./INTEGRATION.md): How to integrate this module with the MySocial codebase

## 🧩 Key Components

- **BlobStorageState**: The central shared object that manages the system state
- **Blob**: Object containing metadata for stored content
- **Storage**: Resource object representing reserved storage capacity
- **StorageNodeCap**: Capability object for validators to interact with the system
- **Committee**: Integration with MYS validator committee system

## 💻 Usage Examples

### Store Data (One-step)

```move
// Store a blob in a single transaction
blob_storage::system::store_blob(
    &mut blob_state,
    blob_id,                // Content-based identifier (hash)
    root_hash,              // Merkle root hash
    size,                   // Size in bytes
    encoding_type,          // Data encoding format
    true,                   // Deletable
    52,                     // 52 epochs (about 1 year)
    &mut storage_payment,   // Payment for storage
    &mut write_payment,     // Payment for write operation
    ctx
);
```

### Calculate Storage Costs

```move
// Calculate storage payment for 10 MB for 52 epochs (about 1 year)
let storage_cost = blob_storage::system::calculate_storage_payment(
    10 * 1024 * 1024,   // 10 MB
    52                  // 52 epochs
);

// Calculate one-time write payment for 10 MB
let write_cost = blob_storage::system::calculate_write_payment(
    10 * 1024 * 1024    // 10 MB
);
```

### Extend Storage Duration

```move
// Extend storage by 26 more epochs (about 6 months)
blob_storage::system::extend_blob(
    &mut blob_state,
    &mut blob,
    26,               // 26 more epochs
    &mut payment,
);
```

### For Validators

```move
// Register as a storage node (validators only)
blob_storage::system::register_storage_node(
    &mut blob_state,
    ctx
);
```

## 💰 Cost Structure

- **Storage Cost**: 1 MySo per MiB per epoch
- **Write Cost**: 0.5 MySo per MiB per write operation

Example: Storing 1 GB for 1 year costs approximately 53,760 MySo.
See the [Architecture](./ARCHITECTURE.md) document for detailed cost breakdowns.

## 🔄 System Integration

The blob storage system automatically integrates with MySocial epoch changes:
- Updates committee based on the current validator set
- Distributes rewards to storage providers
- Reclaims expired storage
- Updates system parameters

## 🔔 Events

The system emits events for important operations:
- System initialization
- Blob operations (registration, certification, invalidation)
- Deny list updates
- Epoch changes

## 📚 Full API Reference

### Storage Operations
- `reserve_space`: Reserve storage capacity for a specified duration
- `register_blob`: Register a blob with the system
- `store_blob`: Combine reservation and registration in one step
- `extend_blob`: Extend the storage duration of a blob
- `delete_blob`: Remove a blob and reclaim its storage resource

### Validator Operations
- `register_storage_node`: Register as a storage provider
- `certify_blob`: Certify a blob as available
- `update_deny_list`: Update the list of denied blobs

### Utility Functions
- `calculate_storage_payment`: Calculate required storage payment
- `calculate_write_payment`: Calculate required write payment
- `epoch`: Get the current epoch
- `total_capacity`: Get the total system capacity
- `used_capacity`: Get the currently used capacity

## 📝 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](../../../LICENSE) file for details.