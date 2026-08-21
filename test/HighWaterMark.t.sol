// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { HighWaterMark as HWM } from "../src/libraries/HighWaterMark.sol";

/// The variance-farming scenarios the high-water mark exists to prevent. If any of these
/// regress, a builder can extract fees from a trader who ended up flat or down.
contract HighWaterMarkTest is Test {
    using HWM for HWM.State;

    uint16 constant PERF = 1_000; // 10%
    uint16 constant SPLIT = 8_000; // 80/20

    function _s(uint256 bal, uint256 mark) internal pure returns (HWM.State memory) {
        return HWM.State({ balance: bal, highWaterMark: mark });
    }

    function test_noFeeBelowMark() public pure {
        (HWM.State memory s, HWM.FeeSplit memory f) = _s(900e6, 1_000e6).assess(PERF, SPLIT);
        assertEq(f.total, 0);
        assertEq(s.balance, 900e6, "balance must not move when under water");
        assertEq(s.highWaterMark, 1_000e6, "mark must not fall on a loss");
    }

    function test_feeOnProfitOnly() public pure {
        (HWM.State memory s, HWM.FeeSplit memory f) = _s(1_100e6, 1_000e6).assess(PERF, SPLIT);
        assertEq(f.total, 10e6, "10% of 100 profit");
        assertEq(f.builderCut, 8e6);
        assertEq(f.platformCut, 2e6);
        assertEq(s.balance, 1_090e6);
        assertEq(s.highWaterMark, 1_090e6, "mark advances post-fee");
    }

    /// The core property. Up 100, back down, up again must be charged once, not twice.
    function test_varianceCannotBeFarmed() public pure {
        HWM.State memory s = _s(1_000e6, 1_000e6);
        HWM.FeeSplit memory f;

        (s, f) = s.assess(PERF, SPLIT);
        assertEq(f.total, 0, "flat earns nothing");

        s.balance = 1_100e6;
        (s, f) = s.assess(PERF, SPLIT);
        assertEq(f.total, 10e6, "up-swing is billed once");

        s.balance = 1_000e6;
        (s, f) = s.assess(PERF, SPLIT);
        assertEq(f.total, 0, "no fee on the way down");

        s.balance = 1_090e6;
        (s, f) = s.assess(PERF, SPLIT);
        assertEq(f.total, 0, "recovery to the mark is not new profit");
    }

    function test_depositIsNotProfit() public pure {
        HWM.State memory s = _s(1_000e6, 1_000e6).onDeposit(500e6);
        assertEq(s.balance, 1_500e6);
        assertEq(s.highWaterMark, 1_500e6);

        (, HWM.FeeSplit memory f) = s.assess(PERF, SPLIT);
        assertEq(f.total, 0, "fresh capital must never read as profit");
    }

    function test_withdrawalLowersMark() public pure {
        HWM.State memory s = _s(1_000e6, 1_000e6).onWithdraw(400e6);
        assertEq(s.balance, 600e6);
        assertEq(s.highWaterMark, 600e6, "otherwise recovery is never fee-free");
    }

    /// Emptying a vault that is under water leaves the unrecovered loss on the mark.
    /// That carryforward favours the trader: if they come back, the builder must climb
    /// past the old loss before earning again.
    function test_fullWithdrawalUnderWaterLeavesCarryforward() public pure {
        HWM.State memory s = _s(800e6, 1_000e6).onWithdraw(800e6);
        assertEq(s.balance, 0);
        assertEq(s.highWaterMark, 200e6);

        s = s.onDeposit(1_000e6);
        assertEq(s.highWaterMark, 1_200e6, "carryforward survives a fresh deposit");
        (, HWM.FeeSplit memory f) = s.assess(PERF, SPLIT);
        assertEq(f.total, 0, "no fee until the old loss is made back");
    }

    /// The clamp exists for the case where a withdrawal is larger than the mark, which
    /// happens when a vault in profit is emptied. Underflow here would brick the vault.
    function test_withdrawalAboveMarkClampsToZero() public pure {
        HWM.State memory s = _s(800e6, 500e6).onWithdraw(800e6);
        assertEq(s.balance, 0);
        assertEq(s.highWaterMark, 0, "must not underflow");
    }

    function test_drawdownBps() public pure {
        assertEq(HWM.drawdownBps(_s(850e6, 1_000e6)), 1_500);
        assertEq(HWM.drawdownBps(_s(1_200e6, 1_000e6)), 0);
        assertEq(HWM.drawdownBps(_s(0, 0)), 0);
    }

    // ── invariants

    function testFuzz_splitAlwaysSumsToTotal(uint96 balance, uint96 mark) public pure {
        vm.assume(balance > mark);
        (, HWM.FeeSplit memory f) = _s(balance, mark).assess(PERF, SPLIT);
        assertEq(f.builderCut + f.platformCut, f.total);
    }

    function testFuzz_feeNeverExceedsProfit(uint96 balance, uint96 mark) public pure {
        vm.assume(balance > mark);
        (, HWM.FeeSplit memory f) = _s(balance, mark).assess(PERF, SPLIT);
        assertLe(f.total, uint256(balance) - uint256(mark));
    }

    /// Assessing twice in a row must never charge twice.
    function testFuzz_assessIsIdempotent(uint96 balance, uint96 mark) public pure {
        HWM.State memory s = _s(balance, mark);
        HWM.FeeSplit memory second;
        (s,) = s.assess(PERF, SPLIT);
        (, second) = s.assess(PERF, SPLIT);
        assertEq(second.total, 0);
    }

    /// A deposit followed immediately by a withdrawal of the same size must leave the
    /// mark exactly where it started.
    function testFuzz_depositWithdrawRoundTrip(uint96 start, uint96 amount) public pure {
        HWM.State memory s = _s(start, start);
        s = s.onDeposit(amount);
        s = s.onWithdraw(amount);
        assertEq(s.balance, start);
        assertEq(s.highWaterMark, start);
    }
}
