// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC1271} from "../interfaces/IERC1271.sol";

/// @title SignatureVerifier
/// @notice Malleability-safe ECDSA verification with an ERC-1271 fallback for contract keys.
/// @dev Dependency-free so the reference implementation compiles identically under Foundry and
///      Hardhat. Behaviour matches OpenZeppelin's `SignatureChecker`.
library SignatureVerifier {
    /// @dev `IERC1271.isValidSignature.selector`.
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev Half of the secp256k1 curve order; signatures with a higher `s` are the malleable
    ///      counterpart of a valid signature and are rejected (EIP-2).
    uint256 internal constant SECP256K1_HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice Returns true when `signature` proves that `signer` signed `digest`.
    /// @dev Dispatches to ERC-1271 when `signer` has code, and to `ecrecover` otherwise.
    function isValidSignatureNow(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (signer == address(0)) return false;

        if (signer.code.length > 0) {
            (bool success, bytes memory returndata) =
                signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, signature)));
            return
                success && returndata.length >= 32 && abi.decode(returndata, (bytes32)) == bytes32(ERC1271_MAGIC_VALUE);
        }

        (address recovered, bool ok) = tryRecover(digest, signature);
        return ok && recovered == signer;
    }

    /// @notice Recovers the signer of `digest`, rejecting malformed and malleable signatures.
    /// @return recovered The signer, or the zero address when recovery fails.
    /// @return ok Whether recovery succeeded.
    function tryRecover(bytes32 digest, bytes memory signature) internal pure returns (address recovered, bool ok) {
        if (signature.length != 65) return (address(0), false);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (uint256(s) > SECP256K1_HALF_N) return (address(0), false);
        if (v != 27 && v != 28) return (address(0), false);

        recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) return (address(0), false);
        ok = true;
    }
}
