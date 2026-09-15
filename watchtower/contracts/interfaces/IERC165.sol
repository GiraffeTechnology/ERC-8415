// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @dev Local copy of the ERC-165 interface so that the reference implementation
/// builds without external dependencies under both Foundry and Hardhat.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
