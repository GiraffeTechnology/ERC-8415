// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title ERC-8415 Watchtower Freshness Layer
/// @notice Interface for a registry that accepts EIP-712 signed watchtower attestations,
///         enforces strict monotonic sequencing per asset feed, honours block-scoped key
///         rotation windows, and classifies the recorded head as STALE, FRESH_PENDING or
///         FRESH_FINAL.
interface IWatchtowerFreshnessLayer {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Freshness classification of the recorded head of an asset feed.
    /// @dev `UNKNOWN`      - the asset is unregistered, or no attestation has been recorded yet.
    ///      `STALE`        - the head is older than its declared freshness threshold, or was
    ///                       signed by a key that has since been revoked.
    ///      `FRESH_PENDING`- the head is within its freshness threshold but has not yet aged
    ///                       past the asset's finality depth, so it may still be reorged.
    ///      `FRESH_FINAL`  - the head is within its freshness threshold and has aged past the
    ///                       asset's finality depth.
    enum Freshness {
        UNKNOWN,
        STALE,
        FRESH_PENDING,
        FRESH_FINAL
    }

    /// @notice The EIP-712 signed payload.
    /// @param assetId            Identifier of the attested feed, as returned by `computeAssetId`.
    /// @param signedAtBlock      Block height the watchtower observed and signed at.
    /// @param sequenceNumber     Strictly monotonic counter; MUST equal `lastSequence + 1`.
    /// @param freshnessThreshold Maximum age, in blocks, for which this attestation stays fresh.
    struct Attestation {
        bytes32 assetId;
        uint64 signedAtBlock;
        uint64 sequenceNumber;
        uint64 freshnessThreshold;
    }

    /// @notice Validity window of a watchtower signing key, in block heights.
    /// @param validFromBlock First block height (inclusive) the key may sign for.
    /// @param validToBlock   Last block height (inclusive) the key may sign for.
    /// @param registered     Whether the key has ever been registered for the asset.
    /// @param revoked        Whether the key was emergency-revoked. A revoked key is rejected for
    ///                       every block height, including heights inside its former window, and
    ///                       can never be registered again for this asset.
    struct KeyWindow {
        uint64 validFromBlock;
        uint64 validToBlock;
        bool registered;
        bool revoked;
    }

    /// @notice Per-asset policy.
    /// @param steward               Address allowed to rotate keys and update the policy.
    /// @param finalityDepth         Age, in blocks, at which a fresh head is considered final.
    /// @param maxFreshnessThreshold Upper bound a watchtower may declare as `freshnessThreshold`.
    /// @param pendingSteward        Address that may accept stewardship, or zero.
    /// @param registered            Whether the asset exists.
    struct AssetPolicy {
        address steward;
        uint64 finalityDepth;
        uint64 maxFreshnessThreshold;
        address pendingSteward;
        bool registered;
    }

    /// @notice The most recent accepted attestation for an asset.
    /// @param signedAtBlock      Block height the head was signed at; zero when no head exists.
    /// @param sequenceNumber     Sequence number of the head; the next accepted value is this plus one.
    /// @param freshnessThreshold Freshness threshold declared by the head.
    /// @param recordedAtBlock    Block height at which the head was recorded on chain.
    /// @param key                Signing key that produced the head.
    struct Head {
        uint64 signedAtBlock;
        uint64 sequenceNumber;
        uint64 freshnessThreshold;
        uint64 recordedAtBlock;
        address key;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event AssetRegistered(
        bytes32 indexed assetId,
        address indexed registrar,
        address indexed steward,
        uint64 finalityDepth,
        uint64 maxFreshnessThreshold,
        uint64 initialSequence
    );
    event PolicyUpdated(bytes32 indexed assetId, uint64 finalityDepth, uint64 maxFreshnessThreshold);
    event StewardshipTransferStarted(bytes32 indexed assetId, address indexed from, address indexed to);
    event StewardshipTransferred(bytes32 indexed assetId, address indexed from, address indexed to);
    event KeyRotated(bytes32 indexed assetId, address indexed key, uint64 validFromBlock, uint64 validToBlock);
    event KeyRevoked(bytes32 indexed assetId, address indexed key, uint64 revokedAtBlock);
    event AttestationAccepted(
        bytes32 indexed assetId,
        address indexed key,
        uint64 indexed sequenceNumber,
        uint64 signedAtBlock,
        uint64 freshnessThreshold,
        bytes32 digest
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error AssetAlreadyRegistered(bytes32 assetId);
    error AssetNotRegistered(bytes32 assetId);
    error NotSteward(bytes32 assetId, address caller);
    error NotPendingSteward(bytes32 assetId, address caller);
    error ZeroAddress();
    error InvalidPolicy(uint64 finalityDepth, uint64 maxFreshnessThreshold);
    error InvalidKeyWindow(uint64 validFromBlock, uint64 validToBlock);
    error KeyNotRegistered(bytes32 assetId, address key);
    error KeyAlreadyRevoked(bytes32 assetId, address key);
    error KeyNotActiveAtBlock(bytes32 assetId, address key, uint64 signedAtBlock);
    error InvalidSignature(bytes32 assetId, address key);
    error InvalidSignedAtBlock();
    error AttestationFromFuture(uint64 signedAtBlock, uint256 currentBlock);
    error AttestationAlreadyStale(uint256 age, uint64 freshnessThreshold);
    error AttestationOutOfOrder(uint64 signedAtBlock, uint64 headSignedAtBlock);
    error FreshnessThresholdOutOfRange(uint64 freshnessThreshold, uint64 maxFreshnessThreshold);
    error SequenceNotContiguous(bytes32 assetId, uint64 expected, uint64 provided);
    error SequenceExhausted(bytes32 assetId);
    error NotFresh(bytes32 assetId, Freshness status);

    // ---------------------------------------------------------------------
    // Asset lifecycle
    // ---------------------------------------------------------------------

    /// @notice Deterministic, squat-resistant asset identifier derived from its registrar.
    function computeAssetId(address registrar, bytes32 salt) external pure returns (bytes32 assetId);

    /// @notice Registers a new asset feed owned by `steward`.
    /// @dev The identifier is derived from `msg.sender` and `salt`, so no caller can register an
    ///      identifier belonging to another registrar. `finalityDepth` MUST NOT exceed
    ///      `maxFreshnessThreshold`, otherwise `FRESH_FINAL` would be unreachable.
    function registerAsset(
        bytes32 salt,
        address steward,
        uint64 finalityDepth,
        uint64 maxFreshnessThreshold,
        uint64 initialSequence
    ) external returns (bytes32 assetId);

    /// @notice Updates the freshness policy of an asset. Steward only.
    function setPolicy(bytes32 assetId, uint64 finalityDepth, uint64 maxFreshnessThreshold) external;

    /// @notice Starts a two-step stewardship transfer. Steward only.
    function transferStewardship(bytes32 assetId, address newSteward) external;

    /// @notice Completes a two-step stewardship transfer. Pending steward only.
    function acceptStewardship(bytes32 assetId) external;

    // ---------------------------------------------------------------------
    // Key rotation
    // ---------------------------------------------------------------------

    /// @notice Registers or re-windows a signing key over `[validFromBlock, validToBlock]`. Steward only.
    /// @dev Windows of different keys MAY overlap, which is what makes a hand-over possible. A key
    ///      is retired gracefully by shortening `validToBlock`; attestations it signed inside the
    ///      old window remain verifiable. A window MAY also be moved or widened into the past: the
    ///      steward is the trust root for its own asset, so it can backdate authority over blocks
    ///      that have already passed. Use `revokeKey`, not a narrowed window, for a compromised key.
    function rotateKey(bytes32 assetId, address key, uint64 validFromBlock, uint64 validToBlock) external;

    /// @notice Emergency-revokes a key. Steward only.
    /// @dev Revocation is retroactive and permanent: the key verifies for no block height, the
    ///      key can never be re-registered for this asset, and a head signed by it classifies as
    ///      `STALE`.
    function revokeKey(bytes32 assetId, address key) external;

    // ---------------------------------------------------------------------
    // Attestations
    // ---------------------------------------------------------------------

    /// @notice Records a signed attestation as the new head of the feed.
    /// @dev Permissionless: anyone may relay a watchtower signature.
    /// @return digest The EIP-712 digest that was verified.
    function submit(Attestation calldata attestation, address key, bytes calldata signature)
        external
        returns (bytes32 digest);

    /// @notice Verifies signer authority and signature validity without touching state.
    /// @dev Does not evaluate sequencing or freshness; use `previewSubmit` for a full dry run.
    function verifyAttestation(Attestation calldata attestation, address key, bytes calldata signature)
        external
        view
        returns (bool valid);

    /// @notice Dry run of `submit`, returning the same reverts on failure.
    function previewSubmit(Attestation calldata attestation, address key, bytes calldata signature)
        external
        view
        returns (bytes32 digest);

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice EIP-712 type hash of the `WatchtowerAttestation` struct.
    function ATTESTATION_TYPEHASH() external pure returns (bytes32);

    /// @notice EIP-712 domain separator of this deployment.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice EIP-712 digest of `attestation` under this deployment's domain.
    function hashAttestation(Attestation calldata attestation) external view returns (bytes32 digest);

    /// @notice Head record of an asset.
    function headOf(bytes32 assetId) external view returns (Head memory head);

    /// @notice Policy of an asset.
    function policyOf(bytes32 assetId) external view returns (AssetPolicy memory policy);

    /// @notice Registered window of a key.
    function keyWindowOf(bytes32 assetId, address key) external view returns (KeyWindow memory window);

    /// @notice Whether `key` may sign for `assetId` at height `signedAtBlock`.
    function isKeyActiveAt(bytes32 assetId, address key, uint64 signedAtBlock) external view returns (bool active);

    /// @notice Sequence number the next accepted attestation must carry.
    function nextSequence(bytes32 assetId) external view returns (uint64 sequence);

    /// @notice Classification of the current head, with its age in blocks.
    function freshnessOf(bytes32 assetId) external view returns (Freshness status, uint256 age);

    /// @notice Reverts with `NotFresh` unless the head is fresh, and final when `requireFinal` is set.
    function requireFresh(bytes32 assetId, bool requireFinal) external view returns (Freshness status, uint256 age);
}
