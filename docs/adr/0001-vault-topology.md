# ADR-0001: Vault topology — singleton versus per-vault clones

**Status:** Accepted — implemented 22 August 2026
**Date:** 21 August 2026
**Deciders:** Protocol lead; anyone signing off on custody changes before audit

## Context

`AgentVault` is a singleton. A vault is a `(trader, listing)` pair keyed by
`keccak256(trader, listingId)`, and one contract custodies every trader's quote tokens at
once. This was a deliberate translation from the Solana implementation, where each vault is
its own PDA: deploying a contract per trader looked like pointless gas on an EVM chain, and
the security properties are identical either way. The accounting is not identical, which is
why per-vault `idle` bookkeeping is load-bearing and the contract's own ERC-20 balance must
never be read as any single vault's balance. There is a test for exactly that.

That reasoning holds for venues which settle atomically. Our adapter is called inside the
same transaction, so it can attribute a fill to a `vaultId` and the vault can assert
post-conditions before returning.

It does not survive contact with an order book.

Polymarket's CTF Exchange V2 — live at `0xE111180000d2663C0091e4f400237545B87B996B`,
audited March 2026 — pulls a maker's collateral **from `order.maker`** and delivers the
acquired outcome tokens **to `order.maker`**. There is no alternate-recipient parameter;
the address is hardcoded in the match path. Settlement is performed by an approved operator
in a transaction we are not part of.

So if the singleton signs orders, every vault in the protocol shares one maker identity.
Four things follow, and they are not all bookkeeping:

1. **Positions commingle with no on-chain attribution.** Every trader's ERC-1155 outcome
   tokens arrive at the same address. `IVenueAdapter.positionValue(vault, vaultId)` cannot
   answer honestly, and the position cap and drawdown checks are only as honest as that
   number. This is a safety property degrading, not a ledger inconvenience.
2. **Redemption cannot tell whose position it is claiming.** The permission-free exit path
   depends on being able to identify a vault's holdings.
3. **Internal accounting diverges from reality.** Settlement never calls us, so no vault's
   `idle` decreases when its order fills.
4. **The allowance mirror is aggregate, not per-vault.** ERC-20 allowance is keyed by
   `(owner, spender)`, so one number covers every vault trading that venue. This is why
   `_syncSettlementAllowance` is documented as holding an upper bound rather than an exact
   figure.

Points 1 and 2 are the blocking ones. Nothing in `src/adapters/` can be written honestly
until this is resolved.

## Decision

Give each vault its own address, deployed as an EIP-1167 minimal proxy behind a factory, so
that a vault is an account rather than a row in a mapping.

## Options considered

### Option A: Keep the singleton, attribute settlements off-chain

| Dimension | Assessment |
|---|---|
| Complexity | Low on-chain, high off-chain |
| Cost | Lowest gas |
| Correctness | Fails |
| Team familiarity | High — no change |

An indexer watches settlements and reports each fill's owning vault back on-chain.

**Pros:** No contract changes. No new deployment cost.
**Cons:** Reintroduces exactly the trusted party the architecture exists to remove. A
relayer able to misattribute a fill can move value between traders. README §2 rejects a
cross-chain relayer on this same reasoning; accepting one here would be inconsistent, and
harder to defend because it sits on the custody path rather than beside it.

**Rejected.** Not a close call.

### Option B: Keep the singleton, allow one order-book vault at a time

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Cost | Lowest gas |
| Scalability | None |
| Team familiarity | High |

If only one vault may have live order-book exposure, attribution is unambiguous.

**Pros:** Correct. Trivial to implement as a guard.
**Cons:** The product is a marketplace of many agents trading concurrently for many
traders. A protocol-wide mutex on the primary venue is not a marketplace.

**Rejected**, but worth recording: it is a legitimate shape for a single-vault pilot, and
if we ever want one live Polymarket vault before the refactor lands, this is how.

### Option C: Per-vault EIP-1167 clones (recommended)

| Dimension | Assessment |
|---|---|
| Complexity | Medium-high — touches custody |
| Cost | openVault 105.6k → 181.7k, once per vault; per-call overhead in the noise |
| Scalability | Good; deploy cost is per vault, with a small per-call proxy overhead |
| Team familiarity | Medium — standard pattern, new to this codebase |

`AgentVault` becomes an implementation contract; a factory clones it per `(trader,
listing)`. Each vault is its own address, holding its own tokens, its own positions, its
own allowances, and acting as its own `order.maker`.

**Pros:**
- Attribution becomes structural rather than something we compute. The exchange delivers to
  the vault that traded, because that vault is the maker.
- Position isolation and redemption work with no extra machinery.
- The allowance mirror becomes **exact** rather than an aggregate upper bound, which
  removes a documented imprecision from the settlement guarantee.
- `idle` bookkeeping stops being load-bearing: a vault's own balance *is* its balance, so
  the class of bug the isolation test guards against stops being possible.
- Re-converges with the Solana design, where each vault is already its own PDA. README §2
  states that parity is deliberate and that where they differ, one of them is wrong.

**Cons:**
- `openVault` rises from a measured 105,614 gas to a measured **181,692**. See the
  postscript: this projection was wrong when the ADR was written, and the correction is
  worth reading before quoting the figure.
- Every subsequent call pays an extra `DELEGATECALL` through the proxy. This turned out to
  be in the measurement noise: `deposit` went 173.6k → 171.2k and `executeTrade` 205.6k →
  204.2k, both slightly *down*, because dropping the `bytes32 id` argument and its mapping
  lookups paid for the proxy hop. The per-trade cost of clones is, in practice, nil.
- `AgentRegistry` currently authenticates a single `vault` address (`msg.sender != vault`
  → `NotVault`). With clones it must instead verify that the caller is a clone the factory
  deployed. That is a new trust edge: governance trusts a factory, and the factory attests
  its children. It must be written so a forged address cannot claim to be a vault.
- Every vault needs initialisation rather than construction, with the usual initialiser
  discipline.
- More addresses to index, verify, and reason about operationally.

### Option D: Hybrid — singleton for accounting, thin maker accounts for order-book venues

| Dimension | Assessment |
|---|---|
| Complexity | High |
| Cost | Similar to C |
| Correctness | Achievable |
| Team familiarity | Low |

Keep the singleton as the accounting hub and deploy a minimal per-vault contract used only
as `order.maker` for order-book venues.

**Pros:** The existing atomic path is untouched, so the tested surface does not move.
**Cons:** Two custody models in one protocol, and capital shuttling between them. The
maker account must enforce the same limits as the vault or it becomes a way around them, at
which point it *is* the vault and we have built Option C with extra steps and a second
place for the accounting to be wrong.

**Rejected** on the grounds that it buys a smaller diff at the price of a permanently more
complicated invariant — a bad trade ahead of an audit.

## Trade-off analysis

The decision is not really singleton-versus-clones. It is whether vault identity is
something we track internally or something the outside world can see.

Every venue that settles atomically lets us keep identity internal, because we are in the
transaction and can say who a fill belongs to. Any venue where a third party moves the money
requires identity to be an address, because an address is the only thing that third party
can be told about. Polymarket is the second kind, and it is the venue this product is for.

Given that, Option C is not a performance decision traded against gas. It is the minimum
structure that makes the guarantee expressible on the target venue. The gas cost is real,
one-off, per vault, and small on Polygon.

The strongest argument for delay is that clones touch custody and the current contracts are
close to audit-ready. The counter is that auditing the singleton and then changing the
custody model afterwards wastes the audit.

## Consequences

**Easier**
- Writing a Polymarket adapter at all — currently blocked.
- Reasoning about isolation: separate addresses instead of a mapping discipline.
- An exact allowance mirror; the upper-bound caveat in README §4 goes away.
- Per-vault emergency action, since a vault can be addressed directly.

**Harder**
- Registry authentication moves from one address to factory-attested provenance.
- Deployment, verification, and indexing all deal with many addresses.
- Initialiser discipline replaces constructor guarantees.

**To revisit**
- Whether `vaultId` remains a hash or simply becomes the vault's address.
- Whether the atomic-venue path keeps `_touchedAdapters` unchanged.
- Whether `MAX_OPEN_ORDERS` still needs to be as tight once allowances are per-vault.

## Action items

1. [ ] Confirm on Amoy that a contract can act as `order.maker` end to end — sign under
       `POLY_1271`, get matched by an operator, receive outcome tokens. This ADR rests on
       reading their code; one live trade is worth more than the reading.
2. [x] Registry authentication: governance sets one factory; the factory calls
       `registerVault` for each clone it deploys, and nothing else can. Chosen over
       CREATE2 re-derivation in the registry, which would have needed the registry to
       know the trader as well as the listing on every AUM call.
3. [x] `AgentVault` is an initialisable implementation; `AgentVaultFactory` clones it
       deterministically at `keccak256(trader, listingId)`.
4. [x] `setVault` is now `setVaultFactory`, and `notifyAumDelta` checks the `isVault`
       set rather than a single address.
5. [x] `test_vaultsAreIsolated` now asserts two addresses holding their own balances,
       and `CrossVaultIsolation.t.sol` asserts an allowance cannot reach another vault.
6. [x] The mirror is per-vault and therefore exact; the upper-bound caveat is gone.
7. [x] Measured at 181,692. See the postscript.


---

## Postscript: what the estimate got wrong (22 August 2026)

The ADR projected `openVault` at ~147,000 gas: the measured 105,614 for the old call plus
the measured 41,257 for an EIP-1167 clone. The implemented figure is **181,692**, about 35k
higher. Both inputs were measured correctly; the arithmetic missed the work that only
appears once the pieces are joined up.

The gap is almost entirely the registry attestation this ADR itself called for. Writing
`isVault[vault] = true` is a cold `SSTORE` at 20,000, the cross-contract call to a cold
address adds 2,600, and the `VaultRegistered` event another ~1,900 — around 24.5k that the
"deploy cost" framing quietly left out. The rest is the CREATE2 salt hashing, the existence
check, and the `initialize` call.

One cost in the first implementation was avoidable and has been removed. The factory kept a
`vaultFor` mapping from `(trader, listing)` to address, which is ~20k to write down
something CREATE2 already determines. Existence is now an `EXTCODESIZE` on the predicted
address, at 2,600. That took `openVault` from 200,920 to 181,692.

The decision does not change — 76k of one-off gas on Polygon is still immaterial against
being able to attribute a position at all, and the per-call overhead turned out to be nil.
But an estimate assembled from two correct measurements was still 24% low, and the reason
was a line item this very document listed under Cons without pricing.
