import { expect } from "chai";
import { ethers } from "hardhat";
import { mine } from "@nomicfoundation/hardhat-network-helpers";

import {
  FINALITY_DEPTH,
  Fixture,
  MAX_THRESHOLD,
  SALT,
  attestation,
  blockNumber,
  deployFixture,
  signAttestation,
  submit,
} from "./fixture";

const MAX_UINT64 = 2n ** 64n - 1n;

describe("ERC-8415: key rotation", () => {
  let fx: Fixture;

  beforeEach(async () => {
    fx = await deployFixture();
  });

  describe("validity windows", () => {
    it("treats validFrom and validTo as inclusive bounds", async () => {
      const base = await blockNumber();
      const validFrom = base + 10n;
      const validTo = base + 20n;

      await fx.layer.connect(fx.steward).rotateKey(fx.assetId, fx.other.address, validFrom, validTo);
      await mine(25);

      expect(await fx.layer.isKeyActiveAt(fx.assetId, fx.other.address, validFrom - 1n)).to.equal(false);
      expect(await fx.layer.isKeyActiveAt(fx.assetId, fx.other.address, validFrom)).to.equal(true);
      expect(await fx.layer.isKeyActiveAt(fx.assetId, fx.other.address, validTo)).to.equal(true);
      expect(await fx.layer.isKeyActiveAt(fx.assetId, fx.other.address, validTo + 1n)).to.equal(false);

      const early = attestation(fx.assetId, 1n, validFrom - 1n);
      await expect(submit(fx, early, fx.other))
        .to.be.revertedWithCustomError(fx.layer, "KeyNotActiveAtBlock")
        .withArgs(fx.assetId, fx.other.address, validFrom - 1n);

      // Both edges of the window are accepted.
      await submit(fx, attestation(fx.assetId, 1n, validFrom), fx.other);
      await submit(fx, attestation(fx.assetId, 2n, validTo), fx.other);
      expect((await fx.layer.headOf(fx.assetId)).sequenceNumber).to.equal(2n);

      const late = attestation(fx.assetId, 3n, validTo + 1n);
      await expect(submit(fx, late, fx.other))
        .to.be.revertedWithCustomError(fx.layer, "KeyNotActiveAtBlock")
        .withArgs(fx.assetId, fx.other.address, validTo + 1n);
    });

    it("keeps a retired key valid for the window it served", async () => {
      const base = await blockNumber();
      const lastValidBlock = base + 5n;

      await fx.layer.connect(fx.steward).rotateKey(fx.assetId, fx.other.address, base, MAX_UINT64);
      await mine(30);

      // Graceful retirement: shorten the window rather than revoking.
      await fx.layer.connect(fx.steward).rotateKey(fx.assetId, fx.other.address, base, lastValidBlock);

      // Work signed inside the old window is still accepted after retirement.
      await submit(fx, attestation(fx.assetId, 1n, lastValidBlock), fx.other);
      expect((await fx.layer.headOf(fx.assetId)).key).to.equal(fx.other.address);

      // Work signed after retirement is not.
      await expect(submit(fx, attestation(fx.assetId, 2n, lastValidBlock + 1n), fx.other))
        .to.be.revertedWithCustomError(fx.layer, "KeyNotActiveAtBlock")
        .withArgs(fx.assetId, fx.other.address, lastValidBlock + 1n);
    });

    it("allows overlapping windows so a hand-over loses no blocks", async () => {
      const [, , , , , , outgoing, incoming] = await ethers.getSigners();
      const base = await blockNumber();
      const handoverStart = base + 10n;
      const handoverEnd = base + 20n;

      await fx.layer.connect(fx.steward).rotateKey(fx.assetId, outgoing.address, base, handoverEnd);
      await fx.layer.connect(fx.steward).rotateKey(fx.assetId, incoming.address, handoverStart, MAX_UINT64);
      await mine(25);

      // Inside the overlap both keys are authoritative.
      expect(await fx.layer.isKeyActiveAt(fx.assetId, outgoing.address, handoverStart + 1n)).to.equal(true);
      expect(await fx.layer.isKeyActiveAt(fx.assetId, incoming.address, handoverStart + 1n)).to.equal(true);

      await submit(fx, attestation(fx.assetId, 1n, handoverStart + 1n), outgoing);
      await submit(fx, attestation(fx.assetId, 2n, handoverStart + 2n), incoming);

      // After it, only the incoming key is.
      expect(await fx.layer.isKeyActiveAt(fx.assetId, outgoing.address, handoverEnd + 1n)).to.equal(false);
      await submit(fx, attestation(fx.assetId, 3n, handoverEnd + 1n), incoming);
      expect((await fx.layer.headOf(fx.assetId)).key).to.equal(incoming.address);
    });

    it("rejects an inverted window and the zero key", async () => {
      await expect(fx.layer.connect(fx.steward).rotateKey(fx.assetId, fx.other.address, 100n, 99n))
        .to.be.revertedWithCustomError(fx.layer, "InvalidKeyWindow")
        .withArgs(100n, 99n);

      await expect(
        fx.layer.connect(fx.steward).rotateKey(fx.assetId, ethers.ZeroAddress, 0n, 100n),
      ).to.be.revertedWithCustomError(fx.layer, "ZeroAddress");
    });

    it("rejects an unregistered key outright", async () => {
      const att = attestation(fx.assetId, 1n, await blockNumber());
      await expect(submit(fx, att, fx.stranger))
        .to.be.revertedWithCustomError(fx.layer, "KeyNotRegistered")
        .withArgs(fx.assetId, fx.stranger.address);
    });
  });

  describe("revocation", () => {
    it("is retroactive and permanent", async () => {
      const signedAtBlock = await blockNumber();
      await submit(fx, attestation(fx.assetId, 1n, signedAtBlock));

      await expect(fx.layer.connect(fx.steward).revokeKey(fx.assetId, fx.watchtower.address)).to.emit(
        fx.layer,
        "KeyRevoked",
      );

      const window = await fx.layer.keyWindowOf(fx.assetId, fx.watchtower.address);
      expect(window.revoked).to.equal(true);

      // Retroactive: heights that were inside the window no longer verify.
      expect(await fx.layer.isKeyActiveAt(fx.assetId, fx.watchtower.address, signedAtBlock)).to.equal(false);

      const next = attestation(fx.assetId, 2n, await blockNumber());
      const signature = await signAttestation(fx.layer, fx.watchtower, next);
      expect(await fx.layer.verifyAttestation(next, fx.watchtower.address, signature)).to.equal(false);
      await expect(fx.layer.submit(next, fx.watchtower.address, signature))
        .to.be.revertedWithCustomError(fx.layer, "KeyAlreadyRevoked")
        .withArgs(fx.assetId, fx.watchtower.address);

      // Permanent: no re-registration, no double revocation.
      await expect(
        fx.layer.connect(fx.steward).rotateKey(fx.assetId, fx.watchtower.address, 0n, MAX_UINT64),
      ).to.be.revertedWithCustomError(fx.layer, "KeyAlreadyRevoked");
      await expect(
        fx.layer.connect(fx.steward).revokeKey(fx.assetId, fx.watchtower.address),
      ).to.be.revertedWithCustomError(fx.layer, "KeyAlreadyRevoked");
    });

    it("cannot revoke a key that was never registered", async () => {
      await expect(fx.layer.connect(fx.steward).revokeKey(fx.assetId, fx.stranger.address))
        .to.be.revertedWithCustomError(fx.layer, "KeyNotRegistered")
        .withArgs(fx.assetId, fx.stranger.address);
    });
  });

  describe("authorisation", () => {
    it("restricts rotation, revocation and policy to the steward", async () => {
      await expect(fx.layer.connect(fx.stranger).rotateKey(fx.assetId, fx.other.address, 0n, 100n))
        .to.be.revertedWithCustomError(fx.layer, "NotSteward")
        .withArgs(fx.assetId, fx.stranger.address);

      await expect(
        fx.layer.connect(fx.stranger).revokeKey(fx.assetId, fx.watchtower.address),
      ).to.be.revertedWithCustomError(fx.layer, "NotSteward");

      await expect(
        fx.layer.connect(fx.stranger).setPolicy(fx.assetId, 1n, 10n),
      ).to.be.revertedWithCustomError(fx.layer, "NotSteward");
    });

    it("transfers stewardship in two steps", async () => {
      await fx.layer.connect(fx.steward).transferStewardship(fx.assetId, fx.other.address);

      let policy = await fx.layer.policyOf(fx.assetId);
      expect(policy.steward).to.equal(fx.steward.address);
      expect(policy.pendingSteward).to.equal(fx.other.address);

      await expect(fx.layer.connect(fx.stranger).acceptStewardship(fx.assetId))
        .to.be.revertedWithCustomError(fx.layer, "NotPendingSteward")
        .withArgs(fx.assetId, fx.stranger.address);

      await expect(fx.layer.connect(fx.other).acceptStewardship(fx.assetId))
        .to.emit(fx.layer, "StewardshipTransferred")
        .withArgs(fx.assetId, fx.steward.address, fx.other.address);

      policy = await fx.layer.policyOf(fx.assetId);
      expect(policy.steward).to.equal(fx.other.address);
      expect(policy.pendingSteward).to.equal(ethers.ZeroAddress);

      // Authority has moved.
      await expect(
        fx.layer.connect(fx.steward).rotateKey(fx.assetId, fx.stranger.address, 0n, 100n),
      ).to.be.revertedWithCustomError(fx.layer, "NotSteward");
      await fx.layer.connect(fx.other).rotateKey(fx.assetId, fx.stranger.address, 0n, 100n);
      expect((await fx.layer.keyWindowOf(fx.assetId, fx.stranger.address)).registered).to.equal(true);
    });
  });

  describe("registration", () => {
    it("namespaces asset identifiers per registrar", async () => {
      const otherAssetId = await fx.layer.computeAssetId(fx.stranger.address, SALT);
      expect(otherAssetId).to.not.equal(fx.assetId);

      await fx.layer
        .connect(fx.stranger)
        .registerAsset(SALT, fx.steward.address, FINALITY_DEPTH, MAX_THRESHOLD, 0n);
      expect((await fx.layer.policyOf(otherAssetId)).registered).to.equal(true);
    });

    it("rejects duplicate registration", async () => {
      await expect(
        fx.layer
          .connect(fx.registrar)
          .registerAsset(SALT, fx.steward.address, FINALITY_DEPTH, MAX_THRESHOLD, 0n),
      )
        .to.be.revertedWithCustomError(fx.layer, "AssetAlreadyRegistered")
        .withArgs(fx.assetId);
    });

    it("rejects a policy where finality can never be reached", async () => {
      await expect(
        fx.layer.connect(fx.registrar).registerAsset(ethers.id("a"), fx.steward.address, 11n, 10n, 0n),
      )
        .to.be.revertedWithCustomError(fx.layer, "InvalidPolicy")
        .withArgs(11n, 10n);

      await expect(
        fx.layer.connect(fx.registrar).registerAsset(ethers.id("b"), fx.steward.address, 0n, 0n, 0n),
      ).to.be.revertedWithCustomError(fx.layer, "InvalidPolicy");

      await expect(
        fx.layer.connect(fx.registrar).registerAsset(ethers.id("c"), ethers.ZeroAddress, 1n, 10n, 0n),
      ).to.be.revertedWithCustomError(fx.layer, "ZeroAddress");
    });

    it("rejects key management on an unknown asset", async () => {
      const unknown = ethers.id("never-registered");
      await expect(fx.layer.connect(fx.steward).rotateKey(unknown, fx.other.address, 0n, 100n))
        .to.be.revertedWithCustomError(fx.layer, "AssetNotRegistered")
        .withArgs(unknown);
    });
  });
});
