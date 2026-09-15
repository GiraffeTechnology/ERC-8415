import { ethers } from "hardhat";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type { BaseContract, Signer, TypedDataDomain } from "ethers";

/// Freshness classification, mirroring `IWatchtowerFreshnessLayer.Freshness`.
export enum Freshness {
  UNKNOWN = 0,
  STALE = 1,
  FRESH_PENDING = 2,
  FRESH_FINAL = 3,
}

export interface Attestation {
  assetId: string;
  signedAtBlock: bigint;
  sequenceNumber: bigint;
  freshnessThreshold: bigint;
}

/// The EIP-712 type of the ERC-8415 payload, written out independently of the Solidity source so
/// the tests fail if either side drifts.
export const ATTESTATION_TYPES = {
  WatchtowerAttestation: [
    { name: "assetId", type: "bytes32" },
    { name: "signedAtBlock", type: "uint64" },
    { name: "sequenceNumber", type: "uint64" },
    { name: "freshnessThreshold", type: "uint64" },
  ],
} as const;

export const DOMAIN_NAME = "ERC-8415 Watchtower Freshness Layer";
export const DOMAIN_VERSION = "1";

export const FINALITY_DEPTH = 32n;
export const MAX_THRESHOLD = 256n;
export const THRESHOLD = 64n;
export const SALT = ethers.id("ETH/USD");

export async function domainOf(layer: BaseContract): Promise<TypedDataDomain> {
  return {
    name: DOMAIN_NAME,
    version: DOMAIN_VERSION,
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: await layer.getAddress(),
  };
}

export async function signAttestation(
  layer: BaseContract,
  signer: Signer,
  attestation: Attestation,
): Promise<string> {
  return signer.signTypedData(await domainOf(layer), ATTESTATION_TYPES as never, attestation);
}

export function attestation(
  assetId: string,
  sequenceNumber: bigint,
  signedAtBlock: bigint,
  freshnessThreshold: bigint = THRESHOLD,
): Attestation {
  return { assetId, signedAtBlock, sequenceNumber, freshnessThreshold };
}

export async function blockNumber(): Promise<bigint> {
  return BigInt(await ethers.provider.getBlockNumber());
}

export interface Fixture {
  layer: any;
  assetId: string;
  registrar: HardhatEthersSigner;
  steward: HardhatEthersSigner;
  relayer: HardhatEthersSigner;
  stranger: HardhatEthersSigner;
  watchtower: HardhatEthersSigner;
  other: HardhatEthersSigner;
}

/// Deploys the layer with one registered asset and one open-window watchtower key.
export async function deployFixture(): Promise<Fixture> {
  const [registrar, steward, relayer, stranger, watchtower, other] = await ethers.getSigners();

  const factory = await ethers.getContractFactory("WatchtowerFreshnessLayer");
  const layer = await factory.deploy();
  await layer.waitForDeployment();

  const assetId = await layer.computeAssetId(registrar.address, SALT);
  await layer
    .connect(registrar)
    .registerAsset(SALT, steward.address, FINALITY_DEPTH, MAX_THRESHOLD, 0n);
  await layer.connect(steward).rotateKey(assetId, watchtower.address, 0n, 2n ** 64n - 1n);

  return { layer, assetId, registrar, steward, relayer, stranger, watchtower, other };
}

/// Signs `att` with `signer` and submits it through `relayer`, proving that submission is
/// permissionless: the signer never needs an on-chain balance.
export async function submit(
  fixture: Fixture,
  att: Attestation,
  signer: Signer = fixture.watchtower,
  key?: string,
): Promise<string> {
  const signature = await signAttestation(fixture.layer, signer, att);
  const keyAddress = key ?? (await signer.getAddress());
  await fixture.layer.connect(fixture.relayer).submit(att, keyAddress, signature);
  return signature;
}
