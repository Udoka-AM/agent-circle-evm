// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { IAgentRegistry } from "../src/interfaces/IAgentRegistry.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import {
    MockVenueAdapter,
    GreedyVenueAdapter,
    BookVenueAdapter
} from "./mocks/MockVenueAdapter.sol";

/// The two halves of the answer to the settlement problem: reserving an order's worst
/// case before it is signed, and being able to leave a position without anybody's help.
///
/// Position cap here is 12% of a 10,000 vault — 1,200 per position.
contract ReservationsTest is Test {
    AgentRegistry registry;
    AgentVault vault;
    VenueWhitelist whitelist;
    MockERC20 usdc;
    MockERC20 agentToken;
    MockVenueAdapter venue;

    address governance = makeAddr("governance");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address builder = makeAddr("builder");
    address agent = makeAddr("agent");
    address trader = makeAddr("trader");
    address attacker = makeAddr("attacker");

    uint256 constant UNIT = 1e6;
    bytes32 listingId;
    bytes32 id;

    bytes32 constant ORDER_A = keccak256("order-a");
    bytes32 constant ORDER_B = keccak256("order-b");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        agentToken = new MockERC20("Agent", "AGENT", 6);

        registry = new AgentRegistry(
            governance,
            guardian,
            address(agentToken),
            [uint256(25_000 * UNIT), 100_000 * UNIT, 400_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            14 days
        );
        whitelist = new VenueWhitelist(governance, guardian, Constants.VENUE_TIMELOCK_DELAY);
        vault = new AgentVault(address(usdc), address(registry), address(whitelist), treasury);
        venue = new MockVenueAdapter(address(usdc));

        vm.prank(governance);
        registry.setVault(address(vault));

        agentToken.mint(builder, 25_000 * UNIT);
        vm.startPrank(builder);
        agentToken.approve(address(registry), type(uint256).max);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        listingId = registry.submitListing(agent, keccak256("m"));
        vm.stopPrank();

        vm.startPrank(governance);
        registry.approveListingAtLaunchTerms(listingId);
        whitelist.queueAddition(address(venue));
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        whitelist.executeAddition(address(venue));
        vm.stopPrank();

        usdc.mint(trader, 100_000 * UNIT);
        vm.startPrank(trader);
        usdc.approve(address(vault), type(uint256).max);
        id = vault.openVault(listingId, 0, 0);
        vault.deposit(id, 10_000 * UNIT);
        vm.stopPrank();
    }

    function _authorise(bytes32 orderHash, uint256 maxCost) internal {
        vm.prank(agent);
        vault.authoriseOrder(
            id, address(venue), orderHash, maxCost, uint64(block.timestamp + 10 minutes)
        );
    }

    function _reserved() internal view returns (uint256 r) {
        (,,, r,,,,,,,,) = vault.vaults(id);
    }

    // ─────────────────────────────────── reservation accounting

    function test_authorisingReservesWithoutMovingMoney() public {
        uint256 heldBefore = usdc.balanceOf(address(vault));
        _authorise(ORDER_A, 1_000 * UNIT);

        assertEq(_reserved(), 1_000 * UNIT);
        assertEq(usdc.balanceOf(address(vault)), heldBefore, "authorisation must not move money");
        assertEq(vault.availableIdle(id), 9_000 * UNIT);
        assertTrue(vault.isOrderAuthorised(ORDER_A));
    }

    /// The reason reservations exist. Two orders that each pass the 12% cap alone would
    /// breach it together, and only accounting for the outstanding one catches that.
    function test_ordersThatPassAloneCannotStackPastTheCap() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.authoriseOrder(
            id, address(venue), ORDER_B, 1_000 * UNIT, uint64(block.timestamp + 10 minutes)
        );
    }

    /// An outstanding order is counted as though it had already filled, so it constrains
    /// an atomic trade on the same vault too. The two paths share one budget.
    function test_reservationConstrainsAtomicTradesAsWell() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.executeTrade(
            id, address(venue), 1_000 * UNIT, abi.encode(id, uint256(1_000 * UNIT), 1_000 * UNIT)
        );
    }

    // ─────────────────────────────────── allowance mirroring

    /// The reservation is mirrored by an allowance to whoever settles, because that is the
    /// only lever the vault holds that a venue cannot cache. Polymarket's V2 exchange lets
    /// an operator preapprove an order and then skip asking the vault ever again; it
    /// cannot skip the token's own allowance check.
    function test_authorisationMirrorsReservationAsAllowance() public {
        assertEq(usdc.allowance(address(vault), address(venue)), 0);

        _authorise(ORDER_A, 1_000 * UNIT);

        assertEq(usdc.allowance(address(vault), address(venue)), 1_000 * UNIT);
        assertEq(vault.reservedBySpender(address(venue)), 1_000 * UNIT);
    }

    /// Cancelling makes a stale order genuinely unsettleable, not merely disowned. Without
    /// this, a preapproved order could still be pulled long after the vault would have
    /// refused it.
    function test_cancellingRevokesTheAllowance() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(trader);
        vault.cancelOrder(ORDER_A);

        assertEq(usdc.allowance(address(vault), address(venue)), 0, "revoked, not just refused");
        assertEq(vault.reservedBySpender(address(venue)), 0);
    }

    function test_expiryRevokesTheAllowance() public {
        _authorise(ORDER_A, 1_000 * UNIT);
        vm.warp(block.timestamp + 11 minutes);

        vm.prank(attacker);
        vault.releaseExpiredOrder(ORDER_A);
        assertEq(usdc.allowance(address(vault), address(venue)), 0);
    }

    function test_allowanceAggregatesAcrossOrders() public {
        _authorise(ORDER_A, 500 * UNIT);
        _authorise(ORDER_B, 400 * UNIT);
        assertEq(usdc.allowance(address(vault), address(venue)), 900 * UNIT);

        vm.prank(agent);
        vault.cancelOrder(ORDER_A);
        assertEq(usdc.allowance(address(vault), address(venue)), 400 * UNIT, "only A's share goes");
    }

    /// On an order-book venue the adapter is not what pulls the money — the exchange is,
    /// and the adapter is not even in the room at settlement. The allowance has to follow
    /// the address that actually settles.
    function test_allowanceFollowsTheSettlementSpenderNotTheAdapter() public {
        address exchange = makeAddr("exchange");
        BookVenueAdapter book = new BookVenueAdapter(address(usdc), exchange);

        vm.startPrank(governance);
        whitelist.queueAddition(address(book));
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        whitelist.executeAddition(address(book));
        vm.stopPrank();

        vm.prank(agent);
        vault.authoriseOrder(
            id, address(book), ORDER_A, 1_000 * UNIT, uint64(block.timestamp + 10 minutes)
        );

        assertEq(usdc.allowance(address(vault), exchange), 1_000 * UNIT, "exchange may pull");
        assertEq(usdc.allowance(address(vault), address(book)), 0, "adapter may not");
    }

    /// An atomic adapter is its own settlement spender, so the temporary allowance a trade
    /// grants must fall back to the standing mirror rather than to zero — otherwise a
    /// trade would silently revoke every order already authorised against that venue.
    function test_tradeRestoresRatherThanWipesTheStandingAllowance() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(agent);
        vault.executeTrade(
            id, address(venue), 200 * UNIT, abi.encode(id, uint256(200 * UNIT), 200 * UNIT)
        );

        assertEq(
            usdc.allowance(address(vault), address(venue)),
            1_000 * UNIT,
            "outstanding order still backed"
        );
    }

    // ─────────────────────────────────── bounding the reservation

    /// There is no floor on an order's size, so without a bound on the count an agent
    /// could bury a trader's capital under thousands of one-wei reservations and make the
    /// withdrawal gate expensive to lift. The cap is what keeps clearing them affordable.
    function test_openOrdersAreBounded() public {
        for (uint256 i; i < Constants.MAX_OPEN_ORDERS; ++i) {
            _authorise(keccak256(abi.encode("spam", i)), 1);
        }

        vm.prank(agent);
        vm.expectRevert(Errors.TooManyOpenOrders.selector);
        vault.authoriseOrder(id, address(venue), ORDER_B, 1, uint64(block.timestamp + 10 minutes));
    }

    /// Cancelling frees a slot, so the bound throttles concurrency rather than capping
    /// how much an agent may ever trade.
    function test_cancellingFreesAnOrderSlot() public {
        for (uint256 i; i < Constants.MAX_OPEN_ORDERS; ++i) {
            _authorise(keccak256(abi.encode("spam", i)), 1);
        }

        vm.prank(agent);
        vault.cancelOrder(keccak256(abi.encode("spam", uint256(0))));

        _authorise(ORDER_B, 1);
        assertEq(_reserved(), uint256(Constants.MAX_OPEN_ORDERS));
    }

    /// The trader's route back to their own money must not get longer the more orders the
    /// agent has open. Whatever the agent has been doing, one transaction clears it.
    function test_traderClearsEveryReservationInOneTransaction() public {
        bytes32[] memory hashes = new bytes32[](Constants.MAX_OPEN_ORDERS);
        for (uint256 i; i < Constants.MAX_OPEN_ORDERS; ++i) {
            hashes[i] = keccak256(abi.encode("spam", i));
            _authorise(hashes[i], 1_000 * UNIT / Constants.MAX_OPEN_ORDERS);
        }
        assertGt(_reserved(), 0);

        vm.startPrank(trader);
        vault.cancelOrders(hashes);
        vault.withdraw(id, 10_000 * UNIT);
        vm.stopPrank();

        assertEq(_reserved(), 0);
        assertEq(usdc.allowance(address(vault), address(venue)), 0, "and the allowance with it");
        assertEq(usdc.balanceOf(trader), 100_000 * UNIT, "trader is whole again");
    }

    function test_batchCancelRejectsAStranger() public {
        _authorise(ORDER_A, 1_000 * UNIT);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = ORDER_A;

        vm.prank(attacker);
        vm.expectRevert(Errors.NotTraderOrAgent.selector);
        vault.cancelOrders(hashes);
    }

    function test_onlyAgentAuthorityCanAuthorise() public {
        uint64 exp = uint64(block.timestamp + 10 minutes);

        vm.prank(trader);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.authoriseOrder(id, address(venue), ORDER_A, 100 * UNIT, exp);

        vm.prank(attacker);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.authoriseOrder(id, address(venue), ORDER_A, 100 * UNIT, exp);
    }

    function test_orderMustNameAWhitelistedVenueAndABoundedLifetime() public {
        vm.startPrank(agent);

        vm.expectRevert(Errors.VenueNotWhitelisted.selector);
        vault.authoriseOrder(
            id, attacker, ORDER_A, 100 * UNIT, uint64(block.timestamp + 10 minutes)
        );

        vm.expectRevert(Errors.OrderLifetimeTooLong.selector);
        vault.authoriseOrder(
            id,
            address(venue),
            ORDER_A,
            100 * UNIT,
            uint64(block.timestamp + Constants.MAX_ORDER_LIFETIME + 1)
        );

        vm.expectRevert(Errors.OrderExpired.selector);
        vault.authoriseOrder(id, address(venue), ORDER_A, 100 * UNIT, uint64(block.timestamp));

        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.authoriseOrder(id, address(venue), ORDER_A, 0, uint64(block.timestamp + 10 minutes));
        vm.stopPrank();
    }

    function test_orderHashCannotBeReused() public {
        _authorise(ORDER_A, 100 * UNIT);

        vm.prank(agent);
        vm.expectRevert(Errors.OrderAlreadyExists.selector);
        vault.authoriseOrder(
            id, address(venue), ORDER_A, 100 * UNIT, uint64(block.timestamp + 10 minutes)
        );
    }

    // ─────────────────────────────────── releasing a reservation

    function test_eitherPartyCanCancelButNobodyElse() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(attacker);
        vm.expectRevert(Errors.NotTraderOrAgent.selector);
        vault.cancelOrder(ORDER_A);

        vm.prank(trader);
        vault.cancelOrder(ORDER_A);

        assertEq(_reserved(), 0);
        assertFalse(vault.isOrderAuthorised(ORDER_A));
    }

    function test_agentCanCancelItsOwnOrder() public {
        _authorise(ORDER_A, 1_000 * UNIT);
        vm.prank(agent);
        vault.cancelOrder(ORDER_A);
        assertEq(_reserved(), 0);
    }

    function test_expiredReservationIsReleasableByAnyone() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.expectRevert(Errors.OrderNotExpired.selector);
        vault.releaseExpiredOrder(ORDER_A);

        vm.warp(block.timestamp + 11 minutes);
        assertFalse(vault.isOrderAuthorised(ORDER_A), "expired orders cannot settle");

        vm.prank(attacker);
        vault.releaseExpiredOrder(ORDER_A);
        assertEq(_reserved(), 0);

        // And the capital is usable again.
        _authorise(ORDER_B, 1_000 * UNIT);
        assertEq(_reserved(), 1_000 * UNIT);
    }

    function test_cannotReleaseTwice() public {
        _authorise(ORDER_A, 1_000 * UNIT);
        vm.prank(trader);
        vault.cancelOrder(ORDER_A);

        vm.prank(trader);
        vm.expectRevert(Errors.OrderNotFound.selector);
        vault.cancelOrder(ORDER_A);
    }

    function test_unknownOrderIsNotAuthorised() public view {
        assertFalse(vault.isOrderAuthorised(keccak256("never-authorised")));
    }

    // ─────────────────────── settlement-time re-checks against live state

    /// The point of re-checking at settlement rather than only at signing: everything
    /// below happened after the order was authorised and each one alone stops it.

    function test_pausingTheVaultStopsAnOutstandingOrder() public {
        _authorise(ORDER_A, 1_000 * UNIT);
        assertTrue(vault.isOrderAuthorised(ORDER_A));

        vm.prank(trader);
        vault.pauseVault(id);
        assertFalse(vault.isOrderAuthorised(ORDER_A));

        vm.prank(trader);
        vault.resumeVault(id);
        assertTrue(vault.isOrderAuthorised(ORDER_A));
    }

    /// A reservation gates a withdrawal, because it is backed by a real allowance the
    /// settlement spender can act on. See CrossVaultIsolation.t.sol for what goes wrong
    /// without this. The trader is not trapped: cancelling is theirs to do alone.
    function test_reservedCapitalIsNotWithdrawable() public {
        _authorise(ORDER_A, 1_000 * UNIT);
        assertEq(vault.availableIdle(id), 9_000 * UNIT);

        vm.prank(trader);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.withdraw(id, 9_500 * UNIT);

        vm.prank(trader);
        vault.withdraw(id, 9_000 * UNIT);

        // What must hold is that the standing allowance is still fully backed by tokens
        // this vault actually owns — never by another vault's balance.
        assertEq(vault.availableIdle(id), 0);
        assertEq(usdc.allowance(address(vault), address(venue)), 1_000 * UNIT);
        assertEq(_reserved(), 1_000 * UNIT, "allowance and backing move together");

        // The order itself is now outside the position cap, because the trader shrank the
        // vault around it — so it is refused at settlement too. Both guards, independently.
        assertFalse(vault.isOrderAuthorised(ORDER_A));
    }

    function test_suspendingTheListingStopsAnOutstandingOrder() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(guardian);
        registry.suspendListing(listingId);
        assertFalse(vault.isOrderAuthorised(ORDER_A));
    }

    function test_removingTheVenueStopsAnOutstandingOrder() public {
        _authorise(ORDER_A, 1_000 * UNIT);

        vm.prank(guardian);
        whitelist.removeVenue(address(venue));
        assertFalse(vault.isOrderAuthorised(ORDER_A));
    }

    /// The position moving against the vault after signing also unauthorises the order,
    /// because the cap is re-evaluated against live marks rather than the marks that
    /// happened to hold at signing time.
    function test_positionGrowingPastTheCapStopsAnOutstandingOrder() public {
        _authorise(ORDER_A, 600 * UNIT);
        assertTrue(vault.isOrderAuthorised(ORDER_A));

        vm.prank(agent);
        vault.executeTrade(
            id, address(venue), 600 * UNIT, abi.encode(id, uint256(600 * UNIT), 600 * UNIT)
        );

        venue.setPositionValue(id, 1_400 * UNIT);
        assertFalse(vault.isOrderAuthorised(ORDER_A));
    }

    // ─────────────────────────────────── permission-free exit

    function _openPosition(uint256 spend) internal {
        vm.prank(agent);
        vault.executeTrade(id, address(venue), spend, abi.encode(id, spend, spend));
    }

    function test_traderCanExitWithoutTheAgent() public {
        _openPosition(1_000 * UNIT);
        usdc.mint(address(venue), 1_000 * UNIT); // counterparty side of the payout

        vm.prank(trader);
        uint256 proceeds = vault.exitPosition(id, address(venue), abi.encode(uint256(10_000)));

        assertEq(proceeds, 1_000 * UNIT);
        assertEq(vault.totalValue(id), 10_000 * UNIT);
    }

    function test_exitWorksWhileTheVaultIsPaused() public {
        _openPosition(1_000 * UNIT);
        usdc.mint(address(venue), 1_000 * UNIT);

        vm.prank(trader);
        vault.pauseVault(id);

        vm.prank(trader);
        vault.exitPosition(id, address(venue), abi.encode(uint256(10_000)));
        assertEq(vault.totalValue(id), 10_000 * UNIT);
    }

    /// Governance removing a venue must stop new money going in without stranding money
    /// already there.
    function test_exitWorksAfterTheVenueIsDeWhitelisted() public {
        _openPosition(1_000 * UNIT);
        usdc.mint(address(venue), 1_000 * UNIT);

        vm.prank(guardian);
        whitelist.removeVenue(address(venue));

        vm.prank(agent);
        vm.expectRevert(Errors.VenueNotWhitelisted.selector);
        vault.executeTrade(id, address(venue), 1, abi.encode(id, uint256(1), uint256(1)));

        vm.prank(trader);
        vault.exitPosition(id, address(venue), abi.encode(uint256(10_000)));
        assertEq(vault.totalValue(id), 10_000 * UNIT);
    }

    /// A vault that auto-paused into a drawdown is the one that most needs to get out,
    /// and exiting must not be blocked by the cap it is already over.
    function test_exitIsNotBlockedByAnAlreadyBreachedCap() public {
        _openPosition(1_000 * UNIT);
        venue.setPositionValue(id, 5_000 * UNIT); // far past the 12% cap
        usdc.mint(address(venue), 5_000 * UNIT);

        vm.prank(trader);
        uint256 proceeds = vault.exitPosition(id, address(venue), abi.encode(uint256(10_000)));
        assertEq(proceeds, 5_000 * UNIT);
    }

    function test_partialExitCreditsOnlyWhatArrived() public {
        _openPosition(1_000 * UNIT);
        usdc.mint(address(venue), 1_000 * UNIT);

        vm.prank(agent);
        uint256 proceeds = vault.exitPosition(id, address(venue), abi.encode(uint256(4_000)));

        assertEq(proceeds, 400 * UNIT);
        assertEq(vault.availableIdle(id), 9_400 * UNIT);
    }

    function test_onlyTraderOrAgentCanExit() public {
        _openPosition(1_000 * UNIT);

        vm.prank(attacker);
        vm.expectRevert(Errors.NotTraderOrAgent.selector);
        vault.exitPosition(id, address(venue), abi.encode(uint256(10_000)));
    }

    /// An "exit" that costs the vault money is not an exit. No allowance is granted on
    /// this path, so a greedy adapter cannot pull at all.
    function test_exitGrantsNoAllowanceToTheAdapter() public {
        GreedyVenueAdapter greedy = new GreedyVenueAdapter(address(usdc));
        vm.startPrank(governance);
        whitelist.queueAddition(address(greedy));
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        whitelist.executeAddition(address(greedy));
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert();
        vault.exitPosition(id, address(greedy), abi.encode(uint256(1_000 * UNIT)));

        assertEq(vault.availableIdle(id), 10_000 * UNIT);
    }

    /// Exiting is permissive about *which* venue, but not unboundedly so: a contract this
    /// vault never traded through is not an exit route. Otherwise the call would be a way
    /// to attach an arbitrary position-value reporter to the vault for good, inflating
    /// what the vault appears to be worth and what a builder can bill against it.
    function test_exitCannotIntroduceAnUntouchedNonWhitelistedVenue() public {
        MockVenueAdapter liar = new MockVenueAdapter(address(usdc));
        liar.setPositionValue(id, 1_000_000 * UNIT);

        vm.prank(trader);
        vm.expectRevert(Errors.VenueNotWhitelisted.selector);
        vault.exitPosition(id, address(liar), abi.encode(uint256(10_000)));

        assertEq(vault.totalValue(id), 10_000 * UNIT, "vault value must be unaffected");
    }

    function test_exitOnUnknownVaultReverts() public {
        vm.prank(trader);
        vm.expectRevert(Errors.VaultNotFound.selector);
        vault.exitPosition(keccak256("nope"), address(venue), abi.encode(uint256(10_000)));
    }
}
