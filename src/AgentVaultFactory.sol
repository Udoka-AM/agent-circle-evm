// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { AgentVault } from "./AgentVault.sol";
import { IAgentRegistry } from "./interfaces/IAgentRegistry.sol";
import { Errors } from "./libraries/Errors.sol";

/// Deploys one `AgentVault` per `(trader, listing)` and vouches for it to the registry.
///
/// The registry lets exactly one address move AUM figures, and whatever can do that can
/// mint headroom out of nothing. There is no longer a single vault to name, so governance
/// trusts this factory once and the factory attests each vault it deploys. The trust is no
/// wider than it was: this contract calls `registerVault` only for a clone it has created
/// in the same call, and has no other way to reach the registry.
///
/// Vaults are deployed with CREATE2 at a salt derived from `(trader, listing)`, so a
/// vault's address is knowable before it exists and derivable by anyone from public data.
/// That matters for an order-book venue, where the vault's address is the identity a third
/// party settles against.
contract AgentVaultFactory {
    /// The clone target. Holds the protocol-wide immutables every vault shares and no
    /// funds of its own; its own storage is deliberately left uninitialisable.
    address public immutable implementation;
    IAgentRegistry public immutable registry;

    event VaultDeployed(address indexed vault, address indexed trader, bytes32 indexed listingId);

    constructor(address implementation_, address registry_) {
        if (implementation_ == address(0) || registry_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        implementation = implementation_;
        registry = IAgentRegistry(registry_);
    }

    /// Salt and mapping key for a vault. Keeps the `(trader, listing)` identity the
    /// singleton used, now as an address derivation rather than a storage lookup.
    function vaultId(address trader, bytes32 listingId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(trader, listingId));
    }

    /// The address this trader's vault for this listing has, or would have.
    function predictVault(address trader, bytes32 listingId) public view returns (address) {
        return Clones.predictDeterministicAddress(
            implementation, vaultId(trader, listingId), address(this)
        );
    }

    /// Whether that vault has been deployed yet.
    function vaultExists(address trader, bytes32 listingId) public view returns (bool) {
        return predictVault(trader, listingId).code.length != 0;
    }

    /// Deploy the caller's vault for a listing. Risk overrides are validated inside the
    /// vault's `initialize`, which is where the listing's own limits are read; pass zero
    /// for either to inherit them.
    function openVault(bytes32 listingId, uint16 positionCapBps, uint16 maxDrawdownBps)
        external
        returns (address vault)
    {
        // No mapping of trader to vault: the address is already determined by the salt, so
        // storing it would be paying ~20k gas to write down something CREATE2 has told us
        // for free. Existence is the code at that address.
        if (vaultExists(msg.sender, listingId)) revert Errors.VaultAlreadyExists();

        vault = Clones.cloneDeterministic(implementation, vaultId(msg.sender, listingId));

        // Vouch first, initialise second. `initialize` is the only call that can fail on a
        // freshly cloned vault, and a revert there unwinds the registration with it.
        registry.registerVault(vault);
        AgentVault(vault).initialize(msg.sender, listingId, positionCapBps, maxDrawdownBps);

        emit VaultDeployed(vault, msg.sender, listingId);
    }
}
