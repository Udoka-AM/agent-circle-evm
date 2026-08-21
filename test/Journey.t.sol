// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { IAgentRegistry } from "../src/interfaces/IAgentRegistry.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockVenueAdapter } from "./mocks/MockVenueAdapter.sol";

/// The whole product in one test, with the state printed at every step.
///
/// Run with `forge test --match-contract Journey -vv` to read it as a walkthrough.
/// This is the fastest way for someone new to the codebase to see what the system does.
contract JourneyTest is Test {
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

    uint256 constant UNIT = 1e6;

    function _usd(uint256 raw) internal pure returns (string memory) {
        return string.concat("$", vm.toString(raw / UNIT));
    }

    function test_fullJourney() public {
        console2.log("=== 1. Deploy ===");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        agentToken = new MockERC20("Agent", "AGENT", 6);
        registry = new AgentRegistry(
            governance,
            guardian,
            address(agentToken),
            [uint256(25_000 * UNIT), 100_000 * UNIT, 400_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            Constants.DEFAULT_UNBOND_PERIOD
        );
        whitelist = new VenueWhitelist(governance, guardian, Constants.VENUE_TIMELOCK_DELAY);
        vault = new AgentVault(address(usdc), address(registry), address(whitelist), treasury);
        venue = new MockVenueAdapter(address(usdc));

        vm.prank(governance);
        registry.setVault(address(vault));
        console2.log("  registry / whitelist / vault deployed and wired");

        console2.log("");
        console2.log("=== 2. Governance whitelists a venue (timelocked) ===");
        vm.prank(governance);
        whitelist.queueAddition(address(venue));
        console2.log("  queued; cannot execute for 2 days");
        vm.warp(block.timestamp + Constants.VENUE_TIMELOCK_DELAY);
        vm.prank(governance);
        whitelist.executeAddition(address(venue));
        console2.log("  executed after the delay");

        console2.log("");
        console2.log("=== 3. Builder registers and bonds ===");
        agentToken.mint(builder, 25_000 * UNIT);
        vm.startPrank(builder);
        agentToken.approve(address(registry), type(uint256).max);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        bytes32 listingId = registry.submitListing(agent, keccak256("strategy-v1"));
        vm.stopPrank();
        console2.log("  bonded 25,000 AGENT -> tier", registry.getBuilder(builder).tier);
        console2.log("  AUM ceiling unlocked:", _usd(registry.aumCeiling(builder)));
        console2.log("  listing submitted, status = Vetting, fees = 0");

        console2.log("");
        console2.log("=== 4. Governance approves the listing ===");
        vm.prank(governance);
        registry.approveListingAtLaunchTerms(listingId);
        IAgentRegistry.Listing memory l = registry.getListing(listingId);
        console2.log("  status = Live");
        console2.log("  performance fee bps:", l.performanceFeeBps);
        console2.log("  builder split bps:  ", l.builderSplitBps);
        console2.log("  position cap bps:   ", l.positionCapBps);
        console2.log("  max drawdown bps:   ", l.maxDrawdownBps);

        console2.log("");
        console2.log("=== 5. Trader allocates capital ===");
        usdc.mint(trader, 10_000 * UNIT);
        vm.startPrank(trader);
        usdc.approve(address(vault), type(uint256).max);
        bytes32 id = vault.openVault(listingId, 0, 0);
        vault.deposit(id, 10_000 * UNIT);
        vm.stopPrank();
        console2.log("  deposited:", _usd(vault.totalValue(id)));
        console2.log("  trader is sole withdrawal authority");

        console2.log("");
        console2.log("=== 6. Agent trades within its limits ===");
        vm.prank(agent);
        vault.executeTrade(
            id,
            address(venue),
            1_000 * UNIT,
            abi.encode(id, uint256(1_000 * UNIT), uint256(1_000 * UNIT))
        );
        console2.log("  opened a $1,000 position (1000bps, inside the 1200bps cap)");
        console2.log("  total value:", _usd(vault.totalValue(id)));

        console2.log("");
        console2.log("=== 7. Agent tries to breach the position cap ===");
        vm.prank(agent);
        (bool ok,) = address(vault)
            .call(
                abi.encodeCall(
                    AgentVault.executeTrade,
                    (
                        id,
                        address(venue),
                        2_000 * UNIT,
                        abi.encode(id, uint256(2_000 * UNIT), uint256(2_000 * UNIT))
                    )
                )
            );
        assertFalse(ok, "must revert");
        console2.log("  reverted. enforced in the same tx as the trade, not after it");
        console2.log("  total value unchanged:", _usd(vault.totalValue(id)));

        console2.log("");
        console2.log("=== 8. Position wins; fees assessed on profit only ===");
        venue.setPositionValue(id, 2_000 * UNIT);
        console2.log("  position doubled, total value:", _usd(vault.totalValue(id)));
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees(id);
        console2.log("  builder received: ", _usd(usdc.balanceOf(builder)));
        console2.log("  treasury received:", _usd(usdc.balanceOf(treasury)));

        console2.log("");
        console2.log("=== 9. Second assessment charges nothing ===");
        vm.warp(block.timestamp + Constants.FEE_ASSESSMENT_INTERVAL);
        vault.assessFees(id);
        console2.log("  builder still at:", _usd(usdc.balanceOf(builder)));
        console2.log("  high-water mark prevents billing the same profit twice");

        console2.log("");
        console2.log("=== 10. Trader exits ===");
        // The counterparty pays out the winning side. The adapter can only return
        // tokens it actually holds.
        usdc.mint(address(venue), 1_000 * UNIT);
        vm.prank(agent);
        vault.executeTrade(id, address(venue), 0, abi.encode(id, uint256(0), uint256(0)));
        (,, uint256 idle,,,,,,,) = vault.vaults(id);
        vm.prank(trader);
        vault.withdraw(id, idle);
        console2.log("  trader walked away with:", _usd(usdc.balanceOf(trader)));

        assertGt(usdc.balanceOf(builder), 0, "builder earned on real profit");
        assertGt(usdc.balanceOf(trader), 10_000 * UNIT, "trader kept the rest of the upside");
    }
}
