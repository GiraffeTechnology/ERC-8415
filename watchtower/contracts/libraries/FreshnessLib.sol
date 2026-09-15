// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IWatchtowerFreshnessLayer} from "../interfaces/IWatchtowerFreshnessLayer.sol";

/// @title FreshnessLib
/// @notice The ERC-8415 freshness classification rule, isolated so that on-chain consumers and
///         off-chain watchtowers can share one definition.
library FreshnessLib {
    /// @notice Classifies an attestation observed at `currentBlock`.
    /// @dev The rule, in order:
    ///      1. `signedAtBlock == 0`            -> `UNKNOWN` (no head recorded).
    ///      2. `age > freshnessThreshold`      -> `STALE`.
    ///      3. `age >= finalityDepth`          -> `FRESH_FINAL`.
    ///      4. otherwise                       -> `FRESH_PENDING`.
    ///      A `finalityDepth` of zero makes every non-stale head final, which suits chains with
    ///      single-slot finality. Registration forbids `finalityDepth > maxFreshnessThreshold`,
    ///      so `FRESH_FINAL` is always reachable.
    /// @param currentBlock       Height the classification is evaluated at.
    /// @param signedAtBlock      Height the attestation was signed at.
    /// @param freshnessThreshold Maximum age in blocks for which the attestation stays fresh.
    /// @param finalityDepth      Age in blocks at which a fresh attestation becomes final.
    function classify(uint256 currentBlock, uint64 signedAtBlock, uint64 freshnessThreshold, uint64 finalityDepth)
        internal
        pure
        returns (IWatchtowerFreshnessLayer.Freshness status, uint256 age)
    {
        if (signedAtBlock == 0 || currentBlock < signedAtBlock) {
            return (IWatchtowerFreshnessLayer.Freshness.UNKNOWN, 0);
        }

        age = currentBlock - signedAtBlock;

        if (age > freshnessThreshold) {
            return (IWatchtowerFreshnessLayer.Freshness.STALE, age);
        }
        if (age >= finalityDepth) {
            return (IWatchtowerFreshnessLayer.Freshness.FRESH_FINAL, age);
        }
        return (IWatchtowerFreshnessLayer.Freshness.FRESH_PENDING, age);
    }
}
