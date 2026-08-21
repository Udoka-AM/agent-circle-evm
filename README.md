# Agent Circle — EVM

A marketplace for autonomous trading agents in prediction markets, implemented in
Solidity for Polygon.

Developers list self-built, self-hosted agents. Traders allocate capital those agents
trade on their behalf. Custody never transfers: the trader is the sole withdrawal
authority, the agent holds only scoped permission to trade, and position caps and
drawdown limits are enforced in the same transaction as the trade rather than monitored
after it.

```bash
make journey
```

That prints the entire product as a ten-step walkthrough against real contracts. It is
the fastest way to see what this does.

---

## Status

| | |
|---|---|
| Tests | 51 passing |
| Line coverage | 95% (`HighWaterMark` and `VenueWhitelist` at 100%) |
| Local deployment | Verified — contracts deployed and the full journey driven against a live node |
| Testnet | Not yet deployed to Amoy |
| Audit | Not started |

Branch coverage is 45%, and that number is honest: most unexercised branches are revert
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

## 4. The open question: how does a Polymarket trade settle?

**Unresolved, and the one thing that could force a redesign.**

Polymarket's CTF Exchange matches signed orders off-chain and settles them later. If a
vault signs an order, funds move in a transaction we do not control and cannot attach
post-conditions to. That breaks "limits enforced atomically, in the same transaction as
the trade," which is the sentence this product rests on.

Possible resolutions, in order of preference:

1. **Vault as taker.** Call `fillOrder` directly against a resting order. Atomic, and the
   post-conditions hold. Costs the maker rebate and needs a counterparty order to exist
   at an acceptable price.
2. **Bounded pre-authorisation.** Sign only orders whose worst-case fill is provably
   inside the limits. Weaker — enforces at signing rather than settlement, and stale
   orders are a real hazard.
3. **Operator-side enforcement.** Rejected. Puts the guarantee in someone else's process.

`IVenueAdapter.execute` is documented to require atomicity precisely so this cannot be
quietly compromised. An adapter that merely queues an order does not satisfy the
interface and must not be whitelisted.

**No Polymarket adapter is written yet, on purpose.** `src/adapters/` does not exist
because a half-designed adapter would be the most expensive thing in this repository.
This is the first thing to resolve with anyone from the Polymarket or Polygon side.

---

## 5. Layout

```
src/
  AgentRegistry.sol           builders, listings, bonds, tiers, AUM ceilings
  AgentVault.sol              custody, limit enforcement, fee assessment
  VenueWhitelist.sol          timelocked allowlist with a veto-only guardian
  interfaces/
    IAgentRegistry.sol
    IVenueAdapter.sol         the seam described in §4
  libraries/
    HighWaterMark.sol         fee accounting
    Constants.sol             locked launch parameters and governance guardrails
    Errors.sol                named to match the Anchor error codes
test/
  Journey.t.sol               the whole product, printed. start here
  HighWaterMark.t.sol         variance-farming scenarios plus fuzz invariants
  AgentRegistry.t.sol         bonding, tiers, listing lifecycle, AUM ceiling
  AgentVault.t.sol            custody, limits, isolation, fees
  VenueWhitelist.t.sol        the Drift lesson, encoded
script/
  Deploy.s.sol                real deployment
  DeployLocal.s.sol           local chain harness
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
- Audit, covering `HighWaterMark` and `AgentVault.executeTrade` first.
- §4 resolved and documented, not worked around.

---

## Licence

BUSL-1.1.
