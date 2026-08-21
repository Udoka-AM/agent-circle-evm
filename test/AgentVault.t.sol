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
import { MockVenueAdapter, GreedyVenueAdapter } from "./mocks/MockVenueAdapter.sol";

contract AgentVaultTest is Test {
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
        usdc.approve(address(vault), type(uint256).max);
        id = vault.openVault(listingId, 0, 0);
        vault.deposit(id, 10_000 * UNIT);
        vm.stopPrank();
    }

    function _trade(uint256 spend, uint256 markTo) internal {
        vm.prank(agent);
        vault.executeTrade(id, address(venue), spend, abi.encode(id, spend, markTo));
    }

    // ─────────────────────────────────────── custody

    function test_onlyTraderCanWithdraw() public {
        vm.prank(agent);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.withdraw(id, 1 * UNIT);

        vm.prank(attacker);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.withdraw(id, 1 * UNIT);

        vm.prank(trader);
        vault.withdraw(id, 1_000 * UNIT);
        assertEq(usdc.balanceOf(trader), 91_000 * UNIT);
    }

    /// The agent's only lever is executeTrade against a whitelisted adapter. There is no
    /// path from agent authority to an arbitrary transfer.
    function test_agentCannotReachAnArbitraryAddress() public {
        vm.prank(agent);
        vm.expectRevert(Errors.VenueNotWhitelisted.selector);
        vault.executeTrade(id, attacker, 10_000 * UNIT, "");
    }

    function test_onlyAgentAuthorityCanTrade() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.executeTrade(id, address(venue), 1_000 * UNIT, abi.encode(id, uint256(0), uint256(0)));

        vm.prank(trader);
        vm.expectRevert(Errors.NotAgentAuthority.selector);
        vault.executeTrade(id, address(venue), 1_000 * UNIT, abi.encode(id, uint256(0), uint256(0)));
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
        vault.executeTrade(id, address(greedy), 100 * UNIT, abi.encode(uint256(10_000 * UNIT)));

        assertEq(vault.totalValue(id), 10_000 * UNIT, "vault untouched");
    }

    /// One contract holds many traders' tokens. A second trader's balance must be
    /// unreachable from the first vault.
    function test_vaultsAreIsolated() public {
        address trader2 = makeAddr("trader2");
        usdc.mint(trader2, 50_000 * UNIT);
        vm.startPrank(trader2);
        usdc.approve(address(vault), type(uint256).max);
        bytes32 id2 = vault.openVault(listingId, 0, 0);
        vault.deposit(id2, 5_000 * UNIT);
        vm.stopPrank();

        // Trader 1 cannot withdraw more than their own idle balance even though the
        // contract holds 15,000 in total.
        vm.prank(trader);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.withdraw(id, 12_000 * UNIT);

        assertEq(vault.totalValue(id), 10_000 * UNIT);
        assertEq(vault.totalValue(id2), 5_000 * UNIT);
    }

    // ─────────────────────────────────────── limits

    function test_positionCapEnforcedAtomically() public {
        // Cap is 1200bps. 2,000 of a 10,000 vault is 2000bps and must revert everything.
        vm.prank(agent);
        vm.expectRevert(Errors.PositionCapExceeded.selector);
        vault.executeTrade(
            id,
            address(venue),
            2_000 * UNIT,
            abi.encode(id, uint256(2_000 * UNIT), uint256(2_000 * UNIT))
        );

        assertEq(vault.totalValue(id), 10_000 * UNIT, "state untouched after revert");
        assertEq(usdc.balanceOf(address(venue)), 0, "no tokens left the vault");
    }

    function test_tradeWithinCapSucceeds() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);
        assertEq(vault.totalValue(id), 10_000 * UNIT, "9,000 idle + 1,000 position");
    }

    function test_drawdownBreachAutoPauses() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);

        // Position collapses; total value falls to 9,000 against a 10,000 mark = 1000bps.
        // Still inside the 1500bps limit.
        venue.setPositionValue(id, 0);
        _trade(0, 0);
        (,,,,,,,,, AgentVault.VaultStatus status,,) = vault.vaults(id);
        assertEq(uint256(status), uint256(AgentVault.VaultStatus.Active), "1000bps is allowed");

        // Deeper loss: idle 9,000 with a further 500 gone takes it past 1500bps.
        _trade(900 * UNIT, 0); // spends 900 into a position worth 0 → value 8,100
        (,,,,,,,,, status,,) = vault.vaults(id);
        assertEq(uint256(status), uint256(AgentVault.VaultStatus.Paused), "1900bps trips");

        // Only the trader can resume.
        vm.prank(agent);
        vm.expectRevert(Errors.NotTrader.selector);
        vault.resumeVault(id);

        vm.prank(trader);
        vault.resumeVault(id);
    }

    function test_pausedVaultRejectsTrades() public {
        vm.prank(trader);
        vault.pauseVault(id);

        vm.prank(agent);
        vm.expectRevert(Errors.VaultNotActive.selector);
        vault.executeTrade(
            id, address(venue), 100 * UNIT, abi.encode(id, uint256(100 * UNIT), uint256(100 * UNIT))
        );
    }

    function test_riskOverridesMustBeStricter() public {
        address t2 = makeAddr("t2");
        vm.prank(t2);
        vm.expectRevert(Errors.RiskOverrideNotStricter.selector);
        vault.openVault(listingId, 5_000, 1_500);

        vm.prank(t2);
        bytes32 strict = vault.openVault(listingId, 500, 500);
        (,,,,,, uint16 cap, uint16 dd,,,,) = vault.vaults(strict);
        assertEq(cap, 500);
        assertEq(dd, 500);
    }

    function test_riskLimitsCanOnlyBeTightened() public {
        vm.startPrank(trader);
        vm.expectRevert(Errors.RiskOverrideNotStricter.selector);
        vault.tightenRiskLimits(id, 2_000, 1_500);

        vault.tightenRiskLimits(id, 600, 800);
        vm.stopPrank();

        (,,,,,, uint16 cap, uint16 dd,,,,) = vault.vaults(id);
        assertEq(cap, 600);
        assertEq(dd, 800);
    }

    function test_suspendedListingStopsTrading() public {
        vm.prank(guardian);
        registry.suspendListing(listingId);

        vm.prank(agent);
        vm.expectRevert(Errors.ListingNotLive.selector);
        vault.executeTrade(
            id, address(venue), 100 * UNIT, abi.encode(id, uint256(100 * UNIT), uint256(100 * UNIT))
        );

        // Trader funds stay withdrawable throughout. Suspension is not confiscation.
        vm.prank(trader);
        vault.withdraw(id, 10_000 * UNIT);
        assertEq(usdc.balanceOf(trader), 100_000 * UNIT);
    }

    // ─────────────────────────────────────── ceiling

    function test_depositRejectedAboveAumCeiling() public {
        // Tier 1 ceiling is 25,000 and 10,000 is already in.
        vm.prank(trader);
        vm.expectRevert(Errors.AumCeilingExceeded.selector);
        vault.deposit(id, 20_000 * UNIT);
    }

    // ─────────────────────────────────────── fees

    function test_performanceFeeSplitsEightyTwenty() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);

        // Position doubles: total value 11,000 against a 10,000 mark = 1,000 profit.
        venue.setPositionValue(id, 2_000 * UNIT);
        assertEq(vault.totalValue(id), 11_000 * UNIT);

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees(id);

        assertEq(usdc.balanceOf(builder), 80 * UNIT, "80% of a 100 fee");
        assertEq(usdc.balanceOf(treasury), 20 * UNIT);
    }

    function test_feeCannotBeAssessedTwiceForTheSameProfit() public {
        _trade(1_000 * UNIT, 1_000 * UNIT);
        venue.setPositionValue(id, 2_000 * UNIT);

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees(id);
        uint256 afterFirst = usdc.balanceOf(builder);

        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees(id);
        assertEq(usdc.balanceOf(builder), afterFirst, "same profit must not pay twice");
    }

    function test_crankIsRateLimited() public {
        vm.expectRevert(Errors.FeeAssessmentTooSoon.selector);
        vault.assessFees(id);
    }

    function test_noFeeWhenFlat() public {
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees(id);
        assertEq(usdc.balanceOf(builder), 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }
}
