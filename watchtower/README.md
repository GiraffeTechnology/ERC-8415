# Watchtower Freshness Layer

An EVM implementation of a watchtower freshness layer: a registry that accepts EIP-712 signed
watchtower attestations, enforces strictly monotonic sequencing per asset feed, honours
block-scoped signing-key rotation, and classifies the recorded head as `STALE`, `FRESH_PENDING`
or `FRESH_FINAL`.

## Placement in this repository

This directory is self-contained and deliberately separate from the register projection draft:

- it has its own `foundry.toml`, `hardhat.config.ts` and `package.json`;
- it is not compiled by the root `npm run compile`, whose sources are `./interfaces`;
- it is not run by the root `npm test`, whose tests are `./test`;
- the root `lint`, `check-imports` and `secret-scan` checks do cover these files.

The register projection interfaces (`IRegisterProjection`, `IProjectionSettlement`) and their
frozen interface IDs are untouched by anything here.

## Layout

| Path | Contents |
|---|---|
| `contracts/interfaces/IWatchtowerFreshnessLayer.sol` | Types, events, errors, and the full external interface |
| `contracts/WatchtowerFreshnessLayer.sol` | Registry: EIP-712 verification, key rotation, sequencing, classification |
| `contracts/libraries/WatchtowerAttestationLib.sol` | EIP-712 type string, type hash, and `hashStruct` |
| `contracts/libraries/FreshnessLib.sol` | The classification rule, isolated and reusable |
| `contracts/libraries/SignatureVerifier.sol` | Malleability-safe ECDSA with an ERC-1271 fallback |
| `contracts/mocks/ERC1271Watchtower.sol` | Contract-signer watchtower, used by both test suites |
| `test/foundry/` | Foundry suite (Solidity, incl. fuzz tests) |
| `test/hardhat/` | Hardhat suite (TypeScript, signing through `eth_signTypedData_v4`) |

## Attestation payload

```solidity
struct Attestation {
    bytes32 assetId;            // feed identifier, from `computeAssetId`
    uint64  signedAtBlock;      // height the watchtower observed and signed at
    uint64  sequenceNumber;     // strictly monotonic: MUST equal lastSequence + 1
    uint64  freshnessThreshold; // maximum age, in blocks, for which this stays fresh
}
```

Signed as EIP-712 typed data under the domain
`("ERC-8415 Watchtower Freshness Layer", "1", chainId, verifyingContract)`, with the type string

```
WatchtowerAttestation(bytes32 assetId,uint64 signedAtBlock,uint64 sequenceNumber,uint64 freshnessThreshold)
```

The domain binds every signature to one chain and one deployment, so an attestation cannot be
replayed onto another instance. The contract also reports its domain through ERC-5267
(`eip712Domain()`), and advertises ERC-165, ERC-5267 and its own interface id.

## Rules enforced on `submit`

Submission is permissionless: anyone may relay a watchtower's signature, so a watchtower key never
needs an on-chain balance. Every accepted attestation satisfies, in order:

1. **Registered asset**, and `0 < freshnessThreshold <= maxFreshnessThreshold`.
2. **Not from the future**, `signedAtBlock != 0`, and **not already stale**:
   `block.number - signedAtBlock <= freshnessThreshold`. A head is never born stale.
3. **Strict monotonic sequence**: `sequenceNumber == head.sequenceNumber + 1`, exactly. Gaps,
   repeats and reorderings are rejected, which also makes signature replay impossible without a
   separate nonce.
4. **Non-regressing height**: `signedAtBlock >= head.signedAtBlock`. Several observations may share
   a block, but a feed never walks backwards.
5. **Key authority at the signed height**: the key's window must contain `signedAtBlock`, not the
   height of submission. In-flight work survives a hand-over.
6. **Valid signature** over the EIP-712 digest: ECDSA with EIP-2 low-`s` enforcement, or ERC-1271
   for contract keys.

`previewSubmit` is a `view` dry run that reverts identically, and `verifyAttestation` checks only
authority and signature.

## Key rotation

A key is registered over an inclusive block range, `rotateKey(assetId, key, validFromBlock,
validToBlock)`. Windows of different keys may overlap, which is what makes a lossless hand-over
possible: during the overlap either key is authoritative.

There are two ways to end a key's authority, and the difference matters:

| | `rotateKey` with a shortened `validToBlock` | `revokeKey` |
|---|---|---|
| Intent | graceful retirement | compromise |
| Past window | signatures inside it still verify | rejected retroactively, for every height |
| Re-registration | allowed | permanently refused |
| Effect on the head | none | classification collapses to `STALE` |

## Freshness classification

With `age = block.number - head.signedAtBlock`:

| Condition | Result |
|---|---|
| no head recorded, or asset unregistered | `UNKNOWN` |
| head's key was revoked | `STALE` |
| `age > head.freshnessThreshold` | `STALE` |
| `age >= finalityDepth` | `FRESH_FINAL` |
| otherwise | `FRESH_PENDING` |

`FRESH_PENDING` is the reorg-exposed window: the attestation is recent enough to be useful, but
its signing height is not yet buried under `finalityDepth` blocks. A `finalityDepth` of zero makes
every fresh head final, which suits chains with single-slot finality. Registration rejects
`finalityDepth > maxFreshnessThreshold`, so `FRESH_FINAL` is always reachable.

Consumers can read `freshnessOf(assetId)`, or guard with `requireFresh(assetId, requireFinal)`,
which reverts with `NotFresh` unless the head qualifies.

## Roles

`registerAsset(salt, steward, finalityDepth, maxFreshnessThreshold, initialSequence)` derives the
identifier as `keccak256(namespace, msg.sender, salt)`, so no caller can register an identifier
belonging to another registrar and no well-known name can be squatted. The `steward` manages keys
and policy for that asset, and stewardship transfers in two steps. `initialSequence` lets an
existing off-chain feed migrate its cursor without restarting at one.

## Build and test

Run these from this directory, not from the repository root.

Foundry:

```sh
forge install foundry-rs/forge-std   # first checkout only
forge build
forge test
```

Hardhat:

```sh
npm install
npx hardhat compile
npx hardhat test
```

Compiler settings are pinned identically in both configs (0.8.28, paris, optimizer 200), so the
two toolchains emit the same runtime bytecode apart from the trailing metadata hash.

Both suites cover key rotation windows, strict monotonic sequencing and freshness classification;
the Foundry suite adds fuzzing, and the Hardhat suite additionally checks that the on-chain digest
matches an independently computed off-chain one and that wallet-produced (`eth_signTypedData_v4`)
signatures verify.
