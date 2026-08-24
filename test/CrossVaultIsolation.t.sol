// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { AgentVaultFactory } from "../src/AgentVaultFactory.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockVenueAdapter } from "./mocks/MockVenueAdapter.sol";

/// Two traders, two vaults, and the boundary between them.
///
/// This suite exists because of a real bug. When one contract held every trader's tokens,
/// a trader could authorise an order — which grants the settlement spender a standing
/// allowance — then withdraw their own backing and leave that allowance live over a pooled
/// balance made up of other people's money. The order would settle out of a stranger's
/// vault.
///
/// Two things now stand in the way, and the tests below pin both. The withdrawal gate,
/// which is what fixed it at the time. And the topology, which makes the whole class of
/// bug unreachable: an allowance granted by Alice's vault is an allowance over Alice's
/// vault's balance, and Bob's money is not in it.
contract CrossVaultIsolationTest is Test {
    AgentRegistry registry;
    AgentVault implementation;
    AgentVaultFactory factory;
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
        implementation =
            new AgentVault(address(usdc), address(registry), address(whitelist), treasury);
        factory = new AgentVaultFactory(address(implementation), address(registry));
        venue = new MockVenueAdapter(address(usdc));

        vm.prank(governance);
        registry.setVaultFactory(address(factory));

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

    function _open(address who, uint256 amount) internal returns (AgentVault v) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        v = AgentVault(factory.openVault(listingId, 0, 0));
        usdc.approve(address(v), type(uint256).max);
        v.deposit(amount);
        vm.stopPrank();
    }

    function _authorise(AgentVault v, uint256 maxCost) internal {
        vm.prank(agent);
        v.authoriseOrder(
            address(venue), keccak256("o"), maxCost, uint64(block.timestamp + 10 minutes)
        );
    }

    /// The first line of defence, and the one that fixed the original bug: reserved
    /// capital is not withdrawable, so an allowance is never left without its backing.
    function test_withdrawalCannotStrandTheAllowanceItGranted() public {
        AgentVault a = _open(alice, 10_000 * UNIT);
        _authorise(a, 1_000 * UNIT);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        a.withdraw(10_000 * UNIT);

        // Everything not backing the order is hers, immediately.
        vm.prank(alice);
        a.withdraw(9_000 * UNIT);

        assertEq(usdc.allowance(address(a), address(venue)), 1_000 * UNIT);
        assertEq(usdc.balanceOf(address(a)), 1_000 * UNIT, "allowance still fully backed");
    }

    /// The second, and the reason the topology changed: even a dangling allowance could
    /// only ever reach the vault that granted it. Bob's money is at a different address.
    function test_anAllowanceCannotReachAnotherTradersVault() public {
        AgentVault a = _open(alice, 10_000 * UNIT);
        AgentVault b = _open(bob, 10_000 * UNIT);

        _authorise(a, 1_000 * UNIT);

        assertEq(usdc.allowance(address(a), address(venue)), 1_000 * UNIT);
        assertEq(usdc.allowance(address(b), address(venue)), 0, "Bob granted nothing");

        // The spender can take what Alice authorised, from Alice, and nothing else.
        vm.prank(address(venue));
        usdc.transferFrom(address(a), address(venue), 1_000 * UNIT);

        vm.prank(address(venue));
        vm.expectRevert();
        usdc.transferFrom(address(b), address(venue), 1);

        assertEq(usdc.balanceOf(address(b)), 10_000 * UNIT, "Bob untouched");
    }

    /// And Alice is never trapped: cancelling is hers to do alone, and it takes the
    /// allowance with it.
    function test_cancellingReleasesBothTheGateAndTheAllowance() public {
        AgentVault a = _open(alice, 10_000 * UNIT);
        _authorise(a, 1_000 * UNIT);

        vm.startPrank(alice);
        a.cancelOrder(keccak256("o"));
        a.withdraw(10_000 * UNIT);
        vm.stopPrank();

        assertEq(usdc.allowance(address(a), address(venue)), 0, "no dangling permission");
        assertEq(usdc.balanceOf(alice), 10_000 * UNIT);
    }
}
