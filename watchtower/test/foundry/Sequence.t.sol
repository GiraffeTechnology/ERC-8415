// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {WatchtowerTestBase} from "./Base.t.sol";

import {IWatchtowerFreshnessLayer} from "../../contracts/interfaces/IWatchtowerFreshnessLayer.sol";

/// @notice Strict monotonic sequencing: the next accepted sequence is always exactly `last + 1`.
contract SequenceTest is WatchtowerTestBase {
    uint64 internal constant THRESHOLD = 64;

    function _prepare(uint64 sequenceNumber, uint64 signedAtBlock)
        internal
        returns (IWatchtowerFreshnessLayer.Attestation memory attestation, bytes memory signature)
    {
        attestation = _attestation(sequenceNumber, signedAtBlock, THRESHOLD);
        signature = _sign(watchtowerPk, attestation);
    }

    function test_firstAcceptedSequenceIsOne() public {
        assertEq(layer.nextSequence(assetId), 1);
        assertEq(layer.headOf(assetId).signedAtBlock, 0);

        (IWatchtowerFreshnessLayer.Attestation memory zeroth, bytes memory zerothSignature) = _prepare(0, START_BLOCK);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.SequenceNotContiguous.selector, assetId, 1, 0));
        layer.submit(zeroth, watchtower, zerothSignature);

        _submitAt(1, START_BLOCK, THRESHOLD);
        assertEq(layer.headOf(assetId).sequenceNumber, 1);
        assertEq(layer.nextSequence(assetId), 2);
    }

    function test_contiguousSequenceIsAccepted() public {
        for (uint64 i = 1; i <= 8; ++i) {
            vm.roll(START_BLOCK + i);
            _submitAt(i, START_BLOCK + i, THRESHOLD);
            assertEq(layer.headOf(assetId).sequenceNumber, i);
            assertEq(layer.nextSequence(assetId), i + 1);
        }
    }

    function test_gapIsRejected() public {
        _submitAt(1, START_BLOCK, THRESHOLD);

        (IWatchtowerFreshnessLayer.Attestation memory skipped, bytes memory signature) = _prepare(3, START_BLOCK);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.SequenceNotContiguous.selector, assetId, 2, 3));
        layer.submit(skipped, watchtower, signature);

        // The head is untouched, and the gap can still be filled by the right number.
        assertEq(layer.headOf(assetId).sequenceNumber, 1);
        _submitAt(2, START_BLOCK, THRESHOLD);
        assertEq(layer.headOf(assetId).sequenceNumber, 2);
    }

    function test_replayOfTheHeadIsRejected() public {
        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, THRESHOLD);
        bytes memory signature = _sign(watchtowerPk, attestation);

        layer.submit(attestation, watchtower, signature);

        // The identical, still validly signed payload cannot be replayed.
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.SequenceNotContiguous.selector, assetId, 2, 1));
        layer.submit(attestation, watchtower, signature);
    }

    function test_olderSequenceIsRejected() public {
        _submitAt(1, START_BLOCK, THRESHOLD);
        _submitAt(2, START_BLOCK, THRESHOLD);

        (IWatchtowerFreshnessLayer.Attestation memory stale, bytes memory signature) = _prepare(1, START_BLOCK);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.SequenceNotContiguous.selector, assetId, 3, 1));
        layer.submit(stale, watchtower, signature);
    }

    function test_sequenceIsPerAssetNotGlobal() public {
        vm.prank(registrar);
        bytes32 secondAssetId = layer.registerAsset(keccak256("BTC/USD"), steward, FINALITY_DEPTH, MAX_THRESHOLD, 0);
        vm.prank(steward);
        layer.rotateKey(secondAssetId, watchtower, 0, type(uint64).max);

        _submitAt(1, START_BLOCK, THRESHOLD);
        _submitAt(2, START_BLOCK, THRESHOLD);

        // The second feed still starts at one.
        assertEq(layer.nextSequence(secondAssetId), 1);

        IWatchtowerFreshnessLayer.Attestation memory attestation = IWatchtowerFreshnessLayer.Attestation({
            assetId: secondAssetId, signedAtBlock: START_BLOCK, sequenceNumber: 1, freshnessThreshold: THRESHOLD
        });
        layer.submit(attestation, watchtower, _sign(watchtowerPk, attestation));

        assertEq(layer.headOf(secondAssetId).sequenceNumber, 1);
        assertEq(layer.headOf(assetId).sequenceNumber, 2);
    }

    function test_feedCanBeMigratedFromAnInitialSequence() public {
        vm.prank(registrar);
        bytes32 migrated = layer.registerAsset(keccak256("migrated"), steward, FINALITY_DEPTH, MAX_THRESHOLD, 4_000);
        vm.prank(steward);
        layer.rotateKey(migrated, watchtower, 0, type(uint64).max);

        assertEq(layer.nextSequence(migrated), 4_001);
        // No head exists yet even though the cursor is non-zero.
        (IWatchtowerFreshnessLayer.Freshness status,) = layer.freshnessOf(migrated);
        assertEq(uint256(status), uint256(IWatchtowerFreshnessLayer.Freshness.UNKNOWN));

        IWatchtowerFreshnessLayer.Attestation memory attestation = IWatchtowerFreshnessLayer.Attestation({
            assetId: migrated, signedAtBlock: START_BLOCK, sequenceNumber: 4_001, freshnessThreshold: THRESHOLD
        });
        layer.submit(attestation, watchtower, _sign(watchtowerPk, attestation));
        assertEq(layer.headOf(migrated).sequenceNumber, 4_001);
    }

    function test_attestationSignedBeforeTheHeadIsRejected() public {
        vm.roll(START_BLOCK + 10);
        _submitAt(1, START_BLOCK + 10, THRESHOLD);

        // Correct sequence, but signed at a height older than the head: the feed cannot go backwards.
        (IWatchtowerFreshnessLayer.Attestation memory backwards, bytes memory signature) = _prepare(2, START_BLOCK + 9);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWatchtowerFreshnessLayer.AttestationOutOfOrder.selector, START_BLOCK + 9, START_BLOCK + 10
            )
        );
        layer.submit(backwards, watchtower, signature);

        // The same height as the head is allowed: several observations may share a block.
        _submitAt(2, START_BLOCK + 10, THRESHOLD);
        assertEq(layer.headOf(assetId).sequenceNumber, 2);
    }

    function test_attestationFromTheFutureIsRejected() public {
        (IWatchtowerFreshnessLayer.Attestation memory future, bytes memory signature) = _prepare(1, START_BLOCK + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWatchtowerFreshnessLayer.AttestationFromFuture.selector, START_BLOCK + 1, START_BLOCK
            )
        );
        layer.submit(future, watchtower, signature);
    }

    function test_zeroSignedAtBlockIsRejected() public {
        (IWatchtowerFreshnessLayer.Attestation memory zero, bytes memory signature) = _prepare(1, 0);
        vm.expectRevert(IWatchtowerFreshnessLayer.InvalidSignedAtBlock.selector);
        layer.submit(zero, watchtower, signature);
    }

    function test_attestationAlreadyStaleAtSubmissionIsRejected() public {
        uint64 signedAt = START_BLOCK;
        uint64 threshold = 10;

        // Age 11 against a threshold of 10: the head would be born stale.
        vm.roll(START_BLOCK + 11);

        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, signedAt, threshold);
        bytes memory signature = _sign(watchtowerPk, attestation);
        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.AttestationAlreadyStale.selector, 11, threshold)
        );
        layer.submit(attestation, watchtower, signature);

        // Exactly at the threshold it is still accepted.
        vm.roll(START_BLOCK + 10);
        _submitAt(1, signedAt, threshold);
        assertEq(layer.headOf(assetId).sequenceNumber, 1);
    }

    function test_zeroThresholdIsRejected() public {
        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 0);
        bytes memory signature = _sign(watchtowerPk, attestation);

        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.FreshnessThresholdOutOfRange.selector, 0, MAX_THRESHOLD)
        );
        layer.submit(attestation, watchtower, signature);
    }

    function testFuzz_onlyTheSuccessorIsAccepted(uint64 candidate) public {
        _submitAt(1, START_BLOCK, THRESHOLD);
        vm.assume(candidate != 2);

        (IWatchtowerFreshnessLayer.Attestation memory attestation, bytes memory signature) =
            _prepare(candidate, START_BLOCK);

        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.SequenceNotContiguous.selector, assetId, 2, candidate)
        );
        layer.submit(attestation, watchtower, signature);

        assertEq(layer.headOf(assetId).sequenceNumber, 1);
    }

    function testFuzz_sequenceNeverRegresses(uint8 steps) public {
        uint64 bounded = uint64(bound(steps, 1, 40));

        for (uint64 i = 1; i <= bounded; ++i) {
            uint64 previous = layer.headOf(assetId).sequenceNumber;
            vm.roll(START_BLOCK + i);
            _submitAt(i, START_BLOCK + i, THRESHOLD);
            uint64 current = layer.headOf(assetId).sequenceNumber;

            assertEq(current, previous + 1);
        }
    }
}
