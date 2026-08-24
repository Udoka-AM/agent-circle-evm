// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { AgentVaultFactory } from "../src/AgentVaultFactory.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { IAgentRegistry } from "../src/interfaces/IAgentRegistry.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockVenueAdapter, GreedyVenueAdapter } from "./mocks/MockVenueAdapter.sol";

contract AgentVaultTest is Test {
    AgentRegistry registry;
    AgentVault implementation;
    AgentVaultFactory factory;
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

        // Builder bonds to tier 1 and gets a listing approved.
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

        // Trader opens and funds a vault.
        usdc.mint(trader, 100_000 * UNIT);
        vm.startPrank(trader);
        vault = AgentVault(factory.openVault(listingId, 0, 0));
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000 * UNIT);
        vm.stopPrank();
    }

    function _trade(uint256 spend, uint256 markTo) internal {
        vm.prank(agent);
        vault.executeTrade(address(venue), spend, abi.encode(spend, markTo));
    }

    // ─────────────────────────────────────── custody

    function test_onlyTraderCanWithdraw() public {
        vm.prank(agent);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.withdraw(1 * UNIT);

        vm.prank(attacker);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.withdraw(1 * UNIT);

        vm.prank(trader);
        vault.withdraw(1_000 * UNIT);
        assertEq(usdc.balanceOf(trader), 91_000 * UNIT);
    }

    /// The agent's only lever is executeTrade against a whitelisted adapter. There is no
    /// path from agent authority to an arbitrary transfer.
    function test_agentCannotReachAnArbitraryAddress() public {
        vm.prank(agent);
        vm.expectRevert(Errors.VenueNotWhitelisted.selector);
        vault.executeTrade(attacker, 10_000 * UNIT, "");
    }

    function test_onlyAgentAuthorityCanTrade() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.executeTrade(address(venue), 1_000 * UNIT, abi.encode(uint256(0), uint256(0)));

        vm.prank(trader);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.executeTrade(address(venue), 1_000 * UNIT, abi.encode(uint256(0), uint256(0)));
    }

    /// A rogue adapter must not be able to pull more than the agent authorised.
    function test_adapterCannotExceedAuthorisedSpend() public {
        GreedyVenueAdapter greedy = new GreedyVenueAdapter(address(usdc));
        vm.startPrank(governance);
        whitelist.queueAddition(address(greedy));
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        whitelist.executeAddition(address(greedy));
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(); // ERC20InsufficientAllowance
        vault.executeTrade(address(greedy), 100 * UNIT, abi.encode(uint256(10_000 * UNIT)));

        assertEq(vault.totalValue(), 10_000 * UNIT, "vault untouched");
    }

    /// Isolation used to be a property of careful bookkeeping inside one contract that
    /// held everybody's tokens. It is now structural: two vaults are two addresses, and
    /// neither can reach the other's balance because neither holds it.
    function test_vaultsAreIsolated() public {
        address trader2 = makeAddr("trader2");
        usdc.mint(trader2, 50_000 * UNIT);
        vm.startPrank(trader2);
        AgentVault vault2 = AgentVault(factory.openVault(listingId, 0, 0));
        usdc.approve(address(vault2), type(uint256).max);
        vault2.deposit(5_000 * UNIT);
        vm.stopPrank();

        assertTrue(address(vault) != address(vault2), "separate deployments");
        assertEq(usdc.balanceOf(address(vault)), 10_000 * UNIT);
        assertEq(usdc.balanceOf(address(vault2)), 5_000 * UNIT);

        vm.prank(trader);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.withdraw(12_000 * UNIT);

        // And trader 1 is simply not the trader of vault 2.
        vm.prank(trader);
        vm.expectRevert(Errors.NotTrader.selector);
        vault2.withdraw(1);

        assertEq(vault.totalValue(), 10_000 * UNIT);
        assertEq(vault2.totalValue(), 5_000 * UNIT);
    }

    // ─────────────────────────────────────── limits

    function test_positionCapEnforcedAtomically() public {
        // Cap is 1200bps. 2,000 of a 10,000 vault is 2000bps and must revert everything.
        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.executeTrade(
            address(venue), 2_000 * UNIT, abi.encode(uint256(2_000 * UNIT), uint256(2_000 * UNIT))
        );

        assertEq(vault.totalValue(), 10_000 * UNIT, "state untouched after revert");
        assertEq(usdc.balanceOf(address(venue)), 0, "no tokens left the vault");
    }

    function test_tradeWithinCapSucceeds() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);
        assertEq(vault.totalValue(), 10_000 * UNIT, "9,000 idle + 1,000 position");
    }

    function test_drawdownBreachAutoPauses() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);

        // Position collapses; total value falls to 9,000 against a 10,000 mark = 1000bps.
        // Still inside the 1500bps limit.
        venue.setPositionValue(address(vault), 0);
        _trade(0, 0);
        assertEq(
            uint256(vault.status()), uint256(AgentVault.VaultStatus.Active), "1000bps is allowed"
        );

        // Deeper loss: idle 9,000 with a further 500 gone takes it past 1500bps.
        _trade(900 * UNIT, 0); // spends 900 into a position worth 0 → value 8,100
        assertEq(uint256(vault.status()), uint256(AgentVault.VaultStatus.Paused), "1900bps trips");

        // Only the trader can resume.
        vm.prank(agent);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.resumeVault();

        vm.prank(trader);
        vault.resumeVault();
    }

    function test_pausedVaultRejectsTrades() public {
        vm.prank(trader);
        vault.pauseVault();

        vm.prank(agent);
        vm.expectRevert(Errors.VaultNotActive.selector);
        vault.executeTrade(
            address(venue), 100 * UNIT, abi.encode(uint256(100 * UNIT), uint256(100 * UNIT))
        );
    }

    function test_riskOverridesMustBeStricter() public {
        address t2 = makeAddr("t2");
        vm.prank(t2);
        vm.expectRevert(Errors.RiskOverrideNotStricter.selector);
        factory.openVault(listingId, 5_000, 1_500);

        vm.prank(t2);
        AgentVault strict = AgentVault(factory.openVault(listingId, 500, 500));
        assertEq(strict.positionCapBps(), 500);
        assertEq(strict.maxDrawdownBps(), 500);
    }

    function test_riskLimitsCanOnlyBeTightened() public {
        vm.startPrank(trader);
        vm.expectRevert(Errors.RiskOverrideNotStricter.selector);
        vault.tightenRiskLimits(2_000, 1_500);

        vault.tightenRiskLimits(600, 800);
        vm.stopPrank();

        assertEq(vault.positionCapBps(), 600);
        assertEq(vault.maxDrawdownBps(), 800);
    }

    function test_suspendedListingStopsTrading() public {
        vm.prank(guardian);
        registry.suspendListing(listingId);

        vm.prank(agent);
        vm.expectRevert(Errors.ListingNotLive.selector);
        vault.executeTrade(
            address(venue), 100 * UNIT, abi.encode(uint256(100 * UNIT), uint256(100 * UNIT))
        );

        // Trader funds stay withdrawable throughout. Suspension is not confiscation.
        vm.prank(trader);
        vault.withdraw(10_000 * UNIT);
        assertEq(usdc.balanceOf(trader), 100_000 * UNIT);
    }

    // ─────────────────────────────────────── ceiling

    function test_depositRejectedAboveAumCeiling() public {
        // Tier 1 ceiling is 25,000 and 10,000 is already in.
        vm.prank(trader);
        vm.expectRevert(Errors.AumCeilingExceeded.selector);
        vault.deposit(20_000 * UNIT);
    }

    // ─────────────────────────────────────── fees

    function test_performanceFeeSplitsEightyTwenty() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);

        // Position doubles: total value 11,000 against a 10,000 mark = 1,000 profit.
        venue.setPositionValue(address(vault), 2_000 * UNIT);
        assertEq(vault.totalValue(), 11_000 * UNIT);

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees();

        assertEq(usdc.balanceOf(builder), 80 * UNIT, "80% of a 100 fee");
        assertEq(usdc.balanceOf(treasury), 20 * UNIT);
    }

    function test_feeCannotBeAssessedTwiceForTheSameProfit() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);
        venue.setPositionValue(address(vault), 2_000 * UNIT);

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees();
        uint256 afterFirst = usdc.balanceOf(builder);

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees();
        assertEq(usdc.balanceOf(builder), afterFirst, "same profit must not pay twice");
    }

    function test_crankIsRateLimited() public {
        vm.expectRevert(Errors.FeeAssessmentTooSoon.selector);
        vault.assessFees();
    }

    function test_noFeeWhenFlat() public {
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees();
        assertEq(usdc.balanceOf(builder), 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }
}
