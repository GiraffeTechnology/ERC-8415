// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {WatchtowerTestBase} from "./Base.t.sol";

import {WatchtowerFreshnessLayer} from "../../contracts/WatchtowerFreshnessLayer.sol";
import {ERC1271Watchtower} from "../../contracts/mocks/ERC1271Watchtower.sol";
import {IERC165} from "../../contracts/interfaces/IERC165.sol";
import {IWatchtowerFreshnessLayer} from "../../contracts/interfaces/IWatchtowerFreshnessLayer.sol";
import {SignatureVerifier} from "../../contracts/libraries/SignatureVerifier.sol";
import {WatchtowerAttestationLib} from "../../contracts/libraries/WatchtowerAttestationLib.sol";

/// @notice EIP-712 encoding, domain binding, and signature verification.
contract Eip712Test is WatchtowerTestBase {
    string internal constant EXPECTED_TYPE =
        "WatchtowerAttestation(bytes32 assetId,uint64 signedAtBlock,uint64 sequenceNumber,uint64 freshnessThreshold)";

    function test_typeHashMatchesLiteralTypeString() public view {
        assertEq(layer.ATTESTATION_TYPEHASH(), keccak256(bytes(EXPECTED_TYPE)));
        assertEq(WatchtowerAttestationLib.ATTESTATION_TYPEHASH, keccak256(bytes(EXPECTED_TYPE)));
    }

    function test_domainSeparatorIsBoundToChainAndContract() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ERC-8415 Watchtower Freshness Layer")),
                keccak256(bytes("1")),
                block.chainid,
                address(layer)
            )
        );
        assertEq(layer.DOMAIN_SEPARATOR(), expected);
    }

    function test_eip712DomainMatchesErc5267() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = layer.eip712Domain();

        assertEq(fields, hex"0f");
        assertEq(name, "ERC-8415 Watchtower Freshness Layer");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(layer));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function testFuzz_digestFollowsEip712(
        bytes32 fuzzAssetId,
        uint64 signedAtBlock,
        uint64 sequenceNumber,
        uint64 freshnessThreshold
    ) public view {
        IWatchtowerFreshnessLayer.Attestation memory attestation =
            IWatchtowerFreshnessLayer.Attestation({
                assetId: fuzzAssetId,
                signedAtBlock: signedAtBlock,
                sequenceNumber: sequenceNumber,
                freshnessThreshold: freshnessThreshold
            });

        bytes32 structHash = keccak256(
            abi.encode(keccak256(bytes(EXPECTED_TYPE)), fuzzAssetId, signedAtBlock, sequenceNumber, freshnessThreshold)
        );
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", layer.DOMAIN_SEPARATOR(), structHash));

        assertEq(layer.hashAttestation(attestation), expected);
    }

    function test_signatureFromAnotherDeploymentIsRejected() public {
        // Same payload, different verifying contract: the domain separator must break replay.
        WatchtowerFreshnessLayer other = new WatchtowerFreshnessLayer();
        assertTrue(layer.DOMAIN_SEPARATOR() != other.DOMAIN_SEPARATOR());

        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(watchtowerPk, other.hashAttestation(attestation));
        bytes memory foreignSignature = abi.encodePacked(r, s, v);

        assertFalse(layer.verifyAttestation(attestation, watchtower, foreignSignature));

        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidSignature.selector, assetId, watchtower)
        );
        layer.submit(attestation, watchtower, foreignSignature);
    }

    function test_signatureFromUnregisteredKeyIsRejected() public {
        (address impostor, uint256 impostorPk) = makeAddrAndKey("impostor");

        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        bytes memory signature = _sign(impostorPk, attestation);

        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.KeyNotRegistered.selector, assetId, impostor));
        layer.submit(attestation, impostor, signature);
    }

    function test_signatureOfOneKeyPresentedAsAnotherIsRejected() public {
        (address second, uint256 secondPk) = makeAddrAndKey("second");
        vm.prank(steward);
        layer.rotateKey(assetId, second, 0, type(uint64).max);

        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        bytes memory signature = _sign(secondPk, attestation);

        // Signed by `second`, but submitted claiming `watchtower`.
        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidSignature.selector, assetId, watchtower)
        );
        layer.submit(attestation, watchtower, signature);

        // Presented honestly it is accepted.
        layer.submit(attestation, second, signature);
        assertEq(layer.headOf(assetId).key, second);
    }

    function test_malleableSignatureIsRejected() public {
        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(watchtowerPk, layer.hashAttestation(attestation));

        // Flip (v, s) into the other valid-looking half of the curve.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, flippedS, flippedV);

        assertFalse(layer.verifyAttestation(attestation, watchtower, malleable));

        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidSignature.selector, assetId, watchtower)
        );
        layer.submit(attestation, watchtower, malleable);

        // The canonical signature still works.
        layer.submit(attestation, watchtower, abi.encodePacked(r, s, v));
        assertEq(layer.headOf(assetId).sequenceNumber, 1);
    }

    function test_wrongLengthSignatureIsRejected() public {
        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        bytes memory truncated = hex"deadbeef";

        assertFalse(layer.verifyAttestation(attestation, watchtower, truncated));

        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidSignature.selector, assetId, watchtower)
        );
        layer.submit(attestation, watchtower, truncated);
    }

    function test_contractKeyVerifiesThroughErc1271() public {
        (address owner, uint256 ownerPk) = makeAddrAndKey("contract-key-owner");
        ERC1271Watchtower contractKey = new ERC1271Watchtower(owner);

        vm.prank(steward);
        layer.rotateKey(assetId, address(contractKey), 0, type(uint64).max);

        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        bytes memory signature = _sign(ownerPk, attestation);

        assertTrue(layer.verifyAttestation(attestation, address(contractKey), signature));

        layer.submit(attestation, address(contractKey), signature);
        assertEq(layer.headOf(assetId).key, address(contractKey));

        // A signature from anyone but the contract's owner is refused by the ERC-1271 path.
        (, uint256 otherPk) = makeAddrAndKey("not-the-owner");
        IWatchtowerFreshnessLayer.Attestation memory next = _attestation(2, START_BLOCK, 64);
        bytes memory badSignature = _sign(otherPk, next);

        vm.expectRevert(
            abi.encodeWithSelector(IWatchtowerFreshnessLayer.InvalidSignature.selector, assetId, address(contractKey))
        );
        layer.submit(next, address(contractKey), badSignature);
    }

    function test_previewSubmitMatchesSubmit() public {
        IWatchtowerFreshnessLayer.Attestation memory attestation = _attestation(1, START_BLOCK, 64);
        bytes memory signature = _sign(watchtowerPk, attestation);

        bytes32 previewed = layer.previewSubmit(attestation, watchtower, signature);
        bytes32 submitted = layer.submit(attestation, watchtower, signature);

        assertEq(previewed, submitted);
        assertEq(previewed, layer.hashAttestation(attestation));

        // Replaying the same payload now fails the sequence check in the dry run too.
        vm.expectRevert(abi.encodeWithSelector(IWatchtowerFreshnessLayer.SequenceNotContiguous.selector, assetId, 2, 1));
        layer.previewSubmit(attestation, watchtower, signature);
    }

    function test_supportsInterface() public view {
        assertTrue(layer.supportsInterface(type(IWatchtowerFreshnessLayer).interfaceId));
        assertTrue(layer.supportsInterface(type(IERC165).interfaceId));
        assertTrue(layer.supportsInterface(0x84b0196e)); // ERC-5267
        assertFalse(layer.supportsInterface(0xffffffff));
    }

    function test_erc1271MagicValueConstant() public pure {
        assertEq(SignatureVerifier.ERC1271_MAGIC_VALUE, bytes4(keccak256("isValidSignature(bytes32,bytes)")));
    }
}
