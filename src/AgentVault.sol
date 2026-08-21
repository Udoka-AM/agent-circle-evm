// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAgentRegistry } from "./interfaces/IAgentRegistry.sol";
import { IVenueAdapter } from "./interfaces/IVenueAdapter.sol";
import { VenueWhitelist } from "./VenueWhitelist.sol";
import { Errors } from "./libraries/Errors.sol";
import { Constants } from "./libraries/Constants.sol";
import { HighWaterMark } from "./libraries/HighWaterMark.sol";

/// Non-custodial vault for agent-directed capital.
///
/// The trader is the sole withdrawal authority. The agent holds scoped permission to
/// trade and nothing else: it can never move funds out, only move them between
/// whitelisted venues, and only within limits this contract enforces in the same
/// transaction as the trade.
///
/// ## One contract, many vaults
///
/// A vault is a `(trader, listing)` pair keyed by hash, not a separate deployment.
/// The security properties are per-vault; the token custody is not. This contract holds
/// many traders' tokens at once, so per-vault `idle` bookkeeping is load-bearing and the
/// contract's own ERC-20 balance must never be read as any single vault's balance.
contract AgentVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using HighWaterMark for HighWaterMark.State;

    enum VaultStatus {
        None,
        Active,
        Paused,
        Closing
    }

    struct Vault {
        address trader;
        bytes32 listingId;
        uint256 idle; // quote tokens not currently deployed to a venue
        uint256 reserved; // worst-case cost of authorised orders not yet expired
        uint256 principal; // net deposits
        uint256 highWaterMark;
        uint16 positionCapBps;
        uint16 maxDrawdownBps;
        bool autoPause;
        VaultStatus status;
        uint64 lastFeeAssessment;
        uint32 openOrders; // outstanding authorisations; packs into the tail slot
    }

    /// An order the agent has authorised the vault to sign, but which the venue has not
    /// necessarily settled. Keyed by the digest the venue will ask the vault to confirm.
    struct Order {
        bytes32 vaultId;
        address venue;
        address spender; // pinned at authorisation; who may pull for this order
        uint256 maxCost; // worst-case quote spend if this fills completely
        uint64 expiry;
        bool released;
    }

    IERC20 public immutable quoteToken;
    IAgentRegistry public immutable registry;
    VenueWhitelist public immutable whitelist;
    address public immutable platformTreasury;

    mapping(bytes32 => Vault) public vaults;
    mapping(bytes32 => Order) public orders;

    /// Live reservations per settlement spender, across every vault. The vault's ERC-20
    /// allowance to a spender is held equal to this, which is what makes a cancelled or
    /// expired order actually unsettleable rather than merely disowned.
    mapping(address => uint256) public reservedBySpender;
    mapping(bytes32 => address[]) internal _touchedAdapters;
    mapping(bytes32 => mapping(address => bool)) internal _hasTouched;

    event VaultOpened(bytes32 indexed vaultId, address indexed trader, bytes32 indexed listingId);
    event Deposited(bytes32 indexed vaultId, uint256 amount);
    event Withdrawn(bytes32 indexed vaultId, uint256 amount);
    event TradeExecuted(bytes32 indexed vaultId, address indexed venue, uint256 idleAfter);
    event FeesAssessed(bytes32 indexed vaultId, uint256 builderCut, uint256 platformCut);
    event StatusChanged(bytes32 indexed vaultId, VaultStatus status);
    event AutoPaused(bytes32 indexed vaultId, uint256 drawdownBps);
    event RiskLimitsTightened(bytes32 indexed vaultId, uint16 positionCapBps, uint16 maxDdBps);
    event OrderAuthorised(
        bytes32 indexed vaultId, bytes32 indexed orderHash, uint256 maxCost, uint64 expiry
    );
    event OrderReleased(bytes32 indexed vaultId, bytes32 indexed orderHash, uint256 maxCost);
    event SettlementAllowanceSet(address indexed spender, uint256 amount);
    event PositionExited(bytes32 indexed vaultId, address indexed venue, uint256 proceeds);

    constructor(
        address quoteToken_,
        address registry_,
        address whitelist_,
        address platformTreasury_
    ) {
        if (
            quoteToken_ == address(0) || registry_ == address(0) || whitelist_ == address(0)
                || platformTreasury_ == address(0)
        ) revert Errors.ZeroAddress();

        quoteToken = IERC20(quoteToken_);
        registry = IAgentRegistry(registry_);
        whitelist = VenueWhitelist(whitelist_);
        platformTreasury = platformTreasury_;
    }

    function vaultId(address trader, bytes32 listingId_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(trader, listingId_));
    }

    modifier onlyTrader(bytes32 id) {
        if (vaults[id].trader != msg.sender) revert Errors.NotTrader();
        _;
    }

    // ────────────────────────────────────────────────────────── lifecycle

    /// Risk overrides may only ever be *stricter* than the listing's own limits. A
    /// trader tightening their exposure is their business; loosening it past what the
    /// listing was vetted at would void the guarantee the leaderboard makes to everyone
    /// else. Pass zero for either to inherit the listing's value.
    function openVault(bytes32 listingId_, uint16 positionCapBps_, uint16 maxDrawdownBps_)
        external
        returns (bytes32 id)
    {
        id = vaultId(msg.sender, listingId_);
        if (vaults[id].status != VaultStatus.None) revert Errors.VaultAlreadyExists();

        IAgentRegistry.Listing memory l = registry.getListing(listingId_);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();

        uint16 cap = positionCapBps_ == 0 ? l.positionCapBps : positionCapBps_;
        uint16 dd = maxDrawdownBps_ == 0 ? l.maxDrawdownBps : maxDrawdownBps_;
        if (cap > l.positionCapBps || dd > l.maxDrawdownBps) {
            revert Errors.RiskOverrideNotStricter();
        }

        Vault storage v = vaults[id];
        v.trader = msg.sender;
        v.listingId = listingId_;
        v.positionCapBps = cap;
        v.maxDrawdownBps = dd;
        v.autoPause = true;
        v.status = VaultStatus.Active;
        v.lastFeeAssessment = uint64(block.timestamp);

        emit VaultOpened(id, msg.sender, listingId_);
    }

    function deposit(bytes32 id, uint256 amount) external nonReentrant onlyTrader(id) {
        if (amount == 0) revert Errors.ZeroAmount();
        Vault storage v = vaults[id];
        if (v.status != VaultStatus.Active) revert Errors.VaultNotActive();

        if (amount > registry.availableAumHeadroom(v.listingId)) {
            revert Errors.AumCeilingExceeded();
        }

        quoteToken.safeTransferFrom(msg.sender, address(this), amount);

        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: v.idle, highWaterMark: v.highWaterMark });
        s = s.onDeposit(amount);

        v.idle = s.balance;
        v.highWaterMark = s.highWaterMark;
        v.principal += amount;

        registry.notifyAumDelta(v.listingId, int256(amount));
        emit Deposited(id, amount);
    }

    /// Trader only, and fees are assessed first. Withdrawing ahead of assessment would
    /// let a trader exit a profitable position without paying the fee that profit earned.
    function withdraw(bytes32 id, uint256 amount) external nonReentrant onlyTrader(id) {
        if (amount == 0) revert Errors.ZeroAmount();
        _assessFees(id);

        Vault storage v = vaults[id];
        // Against raw idle, deliberately *not* against idle minus reservations. A
        // trader's authority over their own money outranks an agent's outstanding order,
        // and no reservation may become a lock on a withdrawal.
        //
        // That is safe because a reservation grants no allowance to anybody. It is pure
        // accounting, so a withdrawal cannot let an order settle out of another vault's
        // balance — it simply leaves the order unfunded, and `isOrderAuthorised` then
        // refuses it at settlement. Safety comes from the refusal, not from the lock.
        if (amount > v.idle) revert Errors.InsufficientBalance();

        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: v.idle, highWaterMark: v.highWaterMark });
        s = s.onWithdraw(amount);

        v.idle = s.balance;
        v.highWaterMark = s.highWaterMark;
        v.principal = amount >= v.principal ? 0 : v.principal - amount;

        registry.notifyAumDelta(v.listingId, -int256(amount));
        quoteToken.safeTransfer(v.trader, amount);
        emit Withdrawn(id, amount);
    }

    function pauseVault(bytes32 id) external onlyTrader(id) {
        vaults[id].status = VaultStatus.Paused;
        emit StatusChanged(id, VaultStatus.Paused);
    }

    function resumeVault(bytes32 id) external onlyTrader(id) {
        Vault storage v = vaults[id];
        if (v.status == VaultStatus.None) revert Errors.VaultNotFound();
        v.status = VaultStatus.Active;
        emit StatusChanged(id, VaultStatus.Active);
    }

    /// Tighten-only, for the same reason overrides are stricter-only at open time.
    function tightenRiskLimits(bytes32 id, uint16 positionCapBps_, uint16 maxDrawdownBps_)
        external
        onlyTrader(id)
    {
        Vault storage v = vaults[id];
        if (positionCapBps_ > v.positionCapBps || maxDrawdownBps_ > v.maxDrawdownBps) {
            revert Errors.RiskOverrideNotStricter();
        }
        if (positionCapBps_ == 0 || maxDrawdownBps_ == 0) revert Errors.ZeroAmount();

        v.positionCapBps = positionCapBps_;
        v.maxDrawdownBps = maxDrawdownBps_;
        emit RiskLimitsTightened(id, positionCapBps_, maxDrawdownBps_);
    }

    // ────────────────────────────────────────────────────────── trading

    /// The whole design rests on this function. All six checks hold in the same
    /// transaction as the trade, so a limit cannot be exceeded even briefly.
    ///
    /// The position cap and drawdown checks are enforced as *post-conditions*: rather
    /// than predicting what a venue call will do, the vault performs it and asserts the
    /// resulting state is legal, reverting everything if not. Prediction is fragile
    /// against venues we do not control; assertion is not.
    ///
    /// `maxSpend` bounds the allowance granted, so a compromised adapter cannot pull
    /// more than the agent authorised for this one call.
    function executeTrade(bytes32 id, address venue, uint256 maxSpend, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory result)
    {
        Vault storage v = vaults[id];
        if (v.status == VaultStatus.None) revert Errors.VaultNotFound();
        if (v.status != VaultStatus.Active) revert Errors.VaultNotActive();

        IAgentRegistry.Listing memory l = registry.getListing(v.listingId);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();
        if (msg.sender != l.agentAuthority) revert Errors.NotAgentAuthority();
        if (!whitelist.isWhitelisted(venue)) revert Errors.VenueNotWhitelisted();
        if (maxSpend > v.idle) revert Errors.InsufficientBalance();

        uint256 heldBefore = quoteToken.balanceOf(address(this));

        // Raised for the duration of the call and put back afterwards — back to the
        // venue's standing settlement allowance, not to zero. An adapter that settles
        // atomically is its own settlement spender, so zeroing here would silently revoke
        // the mirror behind every order already authorised against it.
        quoteToken.forceApprove(venue, maxSpend);
        result = IVenueAdapter(venue).execute(address(this), data);
        quoteToken.forceApprove(venue, reservedBySpender[venue]);

        uint256 heldAfter = quoteToken.balanceOf(address(this));
        _touch(id, venue);

        // Attribute the actual token movement to this vault. A venue returning tokens
        // (closing a position) increases idle rather than decreasing it.
        if (heldBefore >= heldAfter) {
            uint256 spent = heldBefore - heldAfter;
            if (spent > v.idle) revert Errors.InsufficientBalance();
            v.idle -= spent;
        } else {
            v.idle += (heldAfter - heldBefore);
        }

        // ── post-conditions
        uint256 valueAfter = _totalValue(id);
        uint256 positionValue = valueAfter - v.idle;

        _requireWithinPositionCap(positionValue, v.reserved, valueAfter, v.positionCapBps);

        uint256 dd = HighWaterMark.drawdownBps(
            HighWaterMark.State({ balance: valueAfter, highWaterMark: v.highWaterMark })
        );
        if (dd >= v.maxDrawdownBps) {
            if (v.autoPause) {
                v.status = VaultStatus.Paused;
                emit AutoPaused(id, dd);
            } else {
                revert Errors.DrawdownLimitBreached();
            }
        }

        emit TradeExecuted(id, venue, v.idle);
    }

    // ────────────────────────────────────────── order authorisation

    /// Authorise the vault to sign one venue order, reserving its worst case up front.
    ///
    /// This is the path for venues that cannot settle atomically — where the agent signs
    /// an order, an order book matches it, and the money moves later in a transaction
    /// this contract is not part of. `executeTrade` is unavailable there, so the limits
    /// have to be enforced somewhere else, and there are only two places left: before the
    /// order is ever signed, and inside the venue's own settlement transaction when it
    /// asks the vault to confirm the signature. This function is the first. It is not
    /// a trade, and nothing moves here.
    ///
    /// The reservation is what makes the first place work. An order is authorised only if
    /// the vault would still be inside its position cap on the assumption that this order
    /// and every other outstanding one fills completely at the worst price the agent
    /// named. Assuming the worst wastes some capital efficiency, and that is the correct
    /// direction to be wrong in: the alternative is an agent authorising three orders
    /// that each pass the cap alone and breach it together.
    ///
    /// `orderHash` is the digest the venue will present back to the vault at settlement,
    /// which is how the two halves find each other.
    function authoriseOrder(
        bytes32 id,
        address venue,
        bytes32 orderHash,
        uint256 maxCost,
        uint64 expiry
    ) external {
        Vault storage v = vaults[id];
        if (v.status == VaultStatus.None) revert Errors.VaultNotFound();
        if (v.status != VaultStatus.Active) revert Errors.VaultNotActive();
        if (maxCost == 0) revert Errors.ZeroAmount();
        if (orders[orderHash].vaultId != bytes32(0)) revert Errors.OrderAlreadyExists();

        IAgentRegistry.Listing memory l = registry.getListing(v.listingId);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();
        if (msg.sender != l.agentAuthority) revert Errors.NotAgentAuthority();
        if (!whitelist.isWhitelisted(venue)) revert Errors.VenueNotWhitelisted();

        if (expiry <= block.timestamp) revert Errors.OrderExpired();
        if (expiry > block.timestamp + Constants.MAX_ORDER_LIFETIME) {
            revert Errors.OrderLifetimeTooLong();
        }

        if (v.openOrders >= Constants.MAX_OPEN_ORDERS) revert Errors.TooManyOpenOrders();

        uint256 reservedAfter = v.reserved + maxCost;
        uint256 value = _totalValue(id);

        // Reservations are backed by idle tokens, not by tokens already in a position.
        // An order the vault could not pay for if it filled is not an order it may sign.
        //
        // At current cap bounds this only bites after a trader's withdrawal has already
        // left the vault short of what is outstanding — a cap of 25% or less cannot on
        // its own authorise more than the idle balance. It is kept as a direct statement
        // of the invariant rather than something inferred from the cap arithmetic.
        if (reservedAfter > v.idle) revert Errors.InsufficientBalance();

        _requireWithinPositionCap(value - v.idle, reservedAfter, value, v.positionCapBps);

        address spender = IVenueAdapter(venue).settlementSpender();
        if (spender == address(0)) revert Errors.ZeroAddress();

        v.reserved = reservedAfter;
        ++v.openOrders;
        orders[orderHash] = Order({
            vaultId: id,
            venue: venue,
            spender: spender,
            maxCost: maxCost,
            expiry: expiry,
            released: false
        });

        _syncSettlementAllowance(spender, reservedBySpender[spender] + maxCost);

        emit OrderAuthorised(id, orderHash, maxCost, expiry);
    }

    /// Withdraw an authorisation before it expires. Either party may: the agent because
    /// it changed its mind, the trader because it is their money and waiting out the
    /// expiry to free a reservation should not be the only option available to them.
    function cancelOrder(bytes32 orderHash) external {
        Order storage o = orders[orderHash];
        if (o.vaultId == bytes32(0)) revert Errors.OrderNotFound();

        Vault storage v = vaults[o.vaultId];
        if (msg.sender != v.trader) {
            if (msg.sender != registry.getListing(v.listingId).agentAuthority) {
                revert Errors.NotTraderOrAgent();
            }
        }
        _release(orderHash);
    }

    /// Cancel several at once.
    ///
    /// The reason this exists rather than being left to the caller: a reservation gates a
    /// withdrawal, so the trader's route back to their own money must not get longer the
    /// more orders the agent happens to have open. With `MAX_OPEN_ORDERS` bounding the
    /// count, clearing every reservation on a vault is always one transaction, whatever
    /// the agent has been doing.
    function cancelOrders(bytes32[] calldata orderHashes) external {
        for (uint256 i; i < orderHashes.length; ++i) {
            bytes32 orderHash = orderHashes[i];
            Order storage o = orders[orderHash];
            if (o.vaultId == bytes32(0)) revert Errors.OrderNotFound();

            Vault storage v = vaults[o.vaultId];
            if (msg.sender != v.trader) {
                if (msg.sender != registry.getListing(v.listingId).agentAuthority) {
                    revert Errors.NotTraderOrAgent();
                }
            }
            _release(orderHash);
        }
    }

    /// Permissionless once expired. A reservation that outlives the order holding it is
    /// only ever dead weight on a trader's capital, so anyone may clear it.
    function releaseExpiredOrder(bytes32 orderHash) external {
        Order storage o = orders[orderHash];
        if (o.vaultId == bytes32(0)) revert Errors.OrderNotFound();
        if (block.timestamp <= o.expiry) revert Errors.OrderNotExpired();
        _release(orderHash);
    }

    /// Whether this order may still settle, evaluated against live state.
    ///
    /// This is the settlement-time half of the design and the seam the venue-facing
    /// signature check will be built on: when a venue asks the vault to confirm a
    /// signature is genuine, it asks inside its own settlement transaction, and a vault
    /// that answers no makes that settlement fail. So an order sitting on a book for an
    /// hour cannot settle if the trader has since paused the vault, withdrawn the money
    /// behind it, the listing has been suspended, or governance has removed the venue.
    /// Refusing at the door is not the same as checking afterwards, but for safety
    /// purposes it is close.
    ///
    /// Deliberately a view. It cannot decrement the reservation as fills arrive, because
    /// the venue's call is a `staticcall` and may not write — which is exactly why an
    /// order is reserved at its full worst case and released only by expiry or by cancel.
    ///
    /// Nothing calls this yet. Whether a vault may sign venue orders at all is the open
    /// question in README §4, and the signature entry point stays unwritten until it is
    /// answered rather than being guessed at.
    function isOrderAuthorised(bytes32 orderHash) public view returns (bool) {
        Order storage o = orders[orderHash];
        if (o.vaultId == bytes32(0) || o.released) return false;
        if (block.timestamp > o.expiry) return false;
        if (!whitelist.isWhitelisted(o.venue)) return false;

        Vault storage v = vaults[o.vaultId];
        if (v.status != VaultStatus.Active) return false;
        if (v.reserved > v.idle) return false;

        if (registry.getListing(v.listingId).status != IAgentRegistry.ListingStatus.Live) {
            return false;
        }

        uint256 value = _totalValue(o.vaultId);
        return (value - v.idle + v.reserved) * Constants.BPS <= value * v.positionCapBps;
    }

    function _release(bytes32 orderHash) internal {
        Order storage o = orders[orderHash];
        if (o.released) revert Errors.OrderNotFound();

        o.released = true;
        Vault storage v = vaults[o.vaultId];
        v.reserved = o.maxCost >= v.reserved ? 0 : v.reserved - o.maxCost;
        --v.openOrders;

        uint256 outstanding = reservedBySpender[o.spender];
        _syncSettlementAllowance(o.spender, o.maxCost >= outstanding ? 0 : outstanding - o.maxCost);

        emit OrderReleased(o.vaultId, orderHash, o.maxCost);
    }

    /// Hold the vault's allowance to `spender` equal to what is reserved against it.
    ///
    /// This is where the guarantee actually lives, and it is worth being precise about
    /// why. The settlement-time signature check was supposed to carry it — the venue asks
    /// the vault to confirm an order, and a vault that says no makes the settlement fail.
    /// Polymarket's V2 exchange lets an operator *preapprove* an order, after which later
    /// matches skip the confirmation entirely and never ask again. The answer is cached,
    /// only the operator can revoke it, and the vault is not consulted a second time.
    ///
    /// An allowance cannot be cached. Settlement has to pull the tokens, and pulling is
    /// checked against live allowance every time by the token itself. So cancelling an
    /// order or letting it expire drops the allowance with it, and a stale order becomes
    /// genuinely unsettleable rather than merely disowned. This needs no cooperation from
    /// the venue, the operator, or anyone else.
    ///
    /// The mirror is an upper bound, not an exact figure. A fill consumes real allowance
    /// as it happens, and the vault cannot see that — the same blind spot that makes a
    /// reservation hold its full worst case until expiry — so re-syncing can restore
    /// allowance a fill had already spent. It is bounded by orders the vault genuinely
    /// authorised and reserved against, and the exchange's own fill accounting stops the
    /// same order settling twice. Wrong in the safe direction, and wrong the same way the
    /// reservation is.
    function _syncSettlementAllowance(address spender, uint256 amount) internal {
        reservedBySpender[spender] = amount;
        quoteToken.forceApprove(spender, amount);
        emit SettlementAllowanceSet(spender, amount);
    }

    // ─────────────────────────────────────────────────── permission-free exit

    /// Leave a position and bring the money home, needing nobody's cooperation.
    ///
    /// Dependence on an operator is the whole problem with the order-book route, so the
    /// escape route is built to have none. Three restrictions are lifted here on purpose,
    /// and each one is a way capital could otherwise be trapped:
    ///
    /// - The **trader may call it**, not only the agent. An agent that has gone silent,
    ///   or hostile, must not be able to hold a position open.
    /// - It works while the vault is **paused or closing**. A vault that auto-paused into
    ///   a drawdown is precisely the vault that most needs to get out.
    /// - The venue **need not still be whitelisted**, provided this vault already traded
    ///   through it. Governance removing a venue must stop new money going in, never
    ///   strand money already there.
    ///
    /// No allowance is granted, and the vault checks its own balance rather than trusting
    /// what the adapter reports: an exit that costs money is not an exit.
    function exitPosition(bytes32 id, address venue, bytes calldata data)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        Vault storage v = vaults[id];
        if (v.status == VaultStatus.None) revert Errors.VaultNotFound();

        if (msg.sender != v.trader) {
            if (msg.sender != registry.getListing(v.listingId).agentAuthority) {
                revert Errors.NotTraderOrAgent();
            }
        }

        // The venue must be one this vault has actually been through, or one still
        // approved. Without this the exit path would be a way to splice an arbitrary
        // contract into `_touchedAdapters`, and every later `_totalValue` would sum
        // whatever position value that contract cared to invent — inflating the vault's
        // worth, suppressing the drawdown check, and letting a builder bill a performance
        // fee on profit that does not exist.
        if (!_hasTouched[id][venue] && !whitelist.isWhitelisted(venue)) {
            revert Errors.VenueNotWhitelisted();
        }

        uint256 heldBefore = quoteToken.balanceOf(address(this));
        IVenueAdapter(venue).exit(address(this), id, data);
        uint256 heldAfter = quoteToken.balanceOf(address(this));

        if (heldAfter < heldBefore) revert Errors.VaultValueDecreasedUnexpectedly();
        proceeds = heldAfter - heldBefore;

        _touch(id, venue);
        v.idle += proceeds;

        // No position-cap or drawdown post-condition. Both measure risk taken on, and
        // this path only ever gives risk back; a vault already over its cap must not be
        // blocked from reducing the position that put it there.
        emit PositionExited(id, venue, proceeds);
    }

    // ────────────────────────────────────────────────────────── fees

    /// Permissionless crank, rate-limited so nobody can grind a vault down through
    /// repeated rounding.
    function assessFees(bytes32 id) external nonReentrant {
        Vault storage v = vaults[id];
        if (v.status == VaultStatus.None) revert Errors.VaultNotFound();
        if (block.timestamp < v.lastFeeAssessment + Constants.FEE_ASSESSMENT_INTERVAL) {
            revert Errors.FeeAssessmentTooSoon();
        }
        _assessFees(id);
    }

    function _assessFees(bytes32 id) internal {
        Vault storage v = vaults[id];
        if (v.status == VaultStatus.None) revert Errors.VaultNotFound();

        IAgentRegistry.Listing memory l = registry.getListing(v.listingId);

        // Fees are charged against total value but can only be *paid* from idle tokens.
        // Capital sitting in an open position is not ours to move.
        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: _totalValue(id), highWaterMark: v.highWaterMark });

        HighWaterMark.FeeSplit memory split;
        (s, split) = s.assess(l.performanceFeeBps, l.builderSplitBps);

        v.lastFeeAssessment = uint64(block.timestamp);
        if (split.total == 0) {
            v.highWaterMark = s.highWaterMark;
            return;
        }

        // Leaving the mark unchanged when the fee cannot be paid is deliberate: the profit
        // stays unbilled and is assessed once capital is free again. Returning rather than
        // reverting matters because `withdraw` assesses fees first, and a revert here would
        // let an unpayable fee block a trader from reaching their own money — the one
        // outcome this contract must never produce.
        if (split.total > v.idle) return;

        v.highWaterMark = s.highWaterMark;
        v.idle -= split.total;

        // TODO(streaming): the Solana design streams the builder's cut via Streamflow
        // rather than paying lump-sum. Sablier is the Polygon analogue. Direct until
        // that is decided.
        quoteToken.safeTransfer(l.builder, split.builderCut);
        quoteToken.safeTransfer(platformTreasury, split.platformCut);

        emit FeesAssessed(id, split.builderCut, split.platformCut);
    }

    // ────────────────────────────────────────────────────────── views

    function totalValue(bytes32 id) external view returns (uint256) {
        return _totalValue(id);
    }

    /// Idle tokens not already spoken for by an outstanding order. This, not `idle`, is
    /// what a withdrawal, a fee, or a new reservation may draw on.
    function availableIdle(bytes32 id) external view returns (uint256) {
        return _availableIdle(vaults[id]);
    }

    function _availableIdle(Vault storage v) internal view returns (uint256) {
        return v.reserved >= v.idle ? 0 : v.idle - v.reserved;
    }

    function touchedAdapters(bytes32 id) external view returns (address[] memory) {
        return _touchedAdapters[id];
    }

    /// Idle tokens plus mark-to-market value of every position the vault holds.
    function _totalValue(bytes32 id) internal view returns (uint256 total) {
        total = vaults[id].idle;
        address[] storage adapters = _touchedAdapters[id];
        for (uint256 i; i < adapters.length; ++i) {
            total += IVenueAdapter(adapters[i]).positionValue(address(this), id);
        }
    }

    /// Positions the vault holds plus the positions its outstanding orders would open if
    /// they all filled, measured against total value. Reservations count as though they
    /// had already happened, which is the whole point of taking them.
    function _requireWithinPositionCap(
        uint256 positionValue,
        uint256 reserved,
        uint256 value,
        uint16 capBps
    ) internal pure {
        if ((positionValue + reserved) * Constants.BPS > value * capBps) {
            revert Errors.PositionCapExceeded();
        }
    }

    function _touch(bytes32 id, address adapter) internal {
        if (_hasTouched[id][adapter]) return;
        _hasTouched[id][adapter] = true;
        _touchedAdapters[id].push(adapter);
    }
}
