// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// Shared revert reasons, named to mirror the Anchor `#[error_code]` variants on the
/// Solana implementation so a failure means the same thing on either chain.
library Errors {
    // ── authority
    error NotTrader();
    error NotAgentAuthority();
    error NotBuilder();
    error NotGovernance();
    error NotGuardian();
    error NotVault();
    error NotTraderOrAgent();

    // ── lifecycle
    error VaultNotActive();
    error VaultAlreadyExists();
    error VaultNotFound();
    error BuilderAlreadyRegistered();
    error BuilderNotRegistered();
    error ListingNotFound();
    error ListingNotLive();
    error ListingNotVetting();

    // ── limits
    error AumCeilingExceeded();
    error PositionCapExceeded();
    error DrawdownLimitBreached();
    error RiskOverrideNotStricter();
    error InsufficientBalance();
    error BondBelowAumCoverage();
    error ParameterOutOfBounds();

    // ── bonding
    error NoUnbondRequested();
    error UnbondPeriodNotElapsed();
    error UnbondAmountExceedsBond();

    // ── orders
    error OrderAlreadyExists();
    error OrderNotFound();
    error OrderExpired();
    error OrderNotExpired();
    error OrderLifetimeTooLong();
    error TooManyOpenOrders();

    // ── venue
    error VenueNotWhitelisted();
    error VaultValueDecreasedUnexpectedly();

    // ── fees
    error FeeAssessmentTooSoon();

    // ── governance
    error TimelockNotElapsed();
    error TimelockNotQueued();
    error ProposalVetoed();

    // ── misc
    error ZeroAmount();
    error ZeroAddress();
    error AlreadySet();
}
