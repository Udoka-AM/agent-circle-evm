// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { AgentRegistry } from "../src/AgentRegistry.sol";
import { AgentVault } from "../src/AgentVault.sol";
import { AgentVaultFactory } from "../src/AgentVaultFactory.sol";
import { VenueWhitelist } from "../src/VenueWhitelist.sol";
import { Constants } from "../src/libraries/Constants.sol";

/// Deploys the three contracts and wires them together.
///
/// `GOVERNANCE` must be a Safe multisig on mainnet. This script does not enforce that —
/// it cannot tell a Safe from an EOA — so it is on the operator. See README §6.
contract Deploy is Script {
    /// USDC.e on Polygon PoS.
    address constant POLYGON_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    uint256 constant UNIT = 1e6;

    function run()
        external
        returns (
            AgentRegistry registry,
            AgentVault implementation,
            AgentVaultFactory factory,
            VenueWhitelist wl
        )
    {
        address quote = vm.envOr("QUOTE_TOKEN", POLYGON_USDC);
        address bondToken = vm.envAddress("BOND_TOKEN");
        address governance = vm.envAddress("GOVERNANCE");
        address guardian = vm.envAddress("GUARDIAN");
        address treasury = vm.envAddress("TREASURY");

        uint256[3] memory tierBonds = [uint256(25_000 * UNIT), 100_000 * UNIT, 400_000 * UNIT];
        uint256[3] memory tierCeilings = [uint256(25_000 * UNIT), 150_000 * UNIT, 1_000_000 * UNIT];

        vm.startBroadcast();

        registry = new AgentRegistry(
            governance,
            guardian,
            bondToken,
            tierBonds,
            tierCeilings,
            Constants.DEFAULT_UNBOND_PERIOD
        );
        wl = new VenueWhitelist(governance, guardian, Constants.VENUE_TIMELOCK_DELAY);
        implementation = new AgentVault(quote, address(registry), address(wl), treasury);
        factory = new AgentVaultFactory(address(implementation), address(registry));

        vm.stopBroadcast();

        console2.log("AgentRegistry: ", address(registry));
        console2.log("VenueWhitelist:", address(wl));
        console2.log("VaultImpl:     ", address(implementation));
        console2.log("VaultFactory:  ", address(factory));
        console2.log("");
        console2.log("NOT YET USABLE. Two governance actions remain, both from GOVERNANCE:");
        console2.log(
            "  1. registry.setVaultFactory(%s)  -- one-shot, cannot be changed", address(factory)
        );
        console2.log("  2. queue + execute a venue on the whitelist (%s delay)", wl.delay());
        console2.log("");
        console2.log("Deposits will succeed before step 2. Trades will not.");
    }
}
