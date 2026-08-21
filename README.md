# Agent Circle — EVM

A marketplace for autonomous trading agents in prediction markets, implemented in
Solidity for Polygon.

Developers list self-built, self-hosted agents. Traders allocate capital those agents
trade on their behalf. Custody never transfers: the trader is the sole withdrawal
authority, the agent holds only scoped permission to trade, and position caps and
drawdown limits are enforced by the contract rather than monitored after the fact.

Where a venue settles atomically, those limits hold in the same transaction as the trade.
Where it does not — an order book matching signed orders and settling them later —
they are enforced when the order is authorised and re-checked when it settles, and an
order
that would breach a trader's limits cannot settle. §4 is why that distinction exists and
what is still unresolved about it.

```bash
make journey
```

That prints the entire product as a ten-step walkthrough against real contracts. It is
the fastest way to see what this does.

---

## Status

| | |
|---|---|
| Tests | 86 passing |
| Line coverage | 96% (`HighWaterMark` and `VenueWhitelist` at 100%) |
| Local deployment | Verified — contracts deployed and the full journey driven against a live node |
| Testnet | Not yet deployed to Amoy |
| Audit | Not started |

Branch coverage is 51%, and that number is honest: most unexercised branches are revert
paths on parameter validation. Worth closing before an audit, not before a conversation.

---

## 1. What the contracts do

**`AgentRegistry`** — builder identity, agent listings, staked bonds.

A builder posts a bond and the bond buys a tier. The tier caps how much trader capital
that builder may have under management across *all* their listings at once. Per-builder
rather than per-listing on purpose: a builder able to defraud across three agents is
exposed for the total, not for each one separately.

| Tier | Bond | AUM ceiling |
|---|---|---|
| 0 | — | none; cannot take capital |
| 1 | 25,000 | 25,000 |
| 2 | 100,000 | 150,000 |
| 3 | 400,000 | 1,000,000 |

Listings carry zero economics until governance approves them, so a listing that never
passes vetting can never earn.

**`AgentVault`** — custody and enforcement.

A vault is a `(trader, listing)` pair. The trader deposits and is the only address that
can withdraw. The agent can call `executeTrade` and nothing else, and every trade is
bracketed by six checks that all hold in the same transaction:

1. Vault is active
2. Listing is live
3. Caller is the listing's agent authority
4. Target is a whitelisted venue adapter
5. Resulting position is within the position cap
6. Resulting drawdown is within the limit

Checks 5 and 6 are **post-conditions**. Rather than predicting what a venue call will do,
the vault performs it and asserts the resulting state is legal, reverting everything if
not. Prediction is fragile against venues we do not control; assertion is not.

For venues that cannot settle atomically, the same limits are carried by two further
entry points, described in §4:

- `authoriseOrder` reserves an order's worst-case cost before it is signed, and counts
  every outstanding order against the position cap as though it had already filled.
  Reserved capital is not withdrawable while the order is live, it is mirrored by an
  allowance to whoever actually settles so a cancelled order cannot be pulled, and
  `isOrderAuthorised` re-checks the whole thing against live state at settlement.
- `exitPosition` leaves a position with no third party involved. It is the one path that
  works while the vault is paused and after governance has removed the venue, because
  stopping new money going in must never strand money already there.

**`HighWaterMark`** — fee accounting, and the part most worth reading.

Fees accrue only on profit above a vault's all-time high. Without that, a volatile agent
earns on every up-swing and returns nothing on down-swings, letting a builder farm
variance and extract fees from a trader who ended up flat or down. It is a pure library
over a plain struct so every rule is unit-testable in isolation.

### Economics at launch

| Parameter | Value |
|---|---|
| Listing fee | 0 |
| Performance fee | 10% of profit above the high-water mark |
| Builder / platform split | 80 / 20 |
| Default position cap | 12% of vault value |
| Default max drawdown | 15% from the mark |
| Unbonding period | 14 days |
| Slash split | 70% to harmed traders |

Governance can tune these per listing but cannot exceed the guardrails in
`Constants.sol` — a fully compromised multisig still cannot set a 100% performance fee.

---

## 2. Relationship to the Solana implementation

Agent Circle's registry is already deployed and exercised on Solana devnet. This is a
parallel implementation, not a migration, and the two are kept parameter-identical
deliberately. Where they differ, the shared spec wins and one of them is wrong.

Two translations are worth knowing:

**One contract, many vaults.** On Solana each vault is its own PDA. Deploying a contract
per trader would be pointless gas here, so this is a singleton with a mapping. The
security properties are identical; the accounting is not. This contract custodies many
traders' tokens at once, so per-vault `idle` bookkeeping is load-bearing and the
contract's own ERC-20 balance must never be read as any single vault's balance. There is
a test for exactly that.

**Registry is local.** The Solana vault reaches its registry by CPI. This deployment is
self-contained: `AgentRegistry` lives on the same chain, so there is no bridge and no
relayer attesting cross-chain state. A relayer able to forge a `Live` listing would be a
new trusted party, and the whole design is about removing those.

---

## 3. Governance is designed against a real precedent

In April 2026 Drift lost $285M. The attack was not a code bug: months of social
engineering yielded admin control, and the attacker whitelisted fake collateral.

`VenueWhitelist` is structurally the same object — an allowlist whose compromise drains
every vault at once. So it carries two defences:

- **A timelock on additions.** Queued publicly, cannot execute for two days. A
  compromised governance key buys the attacker an announcement, not the funds.
- **A guardian that can veto and remove but never add.** Least authority in the direction
  that matters: the emergency key can only ever shrink the attack surface.

Removals bypass the timelock deliberately. Waiting out a delay to stop an active exploit
is the wrong trade.

Slashing is governance-executed, not automatic. Being honest about what that means: a
bond deters, it does not make fraud impossible, and the decision to slash is a human one
made by whoever holds the multisig.

---

## 4. The open question: how does an order-book trade settle?

**Still unresolved, but narrower than it looks, and most of the answer is now built.**

Polymarket's CTF Exchange matches signed orders off-chain and settles them later. If a
vault signs an order, the money moves in a transaction this contract is not part of and
cannot attach post-conditions to. `executeTrade` is unavailable there.

### This is not a Polygon problem

Worth stating early, because it changes how the rest of this section should be read.

On 21 August 2026 Jupiter's developer relations confirmed publicly that Jupiter Predict
is settled by off-chain keepers, and that a Solana program "will not be compatible" with
opening positions there — for bridged and native providers alike.

Two candidate venues, two different chains, same shape. Losing atomicity is a property
of order books with off-chain matching, not of the EVM, so the design below is required
on whichever chain this ships to rather than being a Polygon workaround. What differs is
only the mechanism in the middle row of the table below: the EVM has a documented
standard for asking a contract to vouch for its own signature, and whether Solana offers
an equivalent hook is the question currently outstanding with Jupiter.

The original framing — "we lose atomicity, so we lose the guarantee" — was too
pessimistic. There are three places a rule can be enforced, and only one of them is lost:

| Where the rule is checked | Available to us |
|---|---|
| After the trade, in our transaction | No — the settlement is not ours |
| During settlement, inside their transaction | Yes, but see the complication below |
| Before the order is ever signed | Yes, always |

The middle row is the useful part. To settle an order signed by a contract, an exchange
has to ask that contract to confirm the signature is genuine — and it asks *inside its
own settlement transaction*. A vault that answers no makes the settlement fail. That is
not checking afterwards; it is refusing at the door, and for safety purposes the two are
close.

### What is built

**Reservation up front.** `authoriseOrder` moves no money and books the order's full
worst-case cost as spent immediately. An order is authorised only if the vault would
still be inside its position cap assuming that order and every other outstanding one
fills completely at the worst price the agent named. This wastes some capital
efficiency, and that is the correct direction to be wrong in — the alternative is three
orders that each pass the cap alone and breach it together. Reservations and atomic
trades draw on one budget, so the two paths cannot be played against each other.

**The signature is the enforcement.** `isOrderAuthorised` re-evaluates an outstanding
order against live state: the vault still active, the listing still live, the venue still
whitelisted, the money still there, the cap still holding at current marks. An order
resting on a book for an hour cannot settle if the trader has since paused the vault or
withdrawn behind it. It is a `view` because the exchange asks inside a `staticcall` —
which is also why a reservation is held at full worst case and released only by expiry or
cancellation, never decremented as fills arrive.

**An exit that needs nobody's permission.** Closing a position and redeeming a resolved
market are both direct contract calls; only *entering* needs the order book. So
`IVenueAdapter.exit` and `AgentVault.exitPosition` bypass the exchange entirely. The
trader can call it without the agent, it works while the vault is paused or closing, and
it works after the venue has been de-whitelisted. Given that dependence on an operator is
the entire problem, the escape route being operator-free matters more than the entrance
being efficient.

**A reservation gates a withdrawal, and cannot trap anyone.** Reserved capital is not
withdrawable, because this contract pools every vault's tokens: letting a trader take
capital an outstanding order still depends on would mean that order settling out of
somebody else's balance. That safety does not depend on the unbuilt signature mechanism,
which is the point of doing it this way.

The obvious objection is that it hands the agent a lever over the trader's own money. It
does not. The trader can cancel any reservation on their own vault unilaterally, and
`cancelOrders` clears every one of them in a single transaction. Orders also expire
within the hour on their own, and an agent may hold at most `MAX_OPEN_ORDERS` open at
once — so there is no way to bury a trader's capital under a heap of tiny reservations
and make clearing them the expensive part. A full withdrawal is always one transaction
away and never needs the agent's cooperation.

### What honestly weakens

Two things, and they belong in any technical conversation about this.

An authorised order can fill in pieces, and the settlement-time check may only read
state, not update a counter. So the vault cannot track fills as they happen. It
compensates by authorising small orders with short lifetimes, capped at one hour in
`Constants.sol`, and by assuming a full fill in the reservation. The limit still holds;
the vault just cannot be more precise than the order it signed.

And the public claim changes. Not from safe to unsafe, but from *"limits enforced in the
same transaction as the trade"* to *"limits enforced when the order is authorised and
re-checked when it settles; an order that would breach a trader's limits cannot settle."*
Still unusual, still strong, and defensible in a technical conversation — which the
first version would not have been.

### What the exchange actually does — answered from the deployed code

The three questions this section used to leave open are mostly settled. They did not
need a conversation: the CTF Exchange is open source and verified on Polygon, so the
answers were readable. Checked against **V2 at
`0xE111180000d2663C0091e4f400237545B87B996B`**, the live exchange as of August 2026,
audited by Quantstamp and Cantina in March 2026.

**1. Does the exchange accept a smart contract as an order signer? — Yes.** The
load-bearing question, and it comes back in our favour. `SignatureType.POLY_1271` routes
to `_verifyPoly1271Signature`, which requires `signer == maker`, requires the maker to
have code, and then calls Solady's `SignatureCheckerLib.isValidSignatureNow(maker,
...)`. That is EIP-1271 against an arbitrary contract — contract signers are *not*
restricted to Polymarket-derived proxy or Safe addresses, unlike `POLY_PROXY` and
`POLY_GNOSIS_SAFE`, which recompute an expected address from an EOA. A vault can be the
maker and signer of its own orders. The middle row of that table is real.

**2. Who may settle orders? — Operators only, and the old answer here was wrong.** V1
gated `fillOrder`, `fillOrders` and `matchOrders` behind `onlyOperator notPaused`. V2
removed `fillOrder` and `fillOrders` entirely in favour of a single `matchOrders`, still
operator-gated. "Vault as taker, calling `fillOrder` directly against a resting order" —
which an earlier version of this section ranked as the *preferred* resolution — is not
merely disfavoured. That function no longer exists, and was never callable by us when it
did.

**3. Could we run our own settlement operator for our own flow? — Still open, and now the
question that matters most.** See below for why.

### The complication, and it is a real one

V2 added order preapproval, and it punctures the settlement-time guarantee.
`validateOrderSignature` short-circuits: an order submitted with an empty signature is
checked only against a `preapproved[orderHash]` mapping, and never triggers the EIP-1271
call at all.

This is not a hole in Polymarket. `_preapproveOrder` verifies the signature properly —
including asking our vault — before recording anything, so nothing can be forged. But the
consequence for us is sharp: **our vault is asked once, at preapproval, and the answer is
cached.** Subsequent matches never ask again. `preapproveOrder` and
`invalidatePreapprovedOrder` are both `onlyOperator`, so the maker cannot revoke its own
preapproval. An operator can preapprove while a vault says yes and settle later, when it
would say no — the vault paused, the money withdrawn, the cap breached in between.

Worse for the stale-order case, we could not find an on-chain `expiration` check in V2's
match path at all; it appears to be enforced off-chain by the operator. That wants direct
confirmation before anything is built on it, but if it holds, `MAX_ORDER_LIFETIME` bounds
what *our* contract will authorise and bounds nothing about when a signed order may
actually settle.

**What this vindicates.** The reservation accounting, not the signature check, is the
load-bearing safety property — and gating withdrawals on reservations is what makes the
system hold. Reservations hold a trader's capital regardless of what the exchange chooses
to do with a signature. An earlier version of this design let withdrawals through and
rested the guarantee on refusing at settlement; preapproval would have gone straight
through that.

**Where the enforcement actually lives — and this part is now built.** Settlement has to
*pull* tokens from the vault, so the vault's allowance to whoever settles is a kill
switch that needs nobody's cooperation and is checked live, by the token itself, on
every pull. An allowance cannot be cached the way a signature answer can.
`authoriseOrder` grants exactly the reserved amount to the venue's
`settlementSpender()`, and cancelling or expiring an order revokes it — so a stale
preapproved order becomes genuinely unsettleable rather than merely disowned, and the
claim holds without EIP-1271 being consulted at all.

The mirror is an upper bound rather than an exact figure, for the same reason a
reservation holds its full worst case: a fill consumes real allowance and the vault
cannot see it happen, so re-syncing can restore allowance a fill had already spent. It
is bounded by orders the vault authorised and reserved against, and the exchange's own
fill accounting stops one order settling twice. Wrong in the safe direction, and wrong
the same way the reservation is.

The ERC-1155 side is the adapter's, not the vault's: outcome tokens live in the adapter,
and the vault's custody is of quote tokens.

What is still genuinely open is per-vault attribution of an order-book settlement. When
the exchange pulls from the pooled balance, no vault's `idle` decreases, because the
vault is not in that transaction. The aggregate stays solvent — every live reservation
is backed by its own vault's idle — but reconciling a settled fill back to the vault
that caused it needs a settlement notification. The exchange hardcodes `order.maker` as
both the source of collateral and the destination for outcome tokens, so a singleton
vault cannot express whose position is whose — see
[ADR-0001](docs/adr/0001-vault-topology.md), which proposes per-vault clones.

### What is not built, and why

The venue-facing signature entry point. Everything above is the seam it plugs into, and
Q1 coming back positive means it is now buildable. The allowance mirroring it needed to
sit alongside is in place, so this is no longer blocked on anything but the work.

Per-vault attribution of an order-book settlement, described above. The aggregate is
safe; the bookkeeping is not yet.

`src/adapters/` still does not exist. `IVenueAdapter.execute` remains documented as
requiring atomicity, and an adapter that merely queues an order does not satisfy it and
must not be whitelisted — the order-book case has its own path rather than being
smuggled through that one.

---

## 5. Layout

```
src/
  AgentRegistry.sol           builders, listings, bonds, tiers, AUM ceilings
  AgentVault.sol              custody, limit enforcement, order reservations, fees
  VenueWhitelist.sol          timelocked allowlist with a veto-only guardian
  interfaces/
    IAgentRegistry.sol
    IVenueAdapter.sol         the seam described in §4: execute, exit,
                              settlementSpender, positionValue
  libraries/
    HighWaterMark.sol         fee accounting
    Constants.sol             locked launch parameters and governance guardrails
    Errors.sol                named to match the Anchor error codes
test/
  Journey.t.sol               the whole product, printed. start here
  HighWaterMark.t.sol         variance-farming scenarios plus fuzz invariants
  AgentRegistry.t.sol         bonding, tiers, listing lifecycle, AUM ceiling
  AgentVault.t.sol            custody, limits, isolation, fees
  Reservations.t.sol          order authorisation and the permission-free exit
  VenueWhitelist.t.sol        the Drift lesson, encoded
script/
  Deploy.s.sol                real deployment
  DeployLocal.s.sol           local chain harness
docs/
  adr/0001-vault-topology.md  singleton vs per-vault clones; open decision
```

---

## 6. Running it

```bash
forge install
```

```bash
forge test
```

```bash
make journey
```

To exercise it against a live node, run `make anvil` in one terminal and
`make deploy-local` in another.

### Before mainnet

- `GOVERNANCE` must be a Safe multisig, never an EOA. The deploy script cannot tell the
  difference, so this is on the operator.
- `GUARDIAN` must be a separate key, held by a different person, on different hardware.
  A guardian on the same laptop as governance is decoration.
- Audit, covering `HighWaterMark`, `AgentVault.executeTrade`, and the order-reservation
  path first.
- §4's three questions answered, and the signature entry point built against the answers
  rather than around them.

---

## Licence

BUSL-1.1.
