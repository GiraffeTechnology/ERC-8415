# Asynchronous Register Projection for NFTs

## ERC Working Draft

This repository contains a public Ethereum ERC working draft for **Asynchronous Register Projection for NFTs**.

**Status:** Discussion Draft<br>
**ERC Number:** 8415

This repository is a standards proposal repository. It is not a product repository and does not represent an adopted Ethereum standard.

## Overview

Tokenized assets may depend on external registries, including ownership records, custody records, certification systems, and institutional databases.

External registries and blockchain networks do not necessarily update at the same time.

An ERC-721 token represents a tradeable on-chain position. However, `ownerOf(tokenId)` does not answer:

- which holder an external registry recognized at a particular record instant;
- whether that historical answer is final;
- whether an unresolved registry transition exists.

This proposal defines a standard interface for representing externally maintained registry states and their temporal evolution alongside ERC-721 compatible assets.

## Design Principles

### 1. Separate Token State and Registry State

The proposal keeps two states distinct:

```
Tradeable Token Position
          ≠
Registry-confirmed Historical State
```

The token remains transferable while registry synchronization occurs.

### 2. Preserve External Registry Boundaries

This proposal does not move external registries on-chain and does not replace legal or institutional sources of truth.

It provides a verifiable interoperability layer between external registries and blockchain assets.

### 3. Historical Semantics Must Be Explicit

The proposal separates:

- historical resolution (`holderAsOf`);
- finality determination (`isFinalAsOf`);
- unresolved transitions (`openGapOf`).

## Relationship with Existing Standards

| Standard | Primary Scope |
| --- | --- |
| ERC-721 | NFT representation and current on-chain ownership |
| ERC-1400 | Security token transfer and compliance controls |
| ERC-3643 | Permissioned token compliance |
| This Proposal | External registry temporal projection |

This proposal is complementary to existing token standards.

## Scope and Non-Goals

This proposal does not:

- determine legal ownership;
- replace government or institutional registries;
- establish jurisdiction-specific rights;
- make blockchain the legal source of truth;
- define application-specific entitlement rules.

A proof establishes inclusion in an accepted remote state. It does not independently prove the factual correctness of the underlying registry.

## Repository Structure

```
ERC8415/
├── ERCS/erc-8415-asynchronous-register-projection.md   spec text, ethereum/ERCs form
├── EIPS/eip-8415.md                                    spec text, ethereum/EIPs form
├── interfaces/
│   ├── IRegisterProjection.sol                         projection queries
│   └── IProjectionSettlement.sol                       settlement lifecycle
├── reference/RegisterProjectionReference.sol           reference implementation
├── test/protocol.cjs                                   invariant tests
├── watchtower/                                         freshness layer, separate toolchain
├── scripts/                                            lint, verification and build scripts
├── RATIONALE.md                                        why the design is shaped this way
├── COMPARISON.md                                       how it differs from adjacent standards
├── SECURITY.md                                         trust assumptions and attack surface
└── README.md
```

The spec text is kept in two forms because the upstream repositories differ: `ERCS/` follows the
`ethereum/ERCs` conventions and `EIPS/` follows `ethereum/EIPs`, including how each links sibling
proposals. Both carry the same content and must be updated together.

### The `watchtower/` directory

`watchtower/` holds an implementation of a freshness layer: a registry that accepts EIP-712 signed
watchtower attestations, enforces strictly monotonic sequencing per asset feed, honours
block-scoped signing-key rotation, and classifies the recorded head as `STALE`, `FRESH_PENDING` or
`FRESH_FINAL`. See `watchtower/README.md`.

It is self-contained and carries its own Foundry and Hardhat setup, so it is built and tested from
its own directory. The root `compile` reads `./interfaces` and the root `test` reads `./test`;
neither reaches into it. The repository-wide `lint`, `check-imports` and `secret-scan` checks do
cover it.

## Building and Verifying

Requires Node 20.

```sh
npm ci
npm run verify:all
```

`verify:all` runs, in order:

| Step | What it checks |
| --- | --- |
| `lint` | SPDX identifier and pragma on every Solidity file; LF endings, no tabs, no trailing whitespace, trailing newline everywhere; ASCII-only Solidity |
| `compile` | Compiles `interfaces/` with solc 0.8.26 and flattens the artifacts |
| `verify:constants` | Recomputes each interface ID from the compiled ABI and compares it against the frozen value |
| `verify:secret-scan` | Every tracked file is on the publication allowlist, and no file carries a private key or token |
| `verify:imports` | No absolute imports, and no relative import escapes the package |
| `test` | Invariant tests against the reference implementation |
| `build` | Writes `dist/` with the ABIs, interface IDs, spec text, and a manifest carrying a sha256 per file |

CI runs the same sequence on every push to `main` and on every pull request.

### Frozen interface IDs

`verify:constants` fails if either value moves, so a published identifier cannot change unnoticed:

| Interface | ERC-165 identifier |
| --- | --- |
| `IRegisterProjection` | `0x6309e170` |
| `IProjectionSettlement` | `0xf4a7d71b` |

Each is the XOR of the selectors the interface adds, excluding `supportsInterface`.

Tests for the watchtower layer are run separately, from `watchtower/`.

## Status

This repository contains an initial technical discussion draft.

This proposal uses ERC number 8415.

Feedback is welcome regarding:

- historical query semantics;
- finality definitions;
- projection gap handling;
- verification profiles;
- interoperability with existing Ethereum standards.

Discussion: [Ethereum Magicians](https://ethereum-magicians.org/t/working-draft-asynchronous-register-projection-for-nfts/29634).

## License

[CC0-1.0](LICENSE).
