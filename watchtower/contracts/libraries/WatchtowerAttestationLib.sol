// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IWatchtowerFreshnessLayer} from "../interfaces/IWatchtowerFreshnessLayer.sol";

/// @title WatchtowerAttestationLib
/// @notice EIP-712 encoding of the ERC-8415 `WatchtowerAttestation` payload.
library WatchtowerAttestationLib {
    /// @notice The literal EIP-712 type string, exposed for off-chain parity checks.
    string internal constant ATTESTATION_TYPE =
        "WatchtowerAttestation(bytes32 assetId,uint64 signedAtBlock,uint64 sequenceNumber,uint64 freshnessThreshold)";

    /// @notice EIP-712 type hash of `ATTESTATION_TYPE`, evaluated at compile time.
    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(bytes(ATTESTATION_TYPE));

    /// @notice `hashStruct(attestation)` as defined by EIP-712.
    function hashStruct(IWatchtowerFreshnessLayer.Attestation memory attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                attestation.assetId,
                attestation.signedAtBlock,
                attestation.sequenceNumber,
                attestation.freshnessThreshold
            )
        );
    }
}
