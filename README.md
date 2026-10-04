# ERC-8415: Asynchronous Register Projection for NFTs

## ERC Working Draft

This repository contains the working draft, Solidity interfaces, reference implementation and local-EVM tests for **ERC-8415: Asynchronous Register Projection for NFTs**.

**Proposal status:** Draft<br>
**ERC Number:** 8415

This repository is a standards proposal repository. It is not a product repository and does not represent an adopted Ethereum standard.

- [Upstream proposal: ethereum/ERCs PR #2006](https://github.com/ethereum/ERCs/pull/2006)
- [Upstream proposal text pinned for this README](https://github.com/GiraffeTechnology/ERCs/blob/12e68aee54c6f94f6910d4db42f1d5677b506de1/ERCS/erc-8415.md)
- [Ethereum Magicians discussion](https://ethereum-magicians.org/t/erc-8415-asynchronous-register-projection-for-nfts/29634)

As of October 4, 2026, the upstream PR is open and unmerged, and the proposal text has status `Draft`.

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

It makes admitted registry history queryable under an explicit verification profile. That profile's authorities and trust assumptions remain part of the security boundary.

### 3. Historical Semantics Must Be Explicit

The proposal separates:

- historical resolution (`holderAsOf`);
- finality determination (`isFinalAsOf`);
- unresolved transitions (`openGapOf`, when the optional settlement interface is supported).

## Implemented Interfaces and Semantics

The [reference contract](reference/RegisterProjectionReference.sol) implements ERC-721 and both interfaces below on the same contract. Consumers discover each interface independently through ERC-165.

| Interface | ERC-165 identifier | Surface |
| --- | --- | --- |
| [`IRegisterProjection`](interfaces/IRegisterProjection.sol) | `0x6309e170` | `currentEntry`, `entryAt`, `entryAsOf`, `holderAsOf`, `isFinalAsOf`, `entryCount`, `registerId` |
| [`IProjectionSettlement`](interfaces/IProjectionSettlement.sol) | `0xf4a7d71b` | `settlement`, `openGapOf`, `settlementPeriod`, `verificationProfile`, `isSettlementAuthority`, `beginSettlement`, `finalizeSettlement`, `cancelSettlement` |

Projection entries are append-only, versions start at one, effective times strictly increase, and record commitments cannot repeat within a token. A new entry links the previous commitment and closes its interval at the new entry's `effectiveAt`. The standard does not require commitment or registry-reference uniqueness across different tokens.

### Historical resolution and finality

`entryAsOf(tokenId, t)` selects the entry covering `t`; `holderAsOf` returns its holder. Queries before the first entry revert. For an existing token, `isFinalAsOf` instead returns `false` before the first entry, and is `true` exactly when:

```text
firstEntry.effectiveAt <= t < latestEntry.effectiveAt
```

An instant at or after the latest effective time remains provisional. Admitting a later confirming entry with the same holder can make earlier instants final; merely closing or cancelling a gap cannot. All instants use Unix seconds.

This is finality of the projection's historical answer. It is not a block-depth test, an assertion that `ownerOf` matches the registered holder, or proof of legal title.

### Optional settlement

The proposal permits projection-only implementations. Settlement conformance additionally requires projection conformance and every settlement/proof requirement; advertising the settlement interface alone is not sufficient.

The reference implementation uses an immutable registrar as settlement authority, independently of ERC-721 ownership:

- `beginSettlement` opens a gap with an unused nonzero ID, a nonzero snapshot, an expected holder and a future deadline within the 30-day settlement period. Opening another gap supersedes the earlier one without changing the projection.
- Anyone can relay a valid proof to `finalizeSettlement`. Successful admission atomically appends an entry and closes the gap. Failed admission reverts all effects.
- Only the recorded initiator can cancel an open gap, strictly after its deadline. Cancellation leaves projection history unchanged.
- `openGapOf` returns zero when no gap is open; `settlement(unknownId)` reverts. A gap contests instants at or after its `openedAt`, while historical finality is determined independently.
- Ordinary ERC-721 transfers do not update the projection and remain possible while a gap is open.

Settlement here records proof-verified admission. It does not implement escrow, payments, refunds, recovery of transferred NFTs or application entitlement rules.

### Reference verification profile

The reference uses a fixed validator quorum, EIP-712 signatures and tagged Keccak Merkle membership proofs. Proofs bind the destination chain and contract, token, settlement, expected holder, snapshot, linked commitments, registry reference, version and effective time. Remote heights increase per token and consumed proofs cannot be reused. Initialization is an administrator-authorized `mint`, and subsequent admissions use settlement proofs.

This is a demonstration profile, not a production light client or a security audit. Its validator set and registrar are immutable, validator equivocation across tokens is not detected, and repeated supersession is not bounded. The profile caps future effective times at 30 days ahead. Read the [reference contract's trust assumptions](reference/RegisterProjectionReference.sol) and [security considerations](SECURITY.md) before adapting it.

### Consumer integration

Applications should re-read and validate the required holder, finality and gap conditions on-chain within the same transaction as the dependent action. Off-chain reads can inform a UI but do not guarantee the state when a later transaction executes; two transactions in the same block do not close that window.

The separate [ERC8415-Kit](https://github.com/GiraffeTechnology/ERC8415-Kit) contains integration components, SDKs and examples. Its [RecordDateClaim example](https://github.com/GiraffeTechnology/ERC8415-Kit/blob/main/contracts/examples/RecordDateClaim.sol) and [pinned local-EVM tests](https://github.com/GiraffeTechnology/ERC8415-Kit/blob/93035d2c1384dbb6b974a9680326fbff623c2d9b/tests/onchain/recordDateClaim.onchain.cjs) demonstrate same-transaction checks and one-time record-date payouts. Their payout and gap-rejection policies are application choices, not extra ERC requirements.

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
ERC-8415/
├── ERCS/erc-8415-asynchronous-register-projection.md   spec text, ethereum/ERCs form
├── EIPS/eip-8415.md                                    spec text, ethereum/EIPs form
├── interfaces/
│   ├── IRegisterProjection.sol                         projection queries
│   └── IProjectionSettlement.sol                       settlement lifecycle
├── reference/RegisterProjectionReference.sol           reference implementation
├── test/protocol.cjs                                   invariant tests
├── watchtower/                                         non-normative addon, separate toolchain
├── scripts/                                            lint, verification and build scripts
├── RATIONALE.md                                        why the design is shaped this way
├── COMPARISON.md                                       how it differs from adjacent standards
├── SECURITY.md                                         trust assumptions and attack surface
└── README.md
```

The local draft is kept in two forms: `ERCS/` follows the `ethereum/ERCs` conventions and `EIPS/`
follows `ethereum/EIPs`, including sibling-proposal links. Keep the two local forms aligned when
editing the draft. They are not automatically synchronized with upstream PR #2006. In particular,
the upstream baseline linked above includes a same-transaction consumer guidance section that is
not yet present in these local draft copies. Use the upstream PR to follow proposal revisions.

### The `watchtower/` directory

[`watchtower/`](watchtower/README.md) is a separate, non-normative freshness addon, not a required ERC-8415 interface. Its registry accepts EIP-712 signed
watchtower attestations, enforces strictly monotonic sequencing per asset feed, honours
block-scoped signing-key rotation, and classifies the recorded head as `STALE`, `FRESH_PENDING` or
`FRESH_FINAL` (or `UNKNOWN` when no head is available).

These are the current code's names. `FRESH_FINAL` means a fresh attestation has reached the
configured block-age threshold; it does not prove consensus finality or the ERC's historical
`isFinalAsOf` condition. The current API exposes the attestation type hash and EIP-712 domain,
not a raw type-string getter. `rotateKey` and `revokeKey` are separate calls; there is no atomic
rotate-and-revoke operation. These implementation boundaries must be considered independently
of the core projection and settlement interfaces.

It is self-contained and carries its own Foundry and Hardhat setup, so it is built and tested from
its own directory. The root `compile` reads `./interfaces` and the root `test` reads `./test`;
neither reaches into it. The repository-wide `lint`, `check-imports` and `secret-scan` checks do
cover it.

## Building and Verifying

The root CI uses Node 20 and the committed npm lockfile. Run from the repository root:

```sh
npm ci
npm run verify:all
```

`verify:all` runs the following sequence. The first interface compilation requires access to
Hardhat's Solidity compiler distribution unless the compiler is already cached.

| Step | What it checks |
| --- | --- |
| `lint` | SPDX identifier and pragma on Solidity; LF endings, no tabs or trailing whitespace, and trailing newline in checked source/configuration/Markdown files; ASCII-only Solidity |
| `compile` | Compiles `interfaces/` with solc 0.8.26 and flattens the artifacts |
| `verify:constants` | Recomputes each interface ID from the compiled ABI and compares it against the frozen value |
| `verify:secret-scan` | Checks files against the publication allowlist and scans for private-key headers and GitHub token patterns; this is not an exhaustive secret detector |
| `verify:imports` | No absolute imports, and no relative import escapes the package |
| `test` | Compiles the reference contract with Hardhat's bundled solc and runs its local-EVM invariant tests |
| `build` | Writes `dist/abi/`, the local `EIPS/eip-8415.md` copy, and `dist/manifest.json` containing interface IDs and SHA-256 hashes of the generated payload files |

CI runs the same sequence on every push to `main` and on every pull request.

`verify:constants` checks the frozen IDs listed above by XOR of each interface's function
selectors, excluding inherited `supportsInterface`.

To run only the reference-contract tests after `npm ci`:

```sh
npm test
```

This command uses `hardhat test --no-compile`; the test file compiles the standalone reference
itself, so it does not require a prior `npm run compile`. The suite runs locally without a wallet,
RPC endpoint, testnet funds or external signer. Passing it does not validate a production
deployment or the separate watchtower implementation.

To build and test the watchtower addon with its own locked dependencies and solc 0.8.28:

```sh
cd watchtower
npm ci
npm run compile
npm test
```

See [watchtower/README.md](watchtower/README.md) for its alternative Foundry workflow. The root
CI does not run either watchtower test suite.

## Status

Feedback is welcome regarding:

- historical query semantics;
- finality definitions;
- projection gap handling;
- verification profiles;
- interoperability with existing Ethereum standards.

Discuss the draft in the [existing Ethereum Magicians thread](https://ethereum-magicians.org/t/erc-8415-asynchronous-register-projection-for-nfts/29634), or report reproducible implementation issues in this repository. Include the commit, command and expected versus observed behavior.

## License

[CC0-1.0](LICENSE).
