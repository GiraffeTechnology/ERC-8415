# Asynchronous Register Projection for NFTs

## ERC Working Draft

This repository contains a public Ethereum ERC working draft for **Asynchronous Register Projection for NFTs**.

**Status:** Discussion Draft  
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
├── EIPS/
├── interfaces/
├── reference/
├── test/
├── RATIONALE.md
├── COMPARISON.md
├── SECURITY.md
└── README.md
```

## Status

This repository contains an initial technical discussion draft.

This proposal uses ERC number 8415.

Feedback is welcome regarding:

- historical query semantics;
- finality definitions;
- projection gap handling;
- verification profiles;
- interoperability with existing Ethereum standards.
