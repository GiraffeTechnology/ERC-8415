// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {WatchtowerTestBase} from "./Base.t.sol";

import {IWatchtowerFreshnessLayer} from "../../contracts/interfaces/IWatchtowerFreshnessLayer.sol";

/// @notice Key rotation: a signature is judged against the window that was open at the height it
///         was signed for, not the height it was submitted at.
contract KeyRotationTest is WatchtowerTestBase {
    uint64 internal constant THRESHOLD = 64;

    address internal rotating;
    uint256 internal rotatingPk;

    function setUp() public override {
        super.setUp();
        (rotating, rotatingPk) = makeAddrAndKey("rotating");
    }

    function _submitAs(
        address key,
        uint256 privateKey,
        uint64 sequenceNumber,
        uint64 signedAtBlock,
        uint64 freshnessThreshold
    ) internal returns (IWatchtowerFreshnessLayer.Attestation memory attestation, bytes memory signature) {
        attestation = _attestation(sequenceNumber, signedAtBlock, freshnessThreshold);
        signature = _sign(privateKey, attestation);
        vm.prank(relayer);
        layer.submit(attestation, key, signature);
    }

    // ------------------------------------------------------------------
    // Window boundaries
    // ------------------------------------------------------------------

    function test_windowBoundsAreInclusive() public {
        uint64 validFrom = START_BLOCK + 10;
        uint64 validTo = START_BLOCK + 20;

        vm.prank(steward);
        layer.rotateKey(assetId, rotating, validFrom, validTo);

        vm.roll(START_BLOCK + 25);

        assertFalse(layer.isKeyActiveAt(assetId, rotating, validFrom - 1));
        assertTrue(layer.isKeyActiveAt(assetId, rotating, validFrom));
        assertTrue(layer.isKeyActiveAt(assetId, rotating, validTo));
        assertFalse(layer.isKeyActiveAt(assetId, rotating, validTo + 1));

        // One block before the window opens.
        IWatchtowerFreshnessLayer.Attestation memory early = _attestation(1, validFrom - 1, THRESHOLD);
        bytes memory earlySignature = _sign(rotatingPk, early);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWatchtowerFreshnessLayer.KeyNotActiveAtBlock.selector, assetId, rotating, validFrom - 1
            )
        );
        layer.submit(early, rotating, earlySignature);

        // First and last block of the window are both accepted.
        _submitAs(rotating, rotatingPk, 1, validFrom, THRESHOLD);
        _submitAs(rotating, rotatingPk, 2, validTo, THRESHOLD);
        assertEq(layer.headOf(assetId).sequenceNumber, 2);

        // One block after the window closes.
        IWatchtowerFreshnessLayer.Attestation memory late = _attestation(3, validTo + 1, THRESHOLD);
        bytes memory lateSignature = _sign(rotatingPk, late);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWatchtowerFreshnessLayer.KeyNotActiveAtBlock.selector, assetId, rotating, validTo + 1
            )
        );
        layer.submit(late, rotating, lateSignature);
    }

    function test_retiredKeyStillVerifiesForItsHistoricalWindow() public {
        uint64 lastValidBlock = START_BLOCK + 5;

        vm.prank(steward);
        layer.rotateKey(assetId, rotating, START_BLOCK, type(uint64).max);

        // Retire the key gracefully by shortening its window to the last block it served.
        vm.roll(START_BLOCK + 30);
        vm.prank(steward);
        layer.rotateKey(assetId, rotating, START_BLOCK, lastValidBlock);

        // Work signed inside the old window is still accepted after retirement.
        _submitAs(rotating, rotatingPk, 1, lastValidBlock, THRESHOLD);
        assertEq(layer.headOf(assetId).key, rotating);

        // Work signed after retirement is not.
        IWatchtowerFreshnessLayer.Attestation memory after_ = _attestation(2, START_BLOCK + 6, THRESHOLD);
        bytes memory signature = _sign(rotatingPk, after_);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWatchtowerFreshnessLayer.KeyNotActiveAtBlock.selector, assetId, rotating, START_BLOCK + 6
            )
        );
        layer.submit(after_, rotating, signature);
    }

    function test_overlappingWindowsAllowHandover() public {
        (address outgoing, uint256 outgoingPk) = makeAddrAndKey("outgoing");
        (address incoming, uint256 incomingPk) = makeAddrAndKey("incoming");

        uint64 handoverStart = START_BLOCK + 10;
        uint64 handoverEnd = START_BLOCK + 20;

        vm.startPrank(steward);
        layer.rotateKey(assetId, outgoing, START_BLOCK, handoverEnd);
        layer.rotateKey(assetId, incoming, handoverStart, type(uint64).max);
        vm.stopPrank();

        vm.roll(START_BLOCK + 22);

        // Inside the overlap both keys are authoritative.
        assertTrue(layer.isKeyActiveAt(assetId, outgoing, handoverStart + 1));
        assertTrue(layer.isKeyActiveAt(assetId, incoming, handoverStart + 1));

        _submitAs(outgoing, outgoingPk, 1, handoverStart + 1, THRESHOLD);
        _submitAs(incoming, incomingPk, 2, handoverStart + 2, THRESHOLD);

        // After the overlap only the incoming key is.
        assertFalse(layer.isKeyActiveAt(assetId, outgoing, handoverEnd + 1));
        assertTrue(layer.isKeyActiveAt(assetId, incoming, handoverEnd + 1));

        _submitAs(incoming, incomingPk, 3, handoverEnd + 1, THRESHOLD);
        assertEq(layer.headOf(assetId).key, incoming);
    }

    function test_rotateRejectsInvertedWindow() public {
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidKeyWindow.selector, 100, 99));
        layer.rotateKey(assetId, rotating, 100, 99);
    }

    function test_rotateRejectsZeroKey() public {
        vm.prank(steward);
        vm.expectRevert(IWatchtowerFreshnessLayer.ZeroAddress.selector);
        layer.rotateKey(assetId, address(0), 0, 100);
    }

    function testFuzz_isKeyActiveAtMatchesWindow(uint64 validFrom, uint64 validTo, uint64 probe) public {
        validTo = uint64(bound(validTo, validFrom, type(uint64).max));

        vm.prank(steward);
        layer.rotateKey(assetId, rotating, validFrom, validTo);

        assertEq(layer.isKeyActiveAt(assetId, rotating, probe), probe >= validFrom && probe <= validTo);
    }

    // ------------------------------------------------------------------
    // Revocation
    // ------------------------------------------------------------------

    function test_revocationIsRetroactiveAndPermanent() public {
        vm.prank(steward);
        layer.rotateKey(assetId, rotating, 0, type(uint64).max);

        vm.roll(START_BLOCK + 5);

        vm.expectEmit(true, true, false, true, address(layer));
        emit IWatchtowerFreshnessLayer.KeyRevoked(assetId, rotating, START_BLOCK + 5);
        vm.prank(steward);
        layer.revokeKey(assetId, rotating);

        assertTrue(layer.keyWindowOf(assetId, rotating).revoked);
        // Retroactive: heights that were inside the window no longer verify.
        assertFalse(layer.isKeyActiveAt(assetId, rotating, START_BLOCK));

        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, THRESHOLD);
        bytes memory signature = _sign(rotatingPk, attestation);
        assertFalse(layer.verifyAttestation(attestation, rotating, signature));
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.KeyAlreadyRevoked.selector, assetId, rotating));
        layer.submit(attestation, rotating, signature);

        // Permanent: the key cannot be re-registered or revoked twice.
        vm.startPrank(steward);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.KeyAlreadyRevoked.selector, assetId, rotating));
        layer.rotateKey(assetId, rotating, 0, type(uint64).max);

        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.KeyAlreadyRevoked.selector, assetId, rotating));
        layer.revokeKey(assetId, rotating);
        vm.stopPrank();
    }

    function test_revokeRequiresRegisteredKey() public {
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.KeyNotRegistered.selector, assetId, rotating));
        layer.revokeKey(assetId, rotating);
    }

    // ------------------------------------------------------------------
    // Authorisation
    // ------------------------------------------------------------------

    function test_onlyStewardMayRotateOrRevoke() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotSteward.selector, assetId, stranger));
        layer.rotateKey(assetId, rotating, 0, 100);

        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotSteward.selector, assetId, stranger));
        layer.revokeKey(assetId, watchtower);

        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotSteward.selector, assetId, stranger));
        layer.setPolicy(assetId, 1, 10);
        vm.stopPrank();
    }

    function test_unknownAssetIsRejected() public {
        bytes32 unknown = keccak256("nope");
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.AssetNotRegistered.selector, unknown));
        layer.rotateKey(unknown, rotating, 0, 100);
    }

    function test_stewardshipTransferIsTwoStep() public {
        address newSteward = makeAddr("new-steward");

        vm.prank(steward);
        layer.transferStewardship(assetId, newSteward);

        // Not effective until accepted.
        assertEq(layer.policyOf(assetId).steward, steward);
        assertEq(layer.policyOf(assetId).pendingSteward, newSteward);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotPendingSteward.selector, assetId, stranger));
        layer.acceptStewardship(assetId);

        vm.prank(newSteward);
        layer.acceptStewardship(assetId);

        assertEq(layer.policyOf(assetId).steward, newSteward);
        assertEq(layer.policyOf(assetId).pendingSteward, address(0));

        // The old steward has lost authority; the new one has it.
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.NotSteward.selector, assetId, steward));
        layer.rotateKey(assetId, rotating, 0, 100);

        vm.prank(newSteward);
        layer.rotateKey(assetId, rotating, 0, 100);
        assertTrue(layer.keyWindowOf(assetId, rotating).registered);
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function test_assetIdIsNamespacedPerRegistrar() public {
        address otherRegistrar = makeAddr("other-registrar");

        vm.prank(otherRegistrar);
        bytes32 otherAssetId = layer.registerAsset(SALT, steward, FINALITY_DEPTH, MAX_THRESHOLD, 0);

        assertTrue(otherAssetId != assetId);
        assertEq(otherAssetId, layer.computeAssetId(otherRegistrar, SALT));
        assertEq(assetId, layer.computeAssetId(registrar, SALT));
    }

    function test_duplicateRegistrationIsRejected() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.AssetAlreadyRegistered.selector, assetId));
        layer.registerAsset(SALT, steward, FINALITY_DEPTH, MAX_THRESHOLD, 0);
    }

    function test_registrationRejectsUnreachableFinality() public {
        vm.startPrank(registrar);

        // A finality depth beyond the freshness bound would make FRESH_FINAL unreachable.
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidPolicy.selector, 11, 10));
        layer.registerAsset(keccak256("a"), steward, 11, 10, 0);

        // A zero freshness bound would reject every attestation.
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidPolicy.selector, 0, 0));
        layer.registerAsset(keccak256("b"), steward, 0, 0, 0);

        vm.expectRevert(IWatchtowerFreshnessLayer.ZeroAddress.selector);
        layer.registerAsset(keccak256("c"), address(0), 1, 10, 0);

        vm.stopPrank();
    }

    function test_setPolicyUpdatesClassificationInputs() public {
        vm.prank(steward);
        layer.setPolicy(assetId, 4, 8);

        IWatchtowerFreshnessLayer.AssetPolicy memory policy = layer.policyOf(assetId);
        assertEq(policy.finalityDepth, 4);
        assertEq(policy.maxFreshnessThreshold, 8);

        // A threshold above the new bound is now refused.
        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 9);
        bytes memory signature = _sign(watchtowerPk, attestation);
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.FreshnessThresholdOutOfRange.selector, 9, 8));
        layer.submit(attestation, watchtower, signature);
    }
}
