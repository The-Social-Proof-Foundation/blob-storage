# Blob Storage Integration Guide

This document outlines all external files that need to be modified to properly integrate the Blob Storage system with the MYS blockchain. Use this guide when moving the blob-storage package to a different MYS codebase.

## External File Modifications

### 1. MYS System Epoch Advancement

The main integration point is in the MYS system's epoch advancement function. This modification ensures the blob storage system advances epochs with the MYS system.

**File: `/crates/mys-framework/packages/mys-system/sources/mys_system.move`**

In the `advance_epoch` function, add this block after the MYS system's epoch advancement:

```move
// Advance the blob storage epoch if the blob storage system is initialized
if (exists<blob_storage::system::BlobStorageState>(@blob_storage)) {
    let blob_state = borrow_global_mut<blob_storage::system::BlobStorageState>(@blob_storage);
    // Create a new committee with validator information from the current validator set
    let (new_committee, new_params) = blob_storage::system::create_committee_from_validator_set(
        self.validators(),
        new_epoch as u32,
        ctx
    );
    blob_storage::system::advance_epoch(blob_state, new_committee, &new_params, ctx);
};
```

The exact location to add this code is after this line:
```move
let storage_rebate = self.advance_epoch(
    new_epoch,
    next_protocol_version,
    storage_reward,
    computation_reward,
    storage_rebate,
    non_refundable_storage_fee,
    storage_fund_reinvest_rate,
    reward_slashing_rate,
    epoch_start_timestamp_ms,
    ctx,
);
```

### 2. Package Dependencies

Ensure `Move.toml` has the correct dependencies for the blob-storage package:

**File: `/crates/mys-framework/packages/blob-storage/Move.toml`**

```toml
[package]
name = "BlobStorage"
version = "0.0.1"

[dependencies]
Mys = { local = "../mys-framework" }
MoveStdlib = { local = "../move-stdlib" }

[addresses]
std = "0x1"
mys = "0x2"
blob_storage = "0x3"
```

### 3. Import in Framework Packages

To expose blob-storage in the MYS framework, update the framework packages:

**File: `/crates/mys-framework/packages/mys-framework/Move.toml`**

Add the blob-storage dependency:

```toml
[dependencies]
# Other dependencies...
BlobStorage = { local = "../blob-storage" }
```

### 4. Testing Infrastructure

If you're using the MYS testing infrastructure, you might need to register the blob-storage package:

**File: `/crates/mys-move/src/build/publish.rs`** (if it exists)

Add the blob-storage package to the list of framework packages:

```rust
const FRAMEWORK_PACKAGES: &[&str] = &[
    // Existing packages...
    "blob-storage",
];
```

### 5. Module Publishing Configuration

If you're using a package publishing configuration, update it:

**File: `/crates/mys-genesis-builder/src/main.rs`** (if it exists)

Add the blob-storage package:

```rust
let framework_packages = vec![
    // Existing packages...
    "blob-storage".to_string(),
];
```

## Rust API Integration (Optional)

If you need the Rust API to interact with blob-storage:

### 1. Rust Object Types

**File: `/crates/mys-types/src/storage/`**

Create appropriate Rust types for blob-storage objects, including:
- `BlobStorageState`
- `Blob`
- `Storage`
- `StorageNodeCap`

Example:
```rust
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
pub struct BlobStorage {
    pub id: ObjectID,
    pub inner: BlobStorageInner,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
pub struct Blob {
    pub id: ObjectID,
    pub blob_id: [u8; 32], // u256
    pub root_hash: [u8; 32], // u256
    pub size: u64,
    pub encoding_type: u8,
    pub deletable: bool,
    pub storage: Storage,
    pub certified: bool,
}
```

### 2. RPC API Extensions

**File: `/crates/mys-json-rpc/src/api/`**

Add RPC methods for blob-storage if needed:
- `get_blob_storage_state`
- `get_blob`
- `calculate_storage_payment`

## Initialization

When deploying the system, ensure the blob-storage system is properly initialized with:

```move
blob_storage::system::initialize(104, ctx); // 104 epochs ahead (2 years)
```

This should be done after the MYS system is initialized.

## Package Structure

Ensure all required files are present in the blob-storage package:

```
blob-storage/
├── Move.toml
├── README.md
├── INTEGRATION.md (this file)
└── sources/
    ├── blob.move
    ├── bls_aggregate.move
    ├── encoding.move
    ├── epoch_parameters.move
    ├── event_blob.move
    ├── events.move
    ├── messages.move
    ├── redstuff.move
    ├── shared_blob.move
    ├── storage_accounting.move
    ├── storage_node.move
    ├── storage_resource.move
    ├── system.move
    ├── system_state_inner.move
    └── test/
        └── integration_test.move
```

## Testing

After integration, run these tests to verify everything works correctly:

1. Run the integration test:
```bash
mys move test --package BlobStorage
```
or from the root dirctory:
```bash
cargo test -p mys-framework-tests -- --exact blob_storage::integration_test
```

2. Test the epoch advancement integration by creating a test that:
   - Initializes the MYS system with validators
   - Initializes the blob storage system
   - Advances the MYS system epoch
   - Verifies the blob storage system epoch also advanced

## Common Issues

1. **Missing Address**: Ensure `@blob_storage` address is set to the correct value (usually `0x3`)

2. **Import Errors**: If you encounter import errors, check that all dependencies are correctly specified in the Move.toml file

3. **Epoch Mismatch**: If the blob storage epoch doesn't advance with the MYS system, verify that the epoch advancement code was added correctly

4. **Validator Integration**: If validators can't register as storage nodes, check that the validator committee integration works properly
