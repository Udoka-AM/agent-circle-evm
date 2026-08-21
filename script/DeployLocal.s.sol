// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { Constants } from "../src/libraries/Constants.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockVenueAdapter } from "../test/mocks/MockVenueAdapter.sol";

/// Deploys the full system plus mock tokens to a local chain, then drives the builder
/// and trader journey against it as real broadcast transactions.
///
/// This is a development harness, not a deployment path. `Deploy.s.sol` is the real one.
/// The value here is proving the contracts work as deployed bytecode against a live
/// node, rather than only inside the test EVM.
contract DeployLocal is Script {
    uint256 constant UNIT = 1e6;

    function run() external {
        uint256 pk = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 agentToken = new MockERC20("Agent", "AGENT", 6);

        AgentRegistry registry = new AgentRegistry(
            deployer, // governance
            deployer, // guardian
            address(agentToken),
            [uint256(25_000 * UNIT), 100_000 * UNIT, 400_000 * UNIT],
            [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT],
            Constants.DEFAULT_UNBOND_PERIOD
        );
        VenueWhitelist whitelist =
            new VenueWhitelist(deployer, deployer, Constants.VENUE_TIMELOCK_DELAY);
        AgentVault vault =
            new AgentVault(address(usdc), address(registry), address(whitelist), deployer);
        MockVenueAdapter venue = new MockVenueAdapter(address(usdc));

        registry.setVault(address(vault));

        // Builder journey, all as the deployer for simplicity on a throwaway chain.
        agentToken.mint(deployer, 25_000 * UNIT);
        agentToken.approve(address(registry), type(uint256).max);
        registry.registerBuilder();
        registry.stakeBond(25_000 * UNIT);
        bytes32 listingId = registry.submitListing(deployer, keccak256("strategy-v1"));
        registry.approveListingAtLaunchTerms(listingId);

        // Trader journey.
        usdc.mint(deployer, 10_000 * UNIT);
        usdc.approve(address(vault), type(uint256).max);
        bytes32 id = vault.openVault(listingId, 0, 0);
        vault.deposit(id, 10_000 * UNIT);

        vm.stopBroadcast();

        console2.log("USDC:          ", address(usdc));
        console2.log("AGENT:         ", address(agentToken));
        console2.log("AgentRegistry: ", address(registry));
        console2.log("VenueWhitelist:", address(whitelist));
        console2.log("AgentVault:    ", address(vault));
        console2.log("VenueAdapter:  ", address(venue));
        console2.log("");
        console2.log("builder tier:    ", registry.getBuilder(deployer).tier);
        console2.log("AUM ceiling:     ", registry.aumCeiling(deployer) / UNIT);
        console2.log("vault id:        ", vm.toString(id));
        console2.log("vault value:     ", vault.totalValue(id) / UNIT);
        console2.log("");
        console2.log("Venue is NOT whitelisted: the 2-day timelock has not run on a fresh chain.");
    }
}
