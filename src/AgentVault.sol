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

/// Non-custodial vault for agent-directed capital. One deployment per `(trader, listing)`.
///
/// The trader is the sole withdrawal authority. The agent holds scoped permission to trade
/// and nothing else: it can never move funds out, only move them between whitelisted
/// venues, and only within limits this contract enforces.
///
/// ## One vault, one address
///
/// This was a singleton — one contract holding every trader's tokens against a mapping of
/// `(trader, listing)` hashes. It is now an implementation contract cloned per vault by
/// `AgentVaultFactory`, because an order book forces the question.
///
/// Polymarket's exchange pulls a maker's collateral from `order.maker` and delivers the
/// outcome tokens back to `order.maker`, with no alternate recipient. Under a singleton
/// every vault in the protocol would share one maker identity: positions would arrive
/// commingled at one address with no on-chain way to say whose is whose, which leaves
/// `positionValue` — and therefore the position cap and the drawdown check — unable to
/// answer honestly. See ADR-0001.
///
/// Identity being an address rather than a mapping key is not a convenience here. It is
/// the only form of identity a third party settling our trades can be told about.
///
/// Two things follow that used to need care and no longer do. A vault's own token balance
/// *is* its balance. And the allowance mirror is exact rather than an upper bound
/// aggregated across every vault sharing one contract.
contract AgentVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using HighWaterMark for HighWaterMark.State;

    enum VaultStatus {
        None,
        Active,
        Paused,
        Closing
    }

    /// An order the agent has authorised the vault to sign, but which the venue has not
    /// necessarily settled. Keyed by the digest the venue will ask the vault to confirm.
    struct Order {
        address venue;
        address spender; // pinned at authorisation; who may pull for this order
        uint256 maxCost; // worst-case quote spend if this fills completely
        uint64 expiry;
        bool released;
    }

    // ── protocol-wide, and identical for every clone: immutables live in the
    // implementation's bytecode, which every clone delegates to.
    IERC20 public immutable quoteToken;
    IAgentRegistry public immutable registry;
    VenueWhitelist public immutable whitelist;
    address public immutable platformTreasury;

    // ── this vault
    address public trader;
    bytes32 public listingId;
    uint256 public idle; // quote tokens not currently deployed to a venue
    uint256 public reserved; // worst-case cost of authorised orders not yet expired
    uint256 public principal; // net deposits
    uint256 public highWaterMark;
    uint16 public positionCapBps;
    uint16 public maxDrawdownBps;
    bool public autoPause;
    VaultStatus public status;
    uint64 public lastFeeAssessment;
    uint32 public openOrders;

    mapping(bytes32 => Order) public orders;

    /// Live reservations per settlement spender. The vault's ERC-20 allowance to a spender
    /// is held equal to this, which is what makes a cancelled or expired order actually
    /// unsettleable rather than merely disowned.
    mapping(address => uint256) public reservedBySpender;

    address[] internal _touchedAdapters;
    mapping(address => bool) internal _hasTouched;

    event VaultOpened(address indexed trader, bytes32 indexed listingId);
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event TradeExecuted(address indexed venue, uint256 idleAfter);
    event FeesAssessed(uint256 builderCut, uint256 platformCut);
    event StatusChanged(VaultStatus status);
    event AutoPaused(uint256 drawdownBps);
    event RiskLimitsTightened(uint16 positionCapBps, uint16 maxDdBps);
    event OrderAuthorised(bytes32 indexed orderHash, uint256 maxCost, uint64 expiry);
    event OrderReleased(bytes32 indexed orderHash, uint256 maxCost);
    event SettlementAllowanceSet(address indexed spender, uint256 amount);
    event PositionExited(address indexed venue, uint256 proceeds);

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

        // The implementation itself must never be initialisable. It holds no funds, but a
        // vault whose trader is whoever called first is a confusing thing to leave lying
        // around at a known address.
        status = VaultStatus.Closing;
    }

    modifier onlyTrader() {
        if (msg.sender != trader) revert Errors.NotTrader();
        _;
    }

    modifier onlyLive() {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();
        _;
    }

    // ────────────────────────────────────────────────────────── lifecycle

    /// Called once by the factory, in the transaction that deploys the clone.
    ///
    /// Risk overrides may only ever be *stricter* than the listing's own limits. A trader
    /// tightening their exposure is their business; loosening it past what the listing was
    /// vetted at would void the guarantee the leaderboard makes to everyone else. Pass zero
    /// for either to inherit the listing's value.
    function initialize(
        address trader_,
        bytes32 listingId_,
        uint16 positionCapBps_,
        uint16 maxDrawdownBps_
    ) external {
        if (status != VaultStatus.None) revert Errors.VaultAlreadyExists();
        if (trader_ == address(0)) revert Errors.ZeroAddress();

        IAgentRegistry.Listing memory l = registry.getListing(listingId_);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();

        uint16 cap = positionCapBps_ == 0 ? l.positionCapBps : positionCapBps_;
        uint16 dd = maxDrawdownBps_ == 0 ? l.maxDrawdownBps : maxDrawdownBps_;
        if (cap > l.positionCapBps || dd > l.maxDrawdownBps) {
            revert Errors.RiskOverrideNotStricter();
        }

        trader = trader_;
        listingId = listingId_;
        positionCapBps = cap;
        maxDrawdownBps = dd;
        autoPause = true;
        status = VaultStatus.Active;
        lastFeeAssessment = uint64(block.timestamp);

        emit VaultOpened(trader_, listingId_);
    }

    function deposit(uint256 amount) external nonReentrant onlyTrader {
        if (amount == 0) revert Errors.ZeroAmount();
        if (status != VaultStatus.Active) revert Errors.VaultNotActive();

        if (amount > registry.availableAumHeadroom(listingId)) {
            revert Errors.AumCeilingExceeded();
        }

        quoteToken.safeTransferFrom(msg.sender, address(this), amount);

        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: idle, highWaterMark: highWaterMark });
        s = s.onDeposit(amount);

        idle = s.balance;
        highWaterMark = s.highWaterMark;
        principal += amount;

        registry.notifyAumDelta(listingId, int256(amount));
        emit Deposited(amount);
    }

    /// Trader only, and fees are assessed first. Withdrawing ahead of assessment would let
    /// a trader exit a profitable position without paying the fee that profit earned.
    function withdraw(uint256 amount) external nonReentrant onlyTrader {
        if (amount == 0) revert Errors.ZeroAmount();
        _assessFees();

        // Against *available* idle, not raw idle. A reservation is not pure accounting: it
        // grants the settlement spender a real, standing permission to pull that amount.
        // Withdrawing the backing while leaving that permission live would leave an
        // allowance this vault could not honour.
        //
        // This cannot trap anyone. Orders live at most `MAX_ORDER_LIFETIME`, and the trader
        // can `cancelOrder` or `cancelOrders` any reservation on their own vault, so a full
        // withdrawal is always one transaction away and never needs the agent.
        if (amount > _availableIdle()) revert Errors.InsufficientBalance();

        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: idle, highWaterMark: highWaterMark });
        s = s.onWithdraw(amount);

        idle = s.balance;
        highWaterMark = s.highWaterMark;
        principal = amount >= principal ? 0 : principal - amount;

        registry.notifyAumDelta(listingId, -int256(amount));
        quoteToken.safeTransfer(trader, amount);
        emit Withdrawn(amount);
    }

    function pauseVault() external onlyTrader {
        status = VaultStatus.Paused;
        emit StatusChanged(VaultStatus.Paused);
    }

    function resumeVault() external onlyTrader {
        status = VaultStatus.Active;
        emit StatusChanged(VaultStatus.Active);
    }

    /// Tighten-only, for the same reason overrides are stricter-only at open time.
    function tightenRiskLimits(uint16 positionCapBps_, uint16 maxDrawdownBps_) external onlyTrader {
        if (positionCapBps_ > positionCapBps || maxDrawdownBps_ > maxDrawdownBps) {
            revert Errors.RiskOverrideNotStricter();
        }
        if (positionCapBps_ == 0 || maxDrawdownBps_ == 0) revert Errors.ZeroAmount();

        positionCapBps = positionCapBps_;
        maxDrawdownBps = maxDrawdownBps_;
        emit RiskLimitsTightened(positionCapBps_, maxDrawdownBps_);
    }

    // ────────────────────────────────────────────────────────── trading

    /// The whole design rests on this function. All six checks hold in the same transaction
    /// as the trade, so a limit cannot be exceeded even briefly.
    ///
    /// The position cap and drawdown checks are enforced as *post-conditions*: rather than
    /// predicting what a venue call will do, the vault performs it and asserts the resulting
    /// state is legal, reverting everything if not. Prediction is fragile against venues we
    /// do not control; assertion is not.
    ///
    /// `maxSpend` bounds the allowance granted, so a compromised adapter cannot pull more
    /// than the agent authorised for this one call.
    function executeTrade(address venue, uint256 maxSpend, bytes calldata data)
        external
        nonReentrant
        onlyLive
        returns (bytes memory result)
    {
        if (status != VaultStatus.Active) revert Errors.VaultNotActive();

        IAgentRegistry.Listing memory l = registry.getListing(listingId);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();
        if (msg.sender != l.agentAuthority) revert Errors.NotAgentAuthority();
        if (!whitelist.isWhitelisted(venue)) revert Errors.VenueNotWhitelisted();
        if (maxSpend > _availableIdle()) revert Errors.InsufficientBalance();

        uint256 heldBefore = quoteToken.balanceOf(address(this));

        // Raised for the duration of the call and put back afterwards — back to the venue's
        // standing settlement allowance, not to zero. An adapter that settles atomically is
        // its own settlement spender, so zeroing here would silently revoke the mirror
        // behind every order already authorised against it.
        quoteToken.forceApprove(venue, maxSpend);
        result = IVenueAdapter(venue).execute(address(this), data);
        quoteToken.forceApprove(venue, reservedBySpender[venue]);

        uint256 heldAfter = quoteToken.balanceOf(address(this));
        _touch(venue);

        if (heldBefore >= heldAfter) {
            uint256 spent = heldBefore - heldAfter;
            if (spent > idle) revert Errors.InsufficientBalance();
            idle -= spent;
        } else {
            idle += (heldAfter - heldBefore);
        }

        // ── post-conditions
        uint256 valueAfter = _totalValue();
        _requireWithinPositionCap(valueAfter - idle, reserved, valueAfter, positionCapBps);

        uint256 dd = HighWaterMark.drawdownBps(
            HighWaterMark.State({ balance: valueAfter, highWaterMark: highWaterMark })
        );
        if (dd >= maxDrawdownBps) {
            if (autoPause) {
                status = VaultStatus.Paused;
                emit AutoPaused(dd);
            } else {
                revert Errors.DrawdownLimitBreached();
            }
        }

        emit TradeExecuted(venue, idle);
    }

    // ────────────────────────────────────────── order authorisation

    /// Authorise the vault to sign one venue order, reserving its worst case up front.
    ///
    /// This is the path for venues that cannot settle atomically — where the agent signs an
    /// order, an order book matches it, and the money moves later in a transaction this
    /// contract is not part of. `executeTrade` is unavailable there, so the limits have to
    /// be enforced somewhere else. This is that place, and nothing moves here.
    ///
    /// An order is authorised only if the vault would still be inside its position cap on
    /// the assumption that this order and every other outstanding one fills completely at
    /// the worst price the agent named. Assuming the worst wastes some capital efficiency,
    /// and that is the correct direction to be wrong in: the alternative is an agent
    /// authorising three orders that each pass the cap alone and breach it together.
    ///
    /// `orderHash` is the digest the venue will present back to the vault at settlement,
    /// which is how the two halves find each other.
    function authoriseOrder(address venue, bytes32 orderHash, uint256 maxCost, uint64 expiry)
        external
        onlyLive
    {
        if (status != VaultStatus.Active) revert Errors.VaultNotActive();
        if (maxCost == 0) revert Errors.ZeroAmount();
        if (orders[orderHash].venue != address(0)) revert Errors.OrderAlreadyExists();

        IAgentRegistry.Listing memory l = registry.getListing(listingId);
        if (l.status != IAgentRegistry.ListingStatus.Live) revert Errors.ListingNotLive();
        if (msg.sender != l.agentAuthority) revert Errors.NotAgentAuthority();
        if (!whitelist.isWhitelisted(venue)) revert Errors.VenueNotWhitelisted();

        if (expiry <= block.timestamp) revert Errors.OrderExpired();
        if (expiry > block.timestamp + Constants.MAX_ORDER_LIFETIME) {
            revert Errors.OrderLifetimeTooLong();
        }

        if (openOrders >= Constants.MAX_OPEN_ORDERS) revert Errors.TooManyOpenOrders();

        uint256 reservedAfter = reserved + maxCost;
        uint256 value = _totalValue();

        // Reservations are backed by idle tokens, not by tokens already in a position. An
        // order the vault could not pay for if it filled is not an order it may sign.
        if (reservedAfter > idle) revert Errors.InsufficientBalance();

        _requireWithinPositionCap(value - idle, reservedAfter, value, positionCapBps);

        address spender = IVenueAdapter(venue).settlementSpender();
        if (spender == address(0)) revert Errors.ZeroAddress();

        reserved = reservedAfter;
        ++openOrders;
        orders[orderHash] = Order({
            venue: venue, spender: spender, maxCost: maxCost, expiry: expiry, released: false
        });

        _syncSettlementAllowance(spender, reservedBySpender[spender] + maxCost);

        emit OrderAuthorised(orderHash, maxCost, expiry);
    }

    /// Withdraw an authorisation before it expires. Either party may: the agent because it
    /// changed its mind, the trader because it is their money and waiting out the expiry to
    /// free a reservation should not be the only option available to them.
    function cancelOrder(bytes32 orderHash) external onlyLive {
        _requireTraderOrAgent();
        if (orders[orderHash].venue == address(0)) revert Errors.OrderNotFound();
        _release(orderHash);
    }

    /// Cancel several at once.
    ///
    /// The reason this exists rather than being left to the caller: a reservation gates a
    /// withdrawal, so the trader's route back to their own money must not get longer the
    /// more orders the agent happens to have open. With `MAX_OPEN_ORDERS` bounding the
    /// count, clearing every reservation on a vault is always one transaction, whatever the
    /// agent has been doing.
    function cancelOrders(bytes32[] calldata orderHashes) external onlyLive {
        _requireTraderOrAgent();
        for (uint256 i; i < orderHashes.length; ++i) {
            if (orders[orderHashes[i]].venue == address(0)) revert Errors.OrderNotFound();
            _release(orderHashes[i]);
        }
    }

    /// Permissionless once expired. A reservation that outlives the order holding it is only
    /// ever dead weight on a trader's capital, so anyone may clear it.
    function releaseExpiredOrder(bytes32 orderHash) external onlyLive {
        Order storage o = orders[orderHash];
        if (o.venue == address(0)) revert Errors.OrderNotFound();
        if (block.timestamp <= o.expiry) revert Errors.OrderNotExpired();
        _release(orderHash);
    }

    /// Whether this order may still settle, evaluated against live state.
    ///
    /// This is the seam the venue-facing signature check will be built on: when a venue asks
    /// the vault to confirm a signature is genuine, it asks inside its own settlement
    /// transaction, and a vault that answers no makes that settlement fail.
    ///
    /// Deliberately a view — the venue's call is a `staticcall` and may not write, which is
    /// why an order is reserved at its full worst case and released only by expiry or by
    /// cancel.
    ///
    /// It is not, on its own, sufficient. Polymarket's V2 exchange lets an operator
    /// preapprove an order, after which later matches skip the confirmation entirely and
    /// never ask again. That is what the allowance mirror is for, and why the mirror rather
    /// than this function carries the guarantee.
    function isOrderAuthorised(bytes32 orderHash) public view returns (bool) {
        Order storage o = orders[orderHash];
        if (o.venue == address(0) || o.released) return false;
        if (block.timestamp > o.expiry) return false;
        if (!whitelist.isWhitelisted(o.venue)) return false;
        if (status != VaultStatus.Active) return false;
        if (reserved > idle) return false;

        if (registry.getListing(listingId).status != IAgentRegistry.ListingStatus.Live) {
            return false;
        }

        uint256 value = _totalValue();
        return (value - idle + reserved) * Constants.BPS <= value * positionCapBps;
    }

    function _release(bytes32 orderHash) internal {
        Order storage o = orders[orderHash];
        if (o.released) revert Errors.OrderNotFound();

        o.released = true;
        reserved = o.maxCost >= reserved ? 0 : reserved - o.maxCost;
        --openOrders;

        uint256 outstanding = reservedBySpender[o.spender];
        _syncSettlementAllowance(o.spender, o.maxCost >= outstanding ? 0 : outstanding - o.maxCost);

        emit OrderReleased(orderHash, o.maxCost);
    }

    /// Hold the vault's allowance to `spender` equal to what is reserved against it.
    ///
    /// This is where the guarantee actually lives. The settlement-time signature check was
    /// supposed to carry it — the venue asks the vault to confirm an order, and a vault that
    /// says no makes the settlement fail. Polymarket's V2 exchange lets an operator
    /// *preapprove* an order, after which later matches skip the confirmation entirely. The
    /// answer is cached, only the operator can revoke it, and the vault is never asked a
    /// second time.
    ///
    /// An allowance cannot be cached. Settlement has to pull the tokens, and pulling is
    /// checked against live allowance every time by the token itself. So cancelling an order
    /// or letting it expire drops the allowance with it, and a stale order becomes genuinely
    /// unsettleable rather than merely disowned. This needs no cooperation from the venue,
    /// the operator, or anyone else.
    ///
    /// Now that a vault is its own address, this is exact rather than an upper bound
    /// aggregated across every vault sharing one contract.
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
    /// - The **trader may call it**, not only the agent. An agent that has gone silent, or
    ///   hostile, must not be able to hold a position open.
    /// - It works while the vault is **paused or closing**. A vault that auto-paused into a
    ///   drawdown is precisely the vault that most needs to get out.
    /// - The venue **need not still be whitelisted**, provided this vault already traded
    ///   through it. Governance removing a venue must stop new money going in, never strand
    ///   money already there.
    ///
    /// No allowance is granted, and the vault checks its own balance rather than trusting
    /// what the adapter reports: an exit that costs money is not an exit.
    function exitPosition(address venue, bytes calldata data)
        external
        nonReentrant
        onlyLive
        returns (uint256 proceeds)
    {
        _requireTraderOrAgent();

        // The venue must be one this vault has actually been through, or one still approved.
        // Without this the exit path would be a way to splice an arbitrary contract into
        // `_touchedAdapters`, and every later `_totalValue` would sum whatever position
        // value that contract cared to invent — inflating the vault's worth, suppressing the
        // drawdown check, and letting a builder bill a performance fee on profit that does
        // not exist.
        if (!_hasTouched[venue] && !whitelist.isWhitelisted(venue)) {
            revert Errors.VenueNotWhitelisted();
        }

        uint256 heldBefore = quoteToken.balanceOf(address(this));
        IVenueAdapter(venue).exit(address(this), data);
        uint256 heldAfter = quoteToken.balanceOf(address(this));

        if (heldAfter < heldBefore) revert Errors.VaultValueDecreasedUnexpectedly();
        proceeds = heldAfter - heldBefore;

        _touch(venue);
        idle += proceeds;

        // No position-cap or drawdown post-condition. Both measure risk taken on, and this
        // path only ever gives risk back; a vault already over its cap must not be blocked
        // from reducing the position that put it there.
        emit PositionExited(venue, proceeds);
    }

    // ────────────────────────────────────────────────────────── fees

    /// Permissionless crank, rate-limited so nobody can grind a vault down through repeated
    /// rounding.
    function assessFees() external nonReentrant onlyLive {
        if (block.timestamp < lastFeeAssessment + Constants.FEE_ASSESSMENT_INTERVAL) {
            revert Errors.FeeAssessmentTooSoon();
        }
        _assessFees();
    }

    function _assessFees() internal {
        if (status == VaultStatus.None) revert Errors.VaultNotFound();

        IAgentRegistry.Listing memory l = registry.getListing(listingId);

        // Fees are charged against total value but can only be *paid* from idle tokens.
        // Capital sitting in an open position is not ours to move.
        HighWaterMark.State memory s =
            HighWaterMark.State({ balance: _totalValue(), highWaterMark: highWaterMark });

        HighWaterMark.FeeSplit memory split;
        (s, split) = s.assess(l.performanceFeeBps, l.builderSplitBps);

        lastFeeAssessment = uint64(block.timestamp);
        if (split.total == 0) {
            highWaterMark = s.highWaterMark;
            return;
        }

        // Leaving the mark unchanged when the fee cannot be paid is deliberate: the profit
        // stays unbilled and is assessed once capital is free again. Returning rather than
        // reverting matters because `withdraw` assesses fees first, and a revert here would
        // let an unpayable fee block a trader from reaching their own money — the one
        // outcome this contract must never produce.
        //
        // Payable from *available* idle only, for the same reason a withdrawal is: a fee
        // taken out of capital backing a live order would leave an allowance this vault
        // could not honour.
        if (split.total > _availableIdle()) return;

        highWaterMark = s.highWaterMark;
        idle -= split.total;

        // TODO(streaming): the Solana design streams the builder's cut via Streamflow rather
        // than paying lump-sum. Sablier is the Polygon analogue. Direct until that is
        // decided.
        quoteToken.safeTransfer(l.builder, split.builderCut);
        quoteToken.safeTransfer(platformTreasury, split.platformCut);

        emit FeesAssessed(split.builderCut, split.platformCut);
    }

    // ────────────────────────────────────────────────────────── views

    function totalValue() external view returns (uint256) {
        return _totalValue();
    }

    /// Idle tokens not already spoken for by an outstanding order. This, not `idle`, is what
    /// a withdrawal, a fee, or a new reservation may draw on.
    function availableIdle() external view returns (uint256) {
        return _availableIdle();
    }

    function touchedAdapters() external view returns (address[] memory) {
        return _touchedAdapters;
    }

    function _availableIdle() internal view returns (uint256) {
        return reserved >= idle ? 0 : idle - reserved;
    }

    /// Idle tokens plus mark-to-market value of every position the vault holds.
    function _totalValue() internal view returns (uint256 total) {
        total = idle;
        uint256 n = _touchedAdapters.length;
        for (uint256 i; i < n; ++i) {
            total += IVenueAdapter(_touchedAdapters[i]).positionValue(address(this));
        }
    }

    /// Positions the vault holds plus the positions its outstanding orders would open if
    /// they all filled, measured against total value. Reservations count as though they had
    /// already happened, which is the whole point of taking them.
    function _requireWithinPositionCap(
        uint256 positionValue,
        uint256 reserved_,
        uint256 value,
        uint16 capBps
    ) internal pure {
        if ((positionValue + reserved_) * Constants.BPS > value * capBps) {
            revert Errors.PositionCapExceeded();
        }
    }

    function _requireTraderOrAgent() internal view {
        if (msg.sender == trader) return;
        if (msg.sender != registry.getListing(listingId).agentAuthority) {
            revert Errors.NotTraderOrAgent();
        }
    }

    function _touch(address adapter) internal {
        if (_hasTouched[adapter]) return;
        _hasTouched[adapter] = true;
        _touchedAdapters.push(adapter);
    }
}
