import { expect } from "chai";
import { ethers } from "hardhat";
import { mine } from "@nomicfoundation/hardhat-network-helpers";

import {
  FINALITY_DEPTH,
  Freshness,
  Fixture,
  MAX_THRESHOLD,
  THRESHOLD,
  attestation,
  blockNumber,
  deployFixture,
  signAttestation,
  submit,
} from "./fixture";

const MAX_UINT64 = 2n ** 64n - 1n;

describe("ERC-8415: strict monotonic sequencing", () => {
  let fx: Fixture;

  beforeEach(async () => {
    fx = await deployFixture();
  });

  it("starts at one and advances by exactly one", async () => {
    expect(await fx.layer.nextSequence(fx.assetId)).to.equal(1n);

    for (let i = 1n; i <= 8n; i++) {
      await submit(fx, attestation(fx.assetId, i, await blockNumber()));
      expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(i);
      expect(await fx.layer.nextSequence(fx.assetId)).to.equal(i + 1n);
    }
  });

  it("rejects sequence zero as the first attestation", async () => {
    await expect(submit(fx, attestation(fx.assetId, 0n, await blockNumber())))
      .to.be.revertedWithCustomError(fx.layer, "SequenceNotContiguous")
      .withArgs(fx.assetId, 1n, 0n);
  });

  it("rejects a gap, and still accepts the number that fills it", async () => {
    await submit(fx, attestation(fx.assetId, 1n, await blockNumber()));

    await expect(submit(fx, attestation(fx.assetId, 3n, await blockNumber())))
      .to.be.revertedWithCustomError(fx.layer, "SequenceNotContiguous")
      .withArgs(fx.assetId, 2n, 3n);

    // The head was not disturbed by the rejected submission.
    expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(1n);

    await submit(fx, attestation(fx.assetId, 2n, await blockNumber()));
    expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(2n);
  });

  it("rejects a replay of the head, signature and all", async () => {
    const att = attestation(fx.assetId, 1n, await blockNumber());
    const signature = await signAttestation(fx.layer, fx.watchtower, att);

    await fx.layer.submit(att, fx.watchtower.address, signature);

    await expect(fx.layer.submit(att, fx.watchtower.address, signature))
      .to.be.revertedWithCustomError(fx.layer, "SequenceNotContiguous")
      .withArgs(fx.assetId, 2n, 1n);
  });

  it("rejects an older sequence number", async () => {
    await submit(fx, attestation(fx.assetId, 1n, await blockNumber()));
    await submit(fx, attestation(fx.assetId, 2n, await blockNumber()));

    await expect(submit(fx, attestation(fx.assetId, 1n, await blockNumber())))
      .to.be.revertedWithCustomError(fx.layer, "SequenceNotContiguous")
      .withArgs(fx.assetId, 3n, 1n);
  });

  it("rejects every number except the successor", async () => {
    await submit(fx, attestation(fx.assetId, 1n, await blockNumber()));

    for (const candidate of [0n, 1n, 3n, 4n, 100n, MAX_UINT64]) {
      await expect(submit(fx, attestation(fx.assetId, candidate, await blockNumber())))
        .to.be.revertedWithCustomError(fx.layer, "SequenceNotContiguous")
        .withArgs(fx.assetId, 2n, candidate);
    }

    await submit(fx, attestation(fx.assetId, 2n, await blockNumber()));
    expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(2n);
  });

  it("keeps sequences independent per asset", async () => {
    const secondSalt = ethers.id("BTC/USD");
    const secondAssetId = await fx.layer.computeAssetId(fx.registrar.address, secondSalt);
    await fx.layer
      .connect(fx.registrar)
      .registerAsset(secondSalt, fx.steward.address, FINALITY_DEPTH, MAX_THRESHOLD, 0n);
    await fx.layer.connect(fx.steward).rotateKey(secondAssetId, fx.watchtower.address, 0n, MAX_UINT64);

    await submit(fx, attestation(fx.assetId, 1n, await blockNumber()));
    await submit(fx, attestation(fx.assetId, 2n, await blockNumber()));

    expect(await fx.layer.nextSequence(secondAssetId)).to.equal(1n);
    await submit(fx, attestation(secondAssetId, 1n, await blockNumber()));

    expect((await fx.layer.headOf(secondAssetId)).sequenceNumber).to.equal(1n);
    expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(2n);
  });

  it("can continue an existing feed from a migrated cursor", async () => {
    const salt = ethers.id("migrated");
    const migrated = await fx.layer.computeAssetId(fx.registrar.address, salt);
    await fx.layer
      .connect(fx.registrar)
      .registerAsset(salt, fx.steward.address, FINALITY_DEPTH, MAX_THRESHOLD, 4_000n);
    await fx.layer.connect(fx.steward).rotateKey(migrated, fx.watchtower.address, 0n, MAX_UINT64);

    expect(await fx.layer.nextSequence(migrated)).to.equal(4_001n);
    // A non-zero cursor is not a head: the feed still has no data.
    expect((await fx.layer.freshnessOf(migrated))[0]).to.equal(BigInt(Freshness.UNKNOWN));

    await expect(submit(fx, attestation(migrated, 4_000n, await blockNumber())))
      .to.be.revertedWithCustomError(fx.layer, "SequenceNotContiguous")
      .withArgs(migrated, 4_001n, 4_000n);

    await submit(fx, attestation(migrated, 4_001n, await blockNumber()));
    expect((await fx.layer.headOf(migrated)).sequenceNumber).to.equal(4_001n);
  });

  describe("block ordering", () => {
    it("rejects an attestation signed before the head", async () => {
      await mine(10);
      const signedAtBlock = await blockNumber();
      await submit(fx, attestation(fx.assetId, 1n, signedAtBlock));

      await expect(submit(fx, attestation(fx.assetId, 2n, signedAtBlock - 1n)))
        .to.be.revertedWithCustomError(fx.layer, "AttestationOutOfOrder")
        .withArgs(signedAtBlock - 1n, signedAtBlock);

      // The same height as the head is fine: a block may carry several observations.
      await submit(fx, attestation(fx.assetId, 2n, signedAtBlock));
      expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(2n);
    });

    it("rejects an attestation signed for a future block", async () => {
      const future = (await blockNumber()) + 5n;
      const att = attestation(fx.assetId, 1n, future);
      const signature = await signAttestation(fx.layer, fx.watchtower, att);

      // `submit` mines one block, so the payload is still ahead of the chain when it lands.
      await expect(fx.layer.submit(att, fx.watchtower.address, signature)).to.be.revertedWithCustomError(
        fx.layer,
        "AttestationFromFuture",
      );
    });

    it("rejects block zero", async () => {
      await expect(submit(fx, attestation(fx.assetId, 1n, 0n))).to.be.revertedWithCustomError(
        fx.layer,
        "InvalidSignedAtBlock",
      );
    });
  });

  describe("freshness bounds at submission", () => {
    it("rejects an attestation that is already stale", async () => {
      const signedAtBlock = await blockNumber();
      const threshold = 10n;

      await mine(11);
      await expect(submit(fx, attestation(fx.assetId, 1n, signedAtBlock, threshold)))
        .to.be.revertedWithCustomError(fx.layer, "AttestationAlreadyStale")
        .withArgs(12n, threshold); // the submitting transaction mines one more block
    });

    it("accepts an attestation exactly at its threshold", async () => {
      const signedAtBlock = await blockNumber();
      const threshold = 10n;

      await mine(9); // the submission itself takes the age to exactly 10
      await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, threshold));

      expect((await fx.layer.headOf(fx.assetId)).signedAtBlock).to.equal(signedAtBlock);
    });

    it("rejects a zero threshold and one above the asset bound", async () => {
      await expect(submit(fx, attestation(fx.assetId, 1n, await blockNumber(), 0n)))
        .to.be.revertedWithCustomError(fx.layer, "FreshnessThresholdOutOfRange")
        .withArgs(0n, MAX_THRESHOLD);

      await expect(submit(fx, attestation(fx.assetId, 1n, await blockNumber(), MAX_THRESHOLD + 1n)))
        .to.be.revertedWithCustomError(fx.layer, "FreshnessThresholdOutOfRange")
        .withArgs(MAX_THRESHOLD + 1n, MAX_THRESHOLD);
    });
  });

  it("lets anyone relay a watchtower signature", async () => {
    const att = attestation(fx.assetId, 1n, await blockNumber(), THRESHOLD);
    const signature = await signAttestation(fx.layer, fx.watchtower, att);

    // Submitted by a stranger, credited to the watchtower.
    await fx.layer.connect(fx.stranger).submit(att, fx.watchtower.address, signature);

    const head = await fx.layer.headOf(fx.assetId);
    expect(head.key).to.equal(fx.watchtower.address);
    expect(head.sequenceNumber).to.equal(1n);
  });
});
