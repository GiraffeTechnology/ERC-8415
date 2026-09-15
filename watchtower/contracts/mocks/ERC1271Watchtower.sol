// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC1271} from "../interfaces/IERC1271.sol";
import {SignatureVerifier} from "../libraries/SignatureVerifier.sol";

/// @title ERC1271Watchtower
/// @notice Minimal smart-contract watchtower key: a signer contract that delegates to one EOA.
/// @dev Used by the test suites to exercise the ERC-1271 path of `SignatureVerifier`. It is a
///      faithful example of how a multisig or session-key watchtower would be registered as a key.
contract ERC1271Watchtower is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, bool ok) = SignatureVerifier.tryRecover(hash, signature);
        if (ok && recovered == owner) return SignatureVerifier.ERC1271_MAGIC_VALUE;
        return 0xffffffff;
    }
}
