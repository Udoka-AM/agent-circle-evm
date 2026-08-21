// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// Launch parameters, locked. These are the same numbers the Solana implementation runs
/// with; the two must not drift.
library Constants {
    uint256 internal constant BPS = 10_000;

    // ── economics at launch
    uint16 internal constant DEFAULT_LISTING_FEE_BPS = 0;
    uint16 internal constant DEFAULT_PERFORMANCE_FEE_BPS = 1_000; // 10% of profit
    uint16 internal constant DEFAULT_BUILDER_SPLIT_BPS = 8_000; // 80 builder / 20 platform
    uint16 internal constant DEFAULT_POSITION_CAP_BPS = 1_200; // 12% of vault per position
    uint16 internal constant DEFAULT_MAX_DRAWDOWN_BPS = 1_500; // 15% from high-water mark

    /// Share of a slashed bond that goes to harmed traders rather than the treasury.
    uint16 internal constant SLASH_TRADER_BPS = 7_000;

    // ── guardrails governance itself cannot exceed
    //
    // A multisig is a smaller attack surface than a single key, not a safe one. These
    // bounds mean a fully compromised multisig still cannot set a 100% performance fee
    // and drain every vault through the fee path.
    uint16 internal constant MAX_LISTING_FEE_BPS = 500;
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000;
    uint16 internal constant MIN_BUILDER_SPLIT_BPS = 5_000;
    uint16 internal constant MAX_POSITION_CAP_BPS = 2_500;
    uint16 internal constant MAX_DRAWDOWN_BPS_CEILING = 5_000;

    // ── timing
    uint64 internal constant DEFAULT_UNBOND_PERIOD = 14 days;
    uint64 internal constant MAX_UNBOND_PERIOD = 90 days;
    uint64 internal constant FEE_ASSESSMENT_INTERVAL = 7 days;
    uint64 internal constant VENUE_TIMELOCK_DELAY = 2 days;
}
