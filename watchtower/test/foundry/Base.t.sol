// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {WatchtowerFreshnessLayer} from "../../contracts/WatchtowerFreshnessLayer.sol";
import {IWatchtowerFreshnessLayer} from "../../contracts/interfaces/IWatchtowerFreshnessLayer.sol";

/// @notice Shared fixture: one registered asset with one open-window watchtower key.
abstract contract WatchtowerTestBase is Test {
    WatchtowerFreshnessLayer internal layer;

    bytes32 internal constant SALT = keccak256("ETH/USD");
    uint64 internal constant FINALITY_DEPTH = 32;
    uint64 internal constant MAX_THRESHOLD = 256;
    uint64 internal constant START_BLOCK = 1_000;

    address internal registrar;
    address internal steward;
    address internal relayer;
    address internal stranger;

    address internal watchtower;
    uint256 internal watchtowerPk;

    bytes32 internal assetId;

    function setUp() public virtual {
        registrar = makeAddr("registrar");
        steward = makeAddr("steward");
        relayer = makeAddr("relayer");
        stranger = makeAddr("stranger");
        (watchtower, watchtowerPk) = makeAddrAndKey("watchtower");

        vm.roll(START_BLOCK);
        layer = new WatchtowerFreshnessLayer();

        vm.prank(registrar);
        assetId = layer.registerAsset(SALT, steward, FINALITY_DEPTH, MAX_THRESHOLD, 0);

        vm.prank(steward);
        layer.rotateKey(assetId, watchtower, 0, type(uint64).max);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _attestation(uint64 sequenceNumber, uint64 signedAtBlock, uint64 freshnessThreshold)
        internal
        view
        returns (IWatchtowerFreshnessLayer.Attestation memory)
    {
        return IWatchtowerFreshnessLayer.Attestation({
            assetId: assetId,
            signedAtBlock: signedAtBlock,
            sequenceNumber: sequenceNumber,
            freshnessThreshold: freshnessThreshold
        });
    }

    function _sign(uint256 privateKey, IWatchtowerFreshnessLayer.Attestation memory attestation)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, layer.hashAttestation(attestation));
        return abi.encodePacked(r, s, v);
    }

    /// @notice Signs and submits an attestation signed at the current block.
    function _submitAt(uint64 sequenceNumber, uint64 signedAtBlock, uint64 freshnessThreshold)
        internal
        returns (IWatchtowerFreshnessLayer.Attestation memory attestation)
    {
        attestation = _attestation(sequenceNumber, signedAtBlock, freshnessThreshold);
        bytes memory signature = _sign(watchtowerPk, attestation);
        vm.prank(relayer);
        layer.submit(attestation, watchtower, signature);
    }
}
