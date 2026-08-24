// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IAgentRegistry {
    enum ListingStatus {
        None,
        Vetting,
        Live,
        Rejected,
        Suspended,
        Delisted
    }

    struct Listing {
        address builder;
        address agentAuthority;
        ListingStatus status;
        uint16 performanceFeeBps;
        uint16 builderSplitBps;
        uint16 positionCapBps;
        uint16 maxDrawdownBps;
        uint64 submittedAt;
        bytes32 metadataHash;
    }

    struct Builder {
        uint256 bondAmount;
        uint256 totalAum;
        uint256 unbondAmount;
        uint64 unbondRequestedAt;
        uint64 createdAt;
        uint16 slashCount;
        uint16 agentCount;
        uint8 tier;
        bool exists;
    }

    function getListing(bytes32 listingId) external view returns (Listing memory);
    function getBuilder(address builder) external view returns (Builder memory);

    /// Remaining headroom under the builder's tier ceiling, in quote-token units.
    function availableAumHeadroom(bytes32 listingId) external view returns (uint256);

    /// Called by the vault on deposit (positive) and withdrawal (negative).
    /// The AUM ceiling is enforced per-*builder* across all their listings, so it cannot
    /// be tracked inside a single vault.
    function notifyAumDelta(bytes32 listingId, int256 delta) external;

    /// Called by the vault factory as it deploys a vault, to vouch for it.
    function registerVault(address vault) external;
}
