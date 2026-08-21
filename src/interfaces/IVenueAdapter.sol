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

    /// Mark-to-market value of all positions this adapter holds for `vaultId`, in
    /// quote-token units. Cost basis is not acceptable — the position cap and drawdown
    /// checks are only as honest as this number.
    function positionValue(address vault, bytes32 vaultId) external view returns (uint256);

    function quoteToken() external view returns (address);
}
