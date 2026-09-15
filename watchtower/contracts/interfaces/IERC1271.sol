// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @dev Local copy of the ERC-1271 interface so that the reference implementation
/// builds without external dependencies under both Foundry and Hardhat.
interface IERC1271 {
    /// @return magicValue `0x1626ba7e` when `signature` is a valid signature of `hash` for this contract.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}
