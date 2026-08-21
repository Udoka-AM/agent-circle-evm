// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { Errors } from "../src/libraries/Errors.sol";

/// The Drift lesson, encoded: a compromised governance key must buy the attacker an
/// announcement, not the funds.
contract VenueWhitelistTest is Test {
    VenueWhitelist wl;

    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address attacker = makeAddr("attacker");
    address venue = makeAddr("venue");

    uint64 constant DELAY = 2 days;

    function setUp() public {
        wl = new VenueWhitelist(governance, guardian, DELAY);
    }

    function test_additionCannotSkipTimelock() public {
        vm.startPrank(governance);
        wl.queueAddition(venue);
        vm.expectRevert(Errors.TimelockNotElapsed.selector);
        wl.executeAddition(venue);
        vm.stopPrank();

        assertFalse(wl.isWhitelisted(venue));
    }

    function test_additionSucceedsAfterDelay() public {
        vm.startPrank(governance);
        wl.queueAddition(venue);
        vm.warp(block.timestamp + DELAY);
        wl.executeAddition(venue);
        vm.stopPrank();

        assertTrue(wl.isWhitelisted(venue));
    }

    function test_guardianCanVetoQueuedAddition() public {
        vm.prank(governance);
        wl.queueAddition(venue);

        vm.prank(guardian);
        wl.vetoAddition(venue);

        vm.warp(block.timestamp + DELAY);
        vm.prank(governance);
        vm.expectRevert(Errors.ProposalVetoed.selector);
        wl.executeAddition(venue);
    }

    /// The asymmetry that matters: the emergency key can only ever shrink the surface.
    function test_guardianCannotAdd() public {
        vm.startPrank(guardian);
        vm.expectRevert(Errors.NotGovernance.selector);
        wl.queueAddition(venue);
        vm.expectRevert(Errors.NotGovernance.selector);
        wl.executeAddition(venue);
        vm.stopPrank();
    }

    function test_removalIsImmediate() public {
        vm.startPrank(governance);
        wl.queueAddition(venue);
        vm.warp(block.timestamp + DELAY);
        wl.executeAddition(venue);
        vm.stopPrank();
        assertTrue(wl.isWhitelisted(venue));

        // No delay: waiting out a timelock to stop an active exploit is the wrong trade.
        vm.prank(guardian);
        wl.removeVenue(venue);
        assertFalse(wl.isWhitelisted(venue));
    }

    function test_executeRequiresAQueuedProposal() public {
        vm.prank(governance);
        vm.expectRevert(Errors.TimelockNotQueued.selector);
        wl.executeAddition(venue);
    }

    function test_attackerCannotQueueOrRemove() public {
        vm.startPrank(attacker);
        vm.expectRevert(Errors.NotGovernance.selector);
        wl.queueAddition(venue);
        vm.expectRevert(Errors.NotGuardian.selector);
        wl.removeVenue(venue);
        vm.stopPrank();
    }

    function test_guardianRotationIsImmediate() public {
        address next = makeAddr("nextGuardian");
        vm.prank(governance);
        wl.setGuardian(next);
        assertEq(wl.guardian(), next);

        vm.prank(guardian);
        vm.expectRevert(Errors.NotGuardian.selector);
        wl.removeVenue(venue);
    }
}
