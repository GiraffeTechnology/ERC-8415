// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC165} from "./interfaces/IERC165.sol";
import {IWatchtowerFreshnessLayer} from "./interfaces/IWatchtowerFreshnessLayer.sol";
import {FreshnessLib} from "./libraries/FreshnessLib.sol";
import {SignatureVerifier} from "./libraries/SignatureVerifier.sol";
import {WatchtowerAttestationLib} from "./libraries/WatchtowerAttestationLib.sol";

/// @title WatchtowerFreshnessLayer
/// @notice Reference implementation of the ERC-8415 Watchtower Freshness Layer.
/// @dev Three invariants hold for every accepted attestation:
///      1. Authority  - the signature verifies against a key whose rotation window contains
///                      `signedAtBlock`, evaluated at the height signed for rather than the
///                      height submitted at, so a hand-over never invalidates in-flight work.
///      2. Sequencing - `sequenceNumber` equals the head's sequence plus one, exactly. Gaps,
///                      repeats and reorderings are rejected, which also makes replay impossible.
///      3. Freshness  - an attestation that is already stale at submission time is rejected, and
///                      the recorded head is classified against its own declared threshold.
contract WatchtowerFreshnessLayer is IWatchtowerFreshnessLayer, IERC165 {
    // ---------------------------------------------------------------------
    // EIP-712 domain
    // ---------------------------------------------------------------------

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    string private constant _NAME = "ERC-8415 Watchtower Freshness Layer";
    string private constant _VERSION = "1";

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    /// @dev Namespace separating asset identifiers from any other keccak-derived value.
    bytes32 private constant _ASSET_ID_NAMESPACE = keccak256("ERC8415.AssetId.v1");

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(bytes32 assetId => AssetPolicy) private _policies;
    mapping(bytes32 assetId => Head) private _heads;
    mapping(bytes32 assetId => mapping(address key => KeyWindow)) private _keys;

    constructor() {
        _HASHED_NAME = keccak256(bytes(_NAME));
        _HASHED_VERSION = keccak256(bytes(_VERSION));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_THIS = address(this);
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlySteward(bytes32 assetId) {
        AssetPolicy storage policy = _policies[assetId];
        if (!policy.registered) revert AssetNotRegistered(assetId);
        if (msg.sender != policy.steward) revert NotSteward(assetId, msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // Asset lifecycle
    // ---------------------------------------------------------------------

    /// @inheritdoc IWatchtowerFreshnessLayer
    function computeAssetId(address registrar, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(_ASSET_ID_NAMESPACE, registrar, salt));
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function registerAsset(
        bytes32 salt,
        address steward,
        uint64 finalityDepth,
        uint64 maxFreshnessThreshold,
        uint64 initialSequence
    ) external returns (bytes32 assetId) {
        if (steward == address(0)) revert ZeroAddress();
        _validatePolicy(finalityDepth, maxFreshnessThreshold);

        assetId = computeAssetId(msg.sender, salt);
        AssetPolicy storage policy = _policies[assetId];
        if (policy.registered) revert AssetAlreadyRegistered(assetId);

        policy.steward = steward;
        policy.finalityDepth = finalityDepth;
        policy.maxFreshnessThreshold = maxFreshnessThreshold;
        policy.registered = true;

        // `signedAtBlock` stays zero, which marks the feed as having no head yet, while the
        // sequence cursor starts at `initialSequence` so an existing feed can be migrated.
        _heads[assetId].sequenceNumber = initialSequence;

        emit AssetRegistered(assetId, msg.sender, steward, finalityDepth, maxFreshnessThreshold, initialSequence);
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function setPolicy(bytes32 assetId, uint64 finalityDepth, uint64 maxFreshnessThreshold)
        external
        onlySteward(assetId)
    {
        _validatePolicy(finalityDepth, maxFreshnessThreshold);

        AssetPolicy storage policy = _policies[assetId];
        policy.finalityDepth = finalityDepth;
        policy.maxFreshnessThreshold = maxFreshnessThreshold;

        emit PolicyUpdated(assetId, finalityDepth, maxFreshnessThreshold);
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function transferStewardship(bytes32 assetId, address newSteward) external onlySteward(assetId) {
        if (newSteward == address(0)) revert ZeroAddress();
        _policies[assetId].pendingSteward = newSteward;
        emit StewardshipTransferStarted(assetId, msg.sender, newSteward);
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function acceptStewardship(bytes32 assetId) external {
        AssetPolicy storage policy = _policies[assetId];
        if (!policy.registered) revert AssetNotRegistered(assetId);
        if (msg.sender != policy.pendingSteward) revert NotPendingSteward(assetId, msg.sender);

        address previous = policy.steward;
        policy.steward = msg.sender;
        policy.pendingSteward = address(0);

        emit StewardshipTransferred(assetId, previous, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Key rotation
    // ---------------------------------------------------------------------

    /// @inheritdoc IWatchtowerFreshnessLayer
    function rotateKey(bytes32 assetId, address key, uint64 validFromBlock, uint64 validToBlock)
        external
        onlySteward(assetId)
    {
        if (key == address(0)) revert ZeroAddress();
        if (validFromBlock > validToBlock) revert InvalidKeyWindow(validFromBlock, validToBlock);

        KeyWindow storage window = _keys[assetId][key];
        if (window.revoked) revert KeyAlreadyRevoked(assetId, key);

        window.validFromBlock = validFromBlock;
        window.validToBlock = validToBlock;
        window.registered = true;

        emit KeyRotated(assetId, key, validFromBlock, validToBlock);
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function revokeKey(bytes32 assetId, address key) external onlySteward(assetId) {
        KeyWindow storage window = _keys[assetId][key];
        if (!window.registered) revert KeyNotRegistered(assetId, key);
        if (window.revoked) revert KeyAlreadyRevoked(assetId, key);

        window.revoked = true;

        emit KeyRevoked(assetId, key, uint64(block.number));
    }

    // ---------------------------------------------------------------------
    // Attestations
    // ---------------------------------------------------------------------

    /// @inheritdoc IWatchtowerFreshnessLayer
    function submit(Attestation calldata attestation, address key, bytes calldata signature)
        external
        returns (bytes32 digest)
    {
        digest = _validate(attestation, key, signature);

        _heads[attestation.assetId] = Head({
            signedAtBlock: attestation.signedAtBlock,
            sequenceNumber: attestation.sequenceNumber,
            freshnessThreshold: attestation.freshnessThreshold,
            recordedAtBlock: uint64(block.number),
            key: key
        });

        emit AttestationAccepted(
            attestation.assetId,
            key,
            attestation.sequenceNumber,
            attestation.signedAtBlock,
            attestation.freshnessThreshold,
            digest
        );
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function previewSubmit(Attestation calldata attestation, address key, bytes calldata signature)
        external
        view
        returns (bytes32 digest)
    {
        return _validate(attestation, key, signature);
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function verifyAttestation(Attestation calldata attestation, address key, bytes calldata signature)
        external
        view
        returns (bool)
    {
        if (!isKeyActiveAt(attestation.assetId, key, attestation.signedAtBlock)) return false;
        return SignatureVerifier.isValidSignatureNow(key, hashAttestation(attestation), signature);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IWatchtowerFreshnessLayer
    function ATTESTATION_TYPEHASH() external pure returns (bytes32) {
        return WatchtowerAttestationLib.ATTESTATION_TYPEHASH;
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID && address(this) == _CACHED_THIS) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator();
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function hashAttestation(Attestation calldata attestation) public view returns (bytes32) {
        return
            keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), WatchtowerAttestationLib.hashStruct(attestation)));
    }

    /// @notice ERC-5267 domain description, for wallets and off-chain signers.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", _NAME, _VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function headOf(bytes32 assetId) external view returns (Head memory) {
        return _heads[assetId];
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function policyOf(bytes32 assetId) external view returns (AssetPolicy memory) {
        return _policies[assetId];
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function keyWindowOf(bytes32 assetId, address key) external view returns (KeyWindow memory) {
        return _keys[assetId][key];
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function isKeyActiveAt(bytes32 assetId, address key, uint64 signedAtBlock) public view returns (bool) {
        KeyWindow storage window = _keys[assetId][key];
        if (!window.registered || window.revoked) return false;
        return signedAtBlock >= window.validFromBlock && signedAtBlock <= window.validToBlock;
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function nextSequence(bytes32 assetId) external view returns (uint64) {
        uint64 last = _heads[assetId].sequenceNumber;
        if (last == type(uint64).max) revert SequenceExhausted(assetId);
        unchecked {
            return last + 1;
        }
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function freshnessOf(bytes32 assetId) public view returns (Freshness status, uint256 age) {
        AssetPolicy storage policy = _policies[assetId];
        if (!policy.registered) return (Freshness.UNKNOWN, 0);

        Head storage head = _heads[assetId];
        (status, age) =
            FreshnessLib.classify(block.number, head.signedAtBlock, head.freshnessThreshold, policy.finalityDepth);

        // A head signed by a key that was later revoked must never read as fresh: revocation is
        // retroactive, so the head collapses to `STALE` while keeping its real age.
        if (status != Freshness.UNKNOWN && _keys[assetId][head.key].revoked) {
            return (Freshness.STALE, age);
        }
    }

    /// @inheritdoc IWatchtowerFreshnessLayer
    function requireFresh(bytes32 assetId, bool requireFinal) external view returns (Freshness status, uint256 age) {
        (status, age) = freshnessOf(assetId);

        if (status == Freshness.FRESH_FINAL) return (status, age);
        if (status == Freshness.FRESH_PENDING && !requireFinal) return (status, age);

        revert NotFresh(assetId, status);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IWatchtowerFreshnessLayer).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == 0x84b0196e; // ERC-5267
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Full validation shared by `submit` and `previewSubmit`.
    function _validate(Attestation calldata attestation, address key, bytes calldata signature)
        internal
        view
        returns (bytes32 digest)
    {
        bytes32 assetId = attestation.assetId;

        AssetPolicy storage policy = _policies[assetId];
        if (!policy.registered) revert AssetNotRegistered(assetId);

        // --- freshness bounds -------------------------------------------------
        uint64 maxThreshold = policy.maxFreshnessThreshold;
        if (attestation.freshnessThreshold == 0 || attestation.freshnessThreshold > maxThreshold) {
            revert FreshnessThresholdOutOfRange(attestation.freshnessThreshold, maxThreshold);
        }
        if (attestation.signedAtBlock == 0) revert InvalidSignedAtBlock();
        if (attestation.signedAtBlock > block.number) {
            revert AttestationFromFuture(attestation.signedAtBlock, block.number);
        }

        uint256 age = block.number - attestation.signedAtBlock;
        if (age > attestation.freshnessThreshold) {
            revert AttestationAlreadyStale(age, attestation.freshnessThreshold);
        }

        // --- strict monotonic sequencing --------------------------------------
        Head storage head = _heads[assetId];
        uint64 last = head.sequenceNumber;
        if (last == type(uint64).max) revert SequenceExhausted(assetId);

        uint64 expected;
        unchecked {
            expected = last + 1;
        }
        if (attestation.sequenceNumber != expected) {
            revert SequenceNotContiguous(assetId, expected, attestation.sequenceNumber);
        }
        if (attestation.signedAtBlock < head.signedAtBlock) {
            revert AttestationOutOfOrder(attestation.signedAtBlock, head.signedAtBlock);
        }

        // --- key rotation window ----------------------------------------------
        KeyWindow storage window = _keys[assetId][key];
        if (!window.registered) revert KeyNotRegistered(assetId, key);
        if (window.revoked) revert KeyAlreadyRevoked(assetId, key);
        if (attestation.signedAtBlock < window.validFromBlock || attestation.signedAtBlock > window.validToBlock) {
            revert KeyNotActiveAtBlock(assetId, key, attestation.signedAtBlock);
        }

        // --- signature ---------------------------------------------------------
        digest = hashAttestation(attestation);
        if (!SignatureVerifier.isValidSignatureNow(key, digest, signature)) {
            revert InvalidSignature(assetId, key);
        }
    }

    /// @dev `FRESH_FINAL` must stay reachable, so finality may not sit beyond the freshness bound.
    function _validatePolicy(uint64 finalityDepth, uint64 maxFreshnessThreshold) private pure {
        if (maxFreshnessThreshold == 0 || finalityDepth > maxFreshnessThreshold) {
            revert InvalidPolicy(finalityDepth, maxFreshnessThreshold);
        }
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }
}
