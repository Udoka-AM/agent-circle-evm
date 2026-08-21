// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockVenueAdapter } from "./mocks/MockVenueAdapter.sol";

contract CrossVaultIsolationTest is Test {
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
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant UNIT = 1e6;
    bytes32 listingId;

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
    }

    function _open(address who, uint256 amount) internal returns (bytes32 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), type(uint256).max);
        id = vault.openVault(listingId, 0, 0);
        vault.deposit(id, amount);
        vm.stopPrank();
    }

    /// The reason a reservation gates a withdrawal.
    ///
    /// Since reservations are mirrored by a real allowance, a live order is a standing
    /// permission for the settlement spender to pull. This contract pools every vault's
    /// tokens. So if Alice could withdraw the backing while leaving that permission live,
    /// her order would settle out of Bob's balance — and Bob never did anything.
    ///
    /// `isOrderAuthorised` cannot prevent this: a preapproved order never asks it, and the
    /// token does not consult it either. Only refusing the withdrawal does.
    function test_withdrawalCannotLeaveAnAllowanceOverAnotherTradersMoney() public {
        bytes32 aliceId = _open(alice, 10_000 * UNIT);
        bytes32 bobId = _open(bob, 10_000 * UNIT);

        vm.prank(agent);
        vault.authoriseOrder(
            aliceId,
            address(venue),
            keccak256("o"),
            1_000 * UNIT,
            uint64(block.timestamp + 10 minutes)
        );

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.withdraw(aliceId, 10_000 * UNIT);

        // Everything not backing the order is still hers, immediately.
        vm.prank(alice);
        vault.withdraw(aliceId, 9_000 * UNIT);

        assertEq(
            usdc.balanceOf(address(vault)),
            11_000 * UNIT,
            "Bob's 10,000 plus Alice's 1,000 of backing"
        );
        assertEq(vault.availableIdle(bobId), 10_000 * UNIT, "Bob untouched");
    }

    /// And Alice is never trapped: cancelling is hers to do alone, and it takes the
    /// allowance with it.
    function test_cancellingReleasesBothTheGateAndTheAllowance() public {
        bytes32 aliceId = _open(alice, 10_000 * UNIT);

        vm.prank(agent);
        vault.authoriseOrder(
            aliceId,
            address(venue),
            keccak256("o"),
            1_000 * UNIT,
            uint64(block.timestamp + 10 minutes)
        );

        vm.startPrank(alice);
        vault.cancelOrder(keccak256("o"));
        vault.withdraw(aliceId, 10_000 * UNIT);
        vm.stopPrank();

        assertEq(usdc.allowance(address(vault), address(venue)), 0, "no dangling permission");
        assertEq(usdc.balanceOf(alice), 10_000 * UNIT);
    }
}
