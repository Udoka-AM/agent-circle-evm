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
        uint256 principal; // net deposits
        uint256 highWaterMark;
        uint16 positionCapBps;
        uint16 maxDrawdownBps;
        bool autoPause;
        VaultStatus status;
        uint64 lastFeeAssessment;
    }

    IERC20 public immutable quoteToken;
    IAgentRegistry public immutable registry;
    VenueWhitelist public immutable whitelist;
    address public immutable platformTreasury;

    mapping(bytes32 => Vault) public vaults;
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

        quoteToken.forceApprove(venue, maxSpend);
        result = IVenueAdapter(venue).execute(address(this), data);
        quoteToken.forceApprove(venue, 0);

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

        if (positionValue * Constants.BPS > valueAfter * v.positionCapBps) {
            revert Errors.PositionCapExceeded();
        }

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

        // Leaving the mark unchanged when the fee cannot be paid is deliberate: the
        // profit stays unbilled and will be assessed once capital is idle again.
        if (split.total > v.idle) revert Errors.InsufficientBalance();

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

    function _touch(bytes32 id, address adapter) internal {
        if (_hasTouched[id][adapter]) return;
        _hasTouched[id][adapter] = true;
        _touchedAdapters[id].push(adapter);
    }
}
