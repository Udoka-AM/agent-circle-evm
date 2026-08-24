// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAgentRegistry } from "./interfaces/IAgentRegistry.sol";
import { Errors } from "./libraries/Errors.sol";
import { Constants } from "./libraries/Constants.sol";

/// Builder identity, agent listings, and the staked bonds that back them.
///
/// A builder posts a bond in the platform token. The bond buys a tier, and the tier sets
/// a ceiling on how much trader capital that builder may have under management across
/// *all* their listings at once. The ceiling is per-builder rather than per-listing on
/// purpose: a builder able to defraud across three agents is exposed for the total, not
/// for each one separately.
///
/// The registry never touches trader funds. It is the permission and reputation layer;
/// `AgentVault` is the custody layer.
contract AgentRegistry is IAgentRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bondToken;
    uint64 public immutable unbondPeriod;

    address public governance;
    address public guardian;
    /// The one contract permitted to mint vaults, and through them to move AUM figures.
    address public vaultFactory;

    /// Vaults the factory has vouched for. Membership, not identity: there is no longer a
    /// single vault address, so authority has to be a set the factory writes and nobody
    /// else can.
    mapping(address => bool) public isVault;

    /// Bond required for each tier, ascending.
    uint256[3] public tierBonds;
    /// AUM ceiling unlocked by each tier, ascending.
    uint256[3] public tierCeilings;

    mapping(address => Builder) internal _builders;
    mapping(bytes32 => Listing) internal _listings;

    event BuilderRegistered(address indexed builder);
    event BondStaked(address indexed builder, uint256 amount, uint8 tier);
    event UnbondRequested(address indexed builder, uint256 amount, uint64 availableAt);
    event BondWithdrawn(address indexed builder, uint256 amount, uint8 tier);
    event BondSlashed(address indexed builder, uint256 amount, uint256 toTraders);
    event ListingSubmitted(bytes32 indexed listingId, address indexed builder, bytes32 metadata);
    event ListingApproved(bytes32 indexed listingId);
    event ListingRejected(bytes32 indexed listingId);
    event ListingSuspended(bytes32 indexed listingId, address indexed by);
    event AgentAuthorityChanged(bytes32 indexed listingId, address indexed next);
    event VaultFactorySet(address indexed factory);
    event VaultRegistered(address indexed vault);
    event GuardianChanged(address indexed previous, address indexed next);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Errors.NotGovernance();
        _;
    }

    modifier onlyGovernanceOrGuardian() {
        if (msg.sender != governance && msg.sender != guardian) revert Errors.NotGuardian();
        _;
    }

    constructor(
        address governance_,
        address guardian_,
        address bondToken_,
        uint256[3] memory tierBonds_,
        uint256[3] memory tierCeilings_,
        uint64 unbondPeriod_
    ) {
        if (governance_ == address(0) || guardian_ == address(0) || bondToken_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (unbondPeriod_ > Constants.MAX_UNBOND_PERIOD) revert Errors.ParameterOutOfBounds();

        governance = governance_;
        guardian = guardian_;
        bondToken = IERC20(bondToken_);
        tierBonds = tierBonds_;
        tierCeilings = tierCeilings_;
        unbondPeriod = unbondPeriod_;
    }

    // ────────────────────────────────────────────────────────── builders

    function registerBuilder() external {
        Builder storage b = _builders[msg.sender];
        if (b.exists) revert Errors.BuilderAlreadyRegistered();

        b.exists = true;
        b.createdAt = uint64(block.timestamp);
        emit BuilderRegistered(msg.sender);
    }

    function stakeBond(uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.ZeroAmount();
        Builder storage b = _builders[msg.sender];
        if (!b.exists) revert Errors.BuilderNotRegistered();

        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        b.bondAmount += amount;
        b.tier = _tierFor(b.bondAmount);

        emit BondStaked(msg.sender, amount, b.tier);
    }

    /// Unbonding is a delay, not a penalty. A builder who wants out gets out; the delay
    /// exists so traders have a window to withdraw before the bond backing their capital
    /// disappears, and so misconduct discovered late still has something to slash.
    function requestUnbond(uint256 amount) external {
        Builder storage b = _builders[msg.sender];
        if (!b.exists) revert Errors.BuilderNotRegistered();
        if (amount == 0) revert Errors.ZeroAmount();
        if (amount > b.bondAmount) revert Errors.UnbondAmountExceedsBond();

        b.unbondAmount = amount;
        b.unbondRequestedAt = uint64(block.timestamp);

        emit UnbondRequested(msg.sender, amount, uint64(block.timestamp) + unbondPeriod);
    }

    function withdrawBond() external nonReentrant {
        Builder storage b = _builders[msg.sender];
        if (b.unbondRequestedAt == 0) revert Errors.NoUnbondRequested();
        if (block.timestamp < b.unbondRequestedAt + unbondPeriod) {
            revert Errors.UnbondPeriodNotElapsed();
        }

        uint256 amount = b.unbondAmount;
        if (amount > b.bondAmount) amount = b.bondAmount;

        // The bond must still cover capital under management after the withdrawal.
        // Traders exit first, then the builder unwinds — not the other way round.
        uint256 remaining = b.bondAmount - amount;
        if (_ceilingFor(_tierFor(remaining)) < b.totalAum) revert Errors.BondBelowAumCoverage();

        b.bondAmount = remaining;
        b.tier = _tierFor(remaining);
        b.unbondAmount = 0;
        b.unbondRequestedAt = 0;

        bondToken.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount, b.tier);
    }

    /// Slashing is governance-executed, not automatic.
    ///
    /// Being honest about what that means: a bond deters, it does not make fraud
    /// impossible, and the decision to slash is a human one made by whoever holds the
    /// multisig. Anyone told otherwise is being sold something.
    function slashBond(address builder, uint256 amount, address traderRecipient)
        external
        onlyGovernance
        nonReentrant
    {
        Builder storage b = _builders[builder];
        if (!b.exists) revert Errors.BuilderNotRegistered();
        if (amount > b.bondAmount) revert Errors.UnbondAmountExceedsBond();
        if (traderRecipient == address(0)) revert Errors.ZeroAddress();

        b.bondAmount -= amount;
        b.tier = _tierFor(b.bondAmount);
        b.slashCount += 1;

        uint256 toTraders = (amount * Constants.SLASH_TRADER_BPS) / Constants.BPS;
        bondToken.safeTransfer(traderRecipient, toTraders);
        bondToken.safeTransfer(governance, amount - toTraders);

        emit BondSlashed(builder, amount, toTraders);
    }

    // ────────────────────────────────────────────────────────── listings

    function listingId(address builder, uint16 index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(builder, index));
    }

    /// Fees are deliberately left at zero here and only set on approval. A listing that
    /// never passes vetting must never carry live economics.
    function submitListing(address agentAuthority, bytes32 metadataHash)
        external
        returns (bytes32 id)
    {
        Builder storage b = _builders[msg.sender];
        if (!b.exists) revert Errors.BuilderNotRegistered();
        if (agentAuthority == address(0)) revert Errors.ZeroAddress();

        id = listingId(msg.sender, b.agentCount);
        b.agentCount += 1;

        _listings[id] = Listing({
            builder: msg.sender,
            agentAuthority: agentAuthority,
            status: ListingStatus.Vetting,
            performanceFeeBps: 0,
            builderSplitBps: 0,
            positionCapBps: 0,
            maxDrawdownBps: 0,
            submittedAt: uint64(block.timestamp),
            metadataHash: metadataHash
        });

        emit ListingSubmitted(id, msg.sender, metadataHash);
    }

    function approveListing(
        bytes32 id,
        uint16 performanceFeeBps,
        uint16 builderSplitBps,
        uint16 positionCapBps,
        uint16 maxDrawdownBps
    ) external onlyGovernance {
        _approveListing(id, performanceFeeBps, builderSplitBps, positionCapBps, maxDrawdownBps);
    }

    /// Approve with the locked launch parameters. The common path.
    function approveListingAtLaunchTerms(bytes32 id) external onlyGovernance {
        _approveListing(
            id,
            Constants.DEFAULT_PERFORMANCE_FEE_BPS,
            Constants.DEFAULT_BUILDER_SPLIT_BPS,
            Constants.DEFAULT_POSITION_CAP_BPS,
            Constants.DEFAULT_MAX_DRAWDOWN_BPS
        );
    }

    function _approveListing(
        bytes32 id,
        uint16 performanceFeeBps,
        uint16 builderSplitBps,
        uint16 positionCapBps,
        uint16 maxDrawdownBps
    ) internal {
        Listing storage l = _listings[id];
        if (l.status != ListingStatus.Vetting) revert Errors.ListingNotVetting();

        if (
            performanceFeeBps > Constants.MAX_PERFORMANCE_FEE_BPS
                || builderSplitBps < Constants.MIN_BUILDER_SPLIT_BPS
                || builderSplitBps > Constants.BPS || positionCapBps == 0
                || positionCapBps > Constants.MAX_POSITION_CAP_BPS || maxDrawdownBps == 0
                || maxDrawdownBps > Constants.MAX_DRAWDOWN_BPS_CEILING
        ) revert Errors.ParameterOutOfBounds();

        l.performanceFeeBps = performanceFeeBps;
        l.builderSplitBps = builderSplitBps;
        l.positionCapBps = positionCapBps;
        l.maxDrawdownBps = maxDrawdownBps;
        l.status = ListingStatus.Live;

        emit ListingApproved(id);
    }

    function rejectListing(bytes32 id) external onlyGovernance {
        Listing storage l = _listings[id];
        if (l.status != ListingStatus.Vetting) revert Errors.ListingNotVetting();
        l.status = ListingStatus.Rejected;
        emit ListingRejected(id);
    }

    /// Either key may suspend. Suspension stops new trades immediately; it does not
    /// touch trader funds, which remain withdrawable by their owners throughout.
    function suspendListing(bytes32 id) external onlyGovernanceOrGuardian {
        Listing storage l = _listings[id];
        if (l.status == ListingStatus.None) revert Errors.ListingNotFound();
        l.status = ListingStatus.Suspended;
        emit ListingSuspended(id, msg.sender);
    }

    /// A builder rotating a compromised agent key must not have to re-run vetting.
    function setAgentAuthority(bytes32 id, address next) external {
        Listing storage l = _listings[id];
        if (l.builder != msg.sender) revert Errors.NotBuilder();
        if (next == address(0)) revert Errors.ZeroAddress();
        l.agentAuthority = next;
        emit AgentAuthorityChanged(id, next);
    }

    // ────────────────────────────────────────────────────────── AUM

    function notifyAumDelta(bytes32 id, int256 delta) external {
        if (!isVault[msg.sender]) revert Errors.NotVault();
        Listing storage l = _listings[id];
        if (l.status == ListingStatus.None) revert Errors.ListingNotFound();

        Builder storage b = _builders[l.builder];
        if (delta >= 0) {
            uint256 add = uint256(delta);
            if (b.totalAum + add > _ceilingFor(b.tier)) revert Errors.AumCeilingExceeded();
            b.totalAum += add;
        } else {
            uint256 sub = uint256(-delta);
            b.totalAum = sub >= b.totalAum ? 0 : b.totalAum - sub;
        }
    }

    function availableAumHeadroom(bytes32 id) external view returns (uint256) {
        Listing storage l = _listings[id];
        if (l.status == ListingStatus.None) return 0;

        Builder storage b = _builders[l.builder];
        uint256 ceiling = _ceilingFor(b.tier);
        return ceiling > b.totalAum ? ceiling - b.totalAum : 0;
    }

    // ────────────────────────────────────────────────────────── governance

    /// One-shot, for the same reason it always was: whatever can move AUM figures can
    /// mint headroom out of nothing, so a compromised governance key must not be able to
    /// re-point it. What changed is only what gets trusted. There is no longer a single
    /// vault to name — vaults are per trader and per listing now — so governance trusts
    /// one factory, and the factory vouches for the vaults it deploys.
    ///
    /// The trust is no wider than before. A factory that could be made to vouch for an
    /// arbitrary address would be exactly as dangerous as a re-settable vault, which is
    /// why `registerVault` is callable by nobody else and the factory only ever calls it
    /// for a clone it has just created itself.
    function setVaultFactory(address factory) external onlyGovernance {
        if (vaultFactory != address(0)) revert Errors.AlreadySet();
        if (factory == address(0)) revert Errors.ZeroAddress();
        vaultFactory = factory;
        emit VaultFactorySet(factory);
    }

    /// Called by the factory as it deploys a vault, and by nothing else.
    function registerVault(address vault_) external {
        if (msg.sender != vaultFactory) revert Errors.NotVaultFactory();
        if (vault_ == address(0)) revert Errors.ZeroAddress();
        if (isVault[vault_]) revert Errors.AlreadySet();
        isVault[vault_] = true;
        emit VaultRegistered(vault_);
    }

    function setGuardian(address next) external onlyGovernance {
        if (next == address(0)) revert Errors.ZeroAddress();
        emit GuardianChanged(guardian, next);
        guardian = next;
    }

    // ────────────────────────────────────────────────────────── views

    function getListing(bytes32 id) external view returns (Listing memory) {
        return _listings[id];
    }

    function getBuilder(address builder) external view returns (Builder memory) {
        return _builders[builder];
    }

    function aumCeiling(address builder) external view returns (uint256) {
        return _ceilingFor(_builders[builder].tier);
    }

    /// Tier is the count of bond thresholds met: 0 means unbonded and unable to take
    /// capital at all.
    function _tierFor(uint256 bond) internal view returns (uint8 tier) {
        for (uint256 i; i < 3; ++i) {
            if (bond >= tierBonds[i]) tier = uint8(i + 1);
        }
    }

    function _ceilingFor(uint8 tier) internal view returns (uint256) {
        return tier == 0 ? 0 : tierCeilings[tier - 1];
    }
}
