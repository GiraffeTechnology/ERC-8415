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
  submit,
} from "./fixture";

describe("ERC-8415: freshness classification", () => {
  let fx: Fixture;

  beforeEach(async () => {
    fx = await deployFixture();
  });

  /// Mines until the head is exactly `age` blocks old, then reads its classification.
  async function classificationAtAge(signedAtBlock: bigint, age: bigint) {
    const target = signedAtBlock + age;
    const current = await blockNumber();
    if (target > current) await mine(Number(target - current));
    expect(await blockNumber()).to.equal(target);

    const [status, reportedAge] = await fx.layer.freshnessOf(fx.assetId);
    expect(reportedAge).to.equal(age);
    return Number(status);
  }

  it("reports UNKNOWN for an unregistered asset", async () => {
    const [status, age] = await fx.layer.freshnessOf(ethers.id("never-registered"));
    expect(Number(status)).to.equal(Freshness.UNKNOWN);
    expect(age).to.equal(0n);
  });

  it("reports UNKNOWN for a registered asset with no head", async () => {
    const [status, age] = await fx.layer.freshnessOf(fx.assetId);
    expect(Number(status)).to.equal(Freshness.UNKNOWN);
    expect(age).to.equal(0n);
  });

  it("walks PENDING -> FINAL -> STALE as the head ages", async () => {
    const signedAtBlock = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));

    // Below the finality depth the head is fresh but reorg-exposed.
    expect(await classificationAtAge(signedAtBlock, 1n)).to.equal(Freshness.FRESH_PENDING);
    expect(await classificationAtAge(signedAtBlock, FINALITY_DEPTH - 1n)).to.equal(Freshness.FRESH_PENDING);

    // Exactly at the finality depth it becomes final.
    expect(await classificationAtAge(signedAtBlock, FINALITY_DEPTH)).to.equal(Freshness.FRESH_FINAL);

    // Exactly at its declared threshold it is still final.
    expect(await classificationAtAge(signedAtBlock, THRESHOLD)).to.equal(Freshness.FRESH_FINAL);

    // One block later it is stale, and stays stale.
    expect(await classificationAtAge(signedAtBlock, THRESHOLD + 1n)).to.equal(Freshness.STALE);
    expect(await classificationAtAge(signedAtBlock, THRESHOLD + 1_000n)).to.equal(Freshness.STALE);
  });

  it("uses the threshold declared by the attestation, not the asset bound", async () => {
    const signedAtBlock = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, 8n));
    expect((await fx.layer.headOf(fx.assetId)).freshnessThreshold).to.equal(8n);

    // Still fresh at its own threshold, and short of the 32-block finality depth.
    expect(await classificationAtAge(signedAtBlock, 8n)).to.equal(Freshness.FRESH_PENDING);
    // Stale one block later, far below the asset's 256-block bound.
    expect(await classificationAtAge(signedAtBlock, 9n)).to.equal(Freshness.STALE);
  });

  it("treats every fresh head as final when the finality depth is zero", async () => {
    await fx.layer.connect(fx.steward).setPolicy(fx.assetId, 0n, MAX_THRESHOLD);

    const signedAtBlock = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));

    expect(await classificationAtAge(signedAtBlock, 1n)).to.equal(Freshness.FRESH_FINAL);
    expect(await classificationAtAge(signedAtBlock, THRESHOLD)).to.equal(Freshness.FRESH_FINAL);
    expect(await classificationAtAge(signedAtBlock, THRESHOLD + 1n)).to.equal(Freshness.STALE);
  });

  it("refreshes a stale feed when a new attestation lands", async () => {
    const first = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, first, THRESHOLD));
    expect(await classificationAtAge(first, THRESHOLD + 1n)).to.equal(Freshness.STALE);

    const second = await blockNumber();
    await submit(fx, attestation(fx.assetId, 2n, second, THRESHOLD));

    const [status, age] = await fx.layer.freshnessOf(fx.assetId);
    expect(Number(status)).to.equal(Freshness.FRESH_PENDING);
    expect(age).to.equal(1n);
  });

  it("reclassifies the head when the policy changes", async () => {
    const signedAtBlock = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));

    expect(await classificationAtAge(signedAtBlock, 10n)).to.equal(Freshness.FRESH_PENDING);

    // Lowering the finality depth promotes the very same head to final.
    await fx.layer.connect(fx.steward).setPolicy(fx.assetId, 5n, MAX_THRESHOLD);
    const [status] = await fx.layer.freshnessOf(fx.assetId);
    expect(Number(status)).to.equal(Freshness.FRESH_FINAL);
  });

  it("collapses a head signed by a revoked key to STALE", async () => {
    const signedAtBlock = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));
    expect(await classificationAtAge(signedAtBlock, FINALITY_DEPTH)).to.equal(Freshness.FRESH_FINAL);

    await fx.layer.connect(fx.steward).revokeKey(fx.assetId, fx.watchtower.address);

    const [status, age] = await fx.layer.freshnessOf(fx.assetId);
    expect(Number(status)).to.equal(Freshness.STALE);
    // The real age is preserved for observability.
    expect(age).to.equal(FINALITY_DEPTH + 1n);

    await expect(fx.layer.requireFresh(fx.assetId, false))
      .to.be.revertedWithCustomError(fx.layer, "NotFresh")
      .withArgs(fx.assetId, Freshness.STALE);
  });

  describe("requireFresh", () => {
    it("rejects an empty feed", async () => {
      await expect(fx.layer.requireFresh(fx.assetId, false))
        .to.be.revertedWithCustomError(fx.layer, "NotFresh")
        .withArgs(fx.assetId, Freshness.UNKNOWN);
    });

    it("admits a pending head only when finality is not required", async () => {
      const signedAtBlock = await blockNumber();
      await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));

      const [status, age] = await fx.layer.requireFresh(fx.assetId, false);
      expect(Number(status)).to.equal(Freshness.FRESH_PENDING);
      expect(age).to.equal(1n);

      await expect(fx.layer.requireFresh(fx.assetId, true))
        .to.be.revertedWithCustomError(fx.layer, "NotFresh")
        .withArgs(fx.assetId, Freshness.FRESH_PENDING);
    });

    it("admits a final head either way", async () => {
      const signedAtBlock = await blockNumber();
      await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));
      await mine(Number(FINALITY_DEPTH));

      expect(Number((await fx.layer.requireFresh(fx.assetId, true))[0])).to.equal(Freshness.FRESH_FINAL);
      expect(Number((await fx.layer.requireFresh(fx.assetId, false))[0])).to.equal(Freshness.FRESH_FINAL);
    });

    it("rejects a stale head either way", async () => {
      const signedAtBlock = await blockNumber();
      await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, THRESHOLD));
      await mine(Number(THRESHOLD) + 1);

      for (const requireFinal of [false, true]) {
        await expect(fx.layer.requireFresh(fx.assetId, requireFinal))
          .to.be.revertedWithCustomError(fx.layer, "NotFresh")
          .withArgs(fx.assetId, Freshness.STALE);
      }
    });
  });

  it("matches the off-chain classification rule across the whole age range", async () => {
    const finalityDepth = 8n;
    const threshold = 24n;
    await fx.layer.connect(fx.steward).setPolicy(fx.assetId, finalityDepth, MAX_THRESHOLD);

    const signedAtBlock = await blockNumber();
    await submit(fx, attestation(fx.assetId, 1n, signedAtBlock, threshold));

    // The reference rule, written independently of the Solidity source.
    const expected = (age: bigint): Freshness => {
      if (age > threshold) return Freshness.STALE;
      if (age >= finalityDepth) return Freshness.FRESH_FINAL;
      return Freshness.FRESH_PENDING;
    };

    for (let age = 1n; age <= threshold + 3n; age++) {
      expect(await classificationAtAge(signedAtBlock, age), `age ${age}`).to.equal(expected(age));
    }
  });
});
