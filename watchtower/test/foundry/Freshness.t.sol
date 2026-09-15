// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {WatchtowerTestBase} from "./Base.t.sol";

import {IWatchtowerFreshnessLayer} from "../../contracts/interfaces/IWatchtowerFreshnessLayer.sol";
import {FreshnessLib} from "../../contracts/libraries/FreshnessLib.sol";

/// @notice Freshness classification: UNKNOWN, STALE, FRESH_PENDING and FRESH_FINAL, and the
///         boundaries between them.
contract FreshnessTest is WatchtowerTestBase {
    uint64 internal constant THRESHOLD = 64;

    IWatchtowerFreshnessLayer.Freshness internal constant UNKNOWN = IWatchtowerFreshnessLayer.Freshness.UNKNOWN;
    IWatchtowerFreshnessLayer.Freshness internal constant STALE = IWatchtowerFreshnessLayer.Freshness.STALE;
    IWatchtowerFreshnessLayer.Freshness internal constant PENDING = IWatchtowerFreshnessLayer.Freshness.FRESH_PENDING;
    IWatchtowerFreshnessLayer.Freshness internal constant FINAL = IWatchtowerFreshnessLayer.Freshness.FRESH_FINAL;

    function _assertFreshness(IWatchtowerFreshnessLayer.Freshness expected, uint256 expectedAge) internal view {
        (IWatchtowerFreshnessLayer.Freshness status, uint256 age) = layer.freshnessOf(assetId);
        assertEq(uint256(status), uint256(expected), "unexpected freshness");
        assertEq(age, expectedAge, "unexpected age");
    }

    // ------------------------------------------------------------------
    // UNKNOWN
    // ------------------------------------------------------------------

    function test_unregisteredAssetIsUnknown() public view {
        (IWatchtowerFreshnessLayer.Freshness status, uint256 age) = layer.freshnessOf(keccak256("never-registered"));
        assertEq(uint256(status), uint256(UNKNOWN));
        assertEq(age, 0);
    }

    function test_registeredAssetWithNoHeadIsUnknown() public view {
        _assertFreshness(UNKNOWN, 0);
    }

    // ------------------------------------------------------------------
    // Boundaries
    // ------------------------------------------------------------------

    function test_classificationBoundaries() public {
        _submitAt(1, START_BLOCK, THRESHOLD);

        // Age 0: recorded in the same block it was signed for, not yet final.
        _assertFreshness(PENDING, 0);

        // Age just below the finality depth: still pending.
        vm.roll(START_BLOCK + FINALITY_DEPTH - 1);
        _assertFreshness(PENDING, FINALITY_DEPTH - 1);

        // Age exactly at the finality depth: final.
        vm.roll(START_BLOCK + FINALITY_DEPTH);
        _assertFreshness(FINAL, FINALITY_DEPTH);

        // Age exactly at the declared threshold: still final.
        vm.roll(START_BLOCK + THRESHOLD);
        _assertFreshness(FINAL, THRESHOLD);

        // One block past the threshold: stale.
        vm.roll(START_BLOCK + THRESHOLD + 1);
        _assertFreshness(STALE, THRESHOLD + 1);

        // Staleness is permanent until a new attestation lands.
        vm.roll(START_BLOCK + 10_000);
        _assertFreshness(STALE, 10_000);
    }

    function test_freshAttestationRefreshesAStaleFeed() public {
        _submitAt(1, START_BLOCK, THRESHOLD);

        vm.roll(START_BLOCK + THRESHOLD + 1);
        _assertFreshness(STALE, THRESHOLD + 1);

        uint64 now_ = uint64(block.number);
        _submitAt(2, now_, THRESHOLD);
        _assertFreshness(PENDING, 0);
    }

    function test_zeroFinalityDepthMakesEveryFreshHeadFinal() public {
        vm.prank(steward);
        layer.setPolicy(assetId, 0, MAX_THRESHOLD);

        _submitAt(1, START_BLOCK, THRESHOLD);
        _assertFreshness(FINAL, 0);

        vm.roll(START_BLOCK + THRESHOLD);
        _assertFreshness(FINAL, THRESHOLD);

        vm.roll(START_BLOCK + THRESHOLD + 1);
        _assertFreshness(STALE, THRESHOLD + 1);
    }

    function test_thresholdIsTakenFromTheAttestationNotThePolicy() public {
        // The watchtower declares a tighter threshold (8) than the asset's bound (256).
        _submitAt(1, START_BLOCK, 8);
        assertEq(layer.headOf(assetId).freshnessThreshold, 8);

        // At its own threshold it is still fresh, and still short of the 32-block finality depth.
        vm.roll(START_BLOCK + 8);
        _assertFreshness(PENDING, 8);

        // One block later it is stale, far below the asset's 256-block bound.
        vm.roll(START_BLOCK + 9);
        _assertFreshness(STALE, 9);
    }

    function test_policyChangeReclassifiesTheHead() public {
        _submitAt(1, START_BLOCK, THRESHOLD);

        vm.roll(START_BLOCK + 10);
        _assertFreshness(PENDING, 10); // finality depth is 32

        // Lowering the finality depth promotes the same head to final.
        vm.prank(steward);
        layer.setPolicy(assetId, 5, MAX_THRESHOLD);
        _assertFreshness(FINAL, 10);
    }

    // ------------------------------------------------------------------
    // Revocation collapses freshness
    // ------------------------------------------------------------------

    function test_revokedKeyCollapsesHeadToStale() public {
        vm.roll(START_BLOCK + FINALITY_DEPTH);
        _submitAt(1, START_BLOCK, THRESHOLD);
        _assertFreshness(FINAL, FINALITY_DEPTH);

        vm.prank(steward);
        layer.revokeKey(assetId, watchtower);

        // The head keeps its real age but must never read as fresh again.
        _assertFreshness(STALE, FINALITY_DEPTH);

        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotFresh.selector, assetId, STALE));
        layer.requireFresh(assetId, false);
    }

    // ------------------------------------------------------------------
    // requireFresh
    // ------------------------------------------------------------------

    function test_requireFreshGuards() public {
        // No head yet.
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotFresh.selector, assetId, UNKNOWN));
        layer.requireFresh(assetId, false);

        _submitAt(1, START_BLOCK, THRESHOLD);

        // Pending: allowed when finality is not required, refused when it is.
        (IWatchtowerFreshnessLayer.Freshness status, uint256 age) = layer.requireFresh(assetId, false);
        assertEq(uint256(status), uint256(PENDING));
        assertEq(age, 0);

        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotFresh.selector, assetId, PENDING));
        layer.requireFresh(assetId, true);

        // Final: allowed either way.
        vm.roll(START_BLOCK + FINALITY_DEPTH);
        (status, age) = layer.requireFresh(assetId, true);
        assertEq(uint256(status), uint256(FINAL));
        assertEq(age, FINALITY_DEPTH);
        (status,) = layer.requireFresh(assetId, false);
        assertEq(uint256(status), uint256(FINAL));

        // Stale: refused either way.
        vm.roll(START_BLOCK + THRESHOLD + 1);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotFresh.selector, assetId, STALE));
        layer.requireFresh(assetId, false);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotFresh.selector, assetId, STALE));
        layer.requireFresh(assetId, true);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_classificationMatchesTheRule(uint64 threshold, uint64 finalityDepth, uint32 elapsed) public {
        threshold = uint64(bound(threshold, 1, MAX_THRESHOLD));
        finalityDepth = uint64(bound(finalityDepth, 0, threshold));

        vm.prank(steward);
        layer.setPolicy(assetId, finalityDepth, MAX_THRESHOLD);

        _submitAt(1, START_BLOCK, threshold);
        vm.roll(uint256(START_BLOCK) + elapsed);

        (IWatchtowerFreshnessLayer.Freshness status, uint256 age) = layer.freshnessOf(assetId);
        (IWatchtowerFreshnessLayer.Freshness expected, uint256 expectedAge) =
            FreshnessLib.classify(block.number, START_BLOCK, threshold, finalityDepth);

        assertEq(uint256(status), uint256(expected));
        assertEq(age, expectedAge);
        assertEq(age, elapsed);

        if (elapsed > threshold) {
            assertEq(uint256(status), uint256(STALE));
        } else if (elapsed >= finalityDepth) {
            assertEq(uint256(status), uint256(FINAL));
        } else {
            assertEq(uint256(status), uint256(PENDING));
        }
    }

    function testFuzz_libraryClassifyIsTotal(
        uint256 currentBlock,
        uint64 signedAtBlock,
        uint64 threshold,
        uint64 finalityDepth
    ) public pure {
        (IWatchtowerFreshnessLayer.Freshness status, uint256 age) =
            FreshnessLib.classify(currentBlock, signedAtBlock, threshold, finalityDepth);

        if (signedAtBlock == 0 || currentBlock < signedAtBlock) {
            assertEq(uint256(status), uint256(UNKNOWN));
            assertEq(age, 0);
        } else {
            assertEq(age, currentBlock - signedAtBlock);
            assertTrue(status != UNKNOWN);
            if (age > threshold) assertEq(uint256(status), uint256(STALE));
        }
    }
}
