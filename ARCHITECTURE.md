# Blob Storage System Architecture and User Experience

## Overall Architecture

The blob storage system is built with a layered architecture:

1. **Core Storage Layer**:
   - **Blob**: Content-addressed data containers with metadata
   - **Storage Resource**: Represents reserved space for a specific duration
   - **System State**: The central state management for the storage system

2. **Validator Layer**:
   - **Committee Integration**: Uses the MYS validator committee for authorization
   - **BLS Signatures**: Multi-signature verification for blob certification
   - **StorageNodeCap**: Capability objects for validators to participate

3. **Economic Layer**:
   - **Payment System**: MYS tokens used for storage and write costs
   - **Reward Distribution**: Validators earn rewards based on storage provided
   - **Epoch-based Accounting**: Tracks future storage commitments

4. **Integration Layer**:
   - **Epoch Management**: Synchronizes with MYS epoch changes
   - **Events**: System emits events for off-chain tracking
   - **Client Interface**: Convenient methods for users to interact with the system

## User Experience

### Storing Data

1. **Calculate Costs**: User determines how much storage they need and for how long
   ```move
   let storage_payment = blob_storage::system::calculate_storage_payment(file_size, epochs_ahead);
   let write_payment = blob_storage::system::calculate_write_payment(file_size);
   ```

2. **Store Blob**: User submits data with a single call
   ```move
   blob_storage::system::store_blob(
     &mut blob_state,
     blob_id,
     root_hash,
     size,
     encoding_type,
     deletable,
     epochs_ahead,
     &mut storage_payment,
     &mut write_payment,
     ctx
   );
   ```

3. **Certification**: Validators automatically certify the blob's availability

### Managing Storage

- **Extend Storage**: Users can extend storage duration of their blobs
- **Delete Blobs**: Users can delete blobs and reclaim storage resources
- **Check Status**: Users can query blob certification status and remaining epochs

## Cost Structure

The system uses a simple pricing model:

1. **Storage Cost**: 1 MYS per MiB per epoch
   - DEFAULT_STORAGE_PRICE = 1,000,000 (1 MYS in the smallest units per MiB)

2. **Write Cost**: 0.5 MYS per MiB per write operation
   - DEFAULT_WRITE_PRICE = 500,000 (0.5 MYS in the smallest units per MiB)

3. **For 1 GB storage for 52 epochs** (about 1 year):
   - Storage Cost: 1 MYS × 1024 MiB × 52 epochs = 53,248 MYS
   - Write Cost: 0.5 MYS × 1024 MiB = 512 MYS
   - Total: ~53,760 MYS for 1 GB stored for 1 year

These values are system parameters and can be adjusted based on market conditions and governance decisions.

## Validator Experience

Validators participate in the storage system as follows:

1. **Registration**: Validators register as storage nodes
   ```move
   blob_storage::system::register_storage_node(&mut state, ctx);
   ```

2. **Storage Allocation**: Each validator implicitly commits to store all certified blobs

3. **Storage Requirements**: Validators would need to allocate disk space based on the total system capacity (DEFAULT_CAPACITY = 1 TiB)
   - The capacity is shared among all validators
   - In practice, each validator would store a redundant copy
   - If the system has 100 validators and total capacity is 1 TiB, each validator needs to reserve at least 1 TiB

4. **Attestation**: Validators attest that blobs are available using their StorageNodeCap

5. **Deny Lists**: Validators can maintain deny lists for blobs they cannot or will not store

6. **Rewards**: Validators earn rewards based on:
   - Their stake in the system
   - The amount of data they're actually storing (total minus denied)
   - Rewards are distributed at epoch boundaries

## Practical Example

Let's consider a real-world example:

1. A user wants to store a 100 MB file for 2 years (104 epochs)
   - Storage payment: 1 MYS × 100 MiB × 104 epochs = 10,400 MYS
   - Write payment: 0.5 MYS × 100 MiB = 50 MYS
   - Total cost: 10,450 MYS

2. After one year, the user decides to extend storage for another year
   - Extension payment: 1 MYS × 100 MiB × 52 epochs = 5,200 MYS

3. The blob is automatically stored by all validators, who earn portions of these payments in proportion to their stake and actual storage provided

## System Management

The total system capacity is capped (DEFAULT_CAPACITY = 1 TiB), and validators must ensure they have enough physical storage to handle this capacity. The system design provides:

1. **Future Accounting**: Tracks storage commitments for years in advance
2. **Graceful Degradation**: Validators can use deny lists if they cannot store certain blobs
3. **Economic Incentives**: Pricing and rewards balance to make storage profitable for validators

## Technical Components

### System State Inner

The `SystemStateInner` structure maintains:
- Current committee information
- Total and used capacity tracking
- Pricing parameters
- Future accounting ring buffer
- Event blob certification state

### Storage Accounting

The system uses a ring buffer to track future storage commitments:
- Each position represents an epoch
- Contains used capacity and rewards for that epoch
- When advancing epochs, the oldest entry is removed and a new one is added

### BLS Committee

The committee is responsible for:
- Verifying blob certification signatures
- Tracking validator membership and weights
- Providing quorum verification

### Storage Resources

The `Storage` object represents:
- A specific amount of reserved capacity
- A validity period (start and end epochs)
- Can be extended or combined with other storage resources

### Blobs

A `Blob` object contains:
- Content identifiers (blob_id and root_hash)
- Size and encoding information
- Certification status
- Associated storage resource

## Integration with MYS Blockchain

The blob storage system integrates with MYS through:

1. **Epoch Advancement**: When MYS advances its epoch, the blob storage system also advances
2. **Committee Updates**: The blob storage committee is derived from the MYS validator set
3. **Reward Distribution**: Storage rewards flow back to MYS validators
4. **MYS Token Economy**: Storage costs are paid in MYS tokens

## Security Considerations

The system incorporates several security features:

1. **BLS Signatures**: Cryptographic verification of blob availability
2. **Quorum Requirements**: Multiple validators must attest to blob availability
3. **Economic Incentives**: Validators are rewarded for honest behavior
4. **Deny Lists**: Provides protection against malicious or illegal content
5. **Permission Controls**: Only authorized validators can participate

In summary, the system provides a complete decentralized storage solution with clear economics, validator incentives, and user interfaces, all integrated with the MYS blockchain's epoch and committee structures.