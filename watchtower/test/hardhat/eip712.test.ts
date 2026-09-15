import { expect } from "chai";
import { ethers } from "hardhat";
import { TypedDataEncoder } from "ethers";

import {
  ATTESTATION_TYPES,
  DOMAIN_NAME,
  DOMAIN_VERSION,
  Fixture,
  attestation,
  blockNumber,
  deployFixture,
  domainOf,
  signAttestation,
} from "./fixture";

const TYPE_STRING =
  "WatchtowerAttestation(bytes32 assetId,uint64 signedAtBlock,uint64 sequenceNumber,uint64 freshnessThreshold)";

describe("ERC-8415: EIP-712 typed data", () => {
  let fx: Fixture;

  beforeEach(async () => {
    fx = await deployFixture();
  });

  it("derives the type hash from the canonical type string", async () => {
    expect(await fx.layer.ATTESTATION_TYPEHASH()).to.equal(ethers.id(TYPE_STRING));
    // ethers derives the same encoder from the field list alone.
    expect(TypedDataEncoder.from(ATTESTATION_TYPES as never).encodeType("WatchtowerAttestation")).to.equal(
      TYPE_STRING,
    );
  });

  it("binds the domain separator to the chain and the deployment", async () => {
    const domain = await domainOf(fx.layer);
    expect(await fx.layer.DOMAIN_SEPARATOR()).to.equal(TypedDataEncoder.hashDomain(domain));

    // A second deployment on the same chain must produce a different separator.
    const other = await (await ethers.getContractFactory("WatchtowerFreshnessLayer")).deploy();
    await other.waitForDeployment();
    expect(await other.DOMAIN_SEPARATOR()).to.not.equal(await fx.layer.DOMAIN_SEPARATOR());
  });

  it("reports its domain through ERC-5267", async () => {
    const [fields, name, version, chainId, verifyingContract, salt, extensions] =
      await fx.layer.eip712Domain();

    expect(fields).to.equal("0x0f");
    expect(name).to.equal(DOMAIN_NAME);
    expect(version).to.equal(DOMAIN_VERSION);
    expect(chainId).to.equal((await ethers.provider.getNetwork()).chainId);
    expect(verifyingContract).to.equal(await fx.layer.getAddress());
    expect(salt).to.equal(ethers.ZeroHash);
    expect(extensions.length).to.equal(0);
  });

  it("computes the same digest as an independent off-chain encoder", async () => {
    const att = attestation(fx.assetId, 7n, 1234n, 99n);
    const expected = TypedDataEncoder.hash(await domainOf(fx.layer), ATTESTATION_TYPES as never, att);

    expect(await fx.layer.hashAttestation(att)).to.equal(expected);
  });

  it("recovers the watchtower from a wallet-produced signature", async () => {
    const att = attestation(fx.assetId, 1n, await blockNumber());
    const signature = await signAttestation(fx.layer, fx.watchtower, att);
    const domain = await domainOf(fx.layer);

    expect(ethers.verifyTypedData(domain, ATTESTATION_TYPES as never, att, signature)).to.equal(
      fx.watchtower.address,
    );
    expect(await fx.layer.verifyAttestation(att, fx.watchtower.address, signature)).to.equal(true);
  });

  it("rejects a signature made for a different deployment", async () => {
    const other = await (await ethers.getContractFactory("WatchtowerFreshnessLayer")).deploy();
    await other.waitForDeployment();

    const att = attestation(fx.assetId, 1n, await blockNumber());
    const foreign = await signAttestation(other, fx.watchtower, att);

    expect(await fx.layer.verifyAttestation(att, fx.watchtower.address, foreign)).to.equal(false);
    await expect(fx.layer.submit(att, fx.watchtower.address, foreign))
      .to.be.revertedWithCustomError(fx.layer, "InvalidSignature")
      .withArgs(fx.assetId, fx.watchtower.address);
  });

  it("rejects a signature over tampered fields", async () => {
    const att = attestation(fx.assetId, 1n, await blockNumber());
    const signature = await signAttestation(fx.layer, fx.watchtower, att);

    // Same signature, one field changed: the digest no longer matches.
    const tampered = { ...att, freshnessThreshold: att.freshnessThreshold + 1n };
    expect(await fx.layer.verifyAttestation(tampered, fx.watchtower.address, signature)).to.equal(false);

    await expect(fx.layer.submit(tampered, fx.watchtower.address, signature))
      .to.be.revertedWithCustomError(fx.layer, "InvalidSignature")
      .withArgs(fx.assetId, fx.watchtower.address);
  });

  it("rejects a malleable (high-s) signature", async () => {
    const att = attestation(fx.assetId, 1n, await blockNumber());
    const signature = await signAttestation(fx.layer, fx.watchtower, att);

    const split = ethers.Signature.from(signature);
    const n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
    const malleable = ethers.concat([
      split.r,
      ethers.zeroPadValue(ethers.toBeHex(n - BigInt(split.s)), 32),
      split.v === 27 ? "0x1c" : "0x1b",
    ]);

    expect(await fx.layer.verifyAttestation(att, fx.watchtower.address, malleable)).to.equal(false);
    await expect(fx.layer.submit(att, fx.watchtower.address, malleable))
      .to.be.revertedWithCustomError(fx.layer, "InvalidSignature")
      .withArgs(fx.assetId, fx.watchtower.address);

    // The canonical form is accepted.
    await expect(fx.layer.submit(att, fx.watchtower.address, signature)).to.emit(
      fx.layer,
      "AttestationAccepted",
    );
  });

  it("verifies a smart-contract watchtower through ERC-1271", async () => {
    const contractKey = await (
      await ethers.getContractFactory("ERC1271Watchtower")
    ).deploy(fx.watchtower.address);
    await contractKey.waitForDeployment();
    const keyAddress = await contractKey.getAddress();

    await fx.layer.connect(fx.steward).rotateKey(fx.assetId, keyAddress, 0n, 2n ** 64n - 1n);

    const att = attestation(fx.assetId, 1n, await blockNumber());
    const signature = await signAttestation(fx.layer, fx.watchtower, att);

    expect(await fx.layer.verifyAttestation(att, keyAddress, signature)).to.equal(true);
    await fx.layer.submit(att, keyAddress, signature);
    expect((await fx.layer.headOf(fx.assetId)).key).to.equal(keyAddress);

    // A signature from anyone else is refused by the signer contract.
    const next = attestation(fx.assetId, 2n, await blockNumber());
    const wrong = await signAttestation(fx.layer, fx.stranger, next);
    await expect(fx.layer.submit(next, keyAddress, wrong))
      .to.be.revertedWithCustomError(fx.layer, "InvalidSignature")
      .withArgs(fx.assetId, keyAddress);
  });

  it("emits the verified digest on acceptance", async () => {
    const signedAtBlock = await blockNumber();
    const att = attestation(fx.assetId, 1n, signedAtBlock);
    const signature = await signAttestation(fx.layer, fx.watchtower, att);
    const digest = await fx.layer.hashAttestation(att);

    await expect(fx.layer.connect(fx.relayer).submit(att, fx.watchtower.address, signature))
      .to.emit(fx.layer, "AttestationAccepted")
      .withArgs(fx.assetId, fx.watchtower.address, 1n, signedAtBlock, att.freshnessThreshold, digest);
  });

  it("announces ERC-165, ERC-5267 and the ERC-8415 interface", async () => {
    expect(await fx.layer.supportsInterface("0x01ffc9a7")).to.equal(true); // ERC-165
    expect(await fx.layer.supportsInterface("0x84b0196e")).to.equal(true); // ERC-5267
    expect(await fx.layer.supportsInterface("0xffffffff")).to.equal(false);
  });
});
