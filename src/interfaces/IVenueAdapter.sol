// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// One adapter per prediction-market venue.
///
/// The vault depends only on this interface. That matters more here than it usually
/// would, because how a Polymarket trade actually settles is the largest unresolved
/// question on this route — see README §4. An adapter that merely *queues* an order
/// cannot satisfy the vault's guarantees and must not be whitelisted.
interface IVenueAdapter {
    /// Execute a trade for `vault`. Implementations pull quote tokens via
    /// `transferFrom` against the allowance the vault grants for this call, and must
    /// leave no residual allowance behaviour the vault has to clean up twice.
    ///
    /// MUST be atomic: either the position is open when this returns, or it reverts.
    function execute(address vault, bytes calldata data) external returns (bytes memory);

    /// Leave a position and return quote tokens to `vault`, without any third party's
    /// cooperation.
    ///
    /// This is the escape hatch, and it is deliberately the one path with no operator in
    /// it. Entering a position may need an order book and therefore somebody else's
    /// process; leaving one must not. On a conditional-token venue both cases this covers
    /// — merging complementary outcome shares back into collateral, and redeeming a
    /// resolved market's payout — are direct contract calls, so an adapter that can only
    /// exit by resting an order on a book does not satisfy this and must not be
    /// whitelisted.
    ///
    /// MUST NOT take quote tokens from `vault`: the vault grants no allowance for this
    /// call and rejects any result where its balance fell. Returns the quote tokens
    /// actually delivered, which the vault verifies against its own balance rather than
    /// trusting.
    function exit(address vault, bytes32 vaultId, bytes calldata data)
        external
        returns (uint256 proceeds);

    /// The address that will actually pull quote tokens out of the vault when an order
    /// authorised for this venue settles.
    ///
    /// For a venue that settles atomically this is the adapter itself. For an order-book
    /// venue it is the exchange, because the adapter is not in the room when the trade
    /// settles — somebody else's operator is.
    ///
    /// The vault mirrors every reservation with an allowance to exactly this address, so
    /// what this returns is a spending permission over trader capital. It MUST be
    /// constant for the lifetime of the adapter: the vault pins it when an order is
    /// authorised and revokes against the pinned value, and an adapter that changed its
    /// answer mid-flight would strand allowances it had already been granted.
    function settlementSpender() external view returns (address);

    /// Mark-to-market value of all positions this adapter holds for `vaultId`, in
    /// quote-token units. Cost basis is not acceptable — the position cap and drawdown
    /// checks are only as honest as this number.
    function positionValue(address vault, bytes32 vaultId) external view returns (uint256);

    function quoteToken() external view returns (address);
}
