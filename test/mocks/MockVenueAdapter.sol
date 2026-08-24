// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVenueAdapter } from "../../src/interfaces/IVenueAdapter.sol";

/// A venue that behaves. Pulls the requested spend and books it as a position whose
/// mark-to-market value the test controls directly, so the drawdown and position-cap paths
/// can be driven without a real prediction market.
///
/// Positions key on the vault's address, which is now the whole of a vault's identity.
contract MockVenueAdapter is IVenueAdapter {
    IERC20 public immutable token;
    mapping(address => uint256) public positions;

    constructor(address token_) {
        token = IERC20(token_);
    }

    /// data = abi.encode(spend, markToValue)
    ///
    /// `spend > 0` opens or adds to a position. `spend == 0` with an open position closes
    /// it and returns the marked value to the vault, which is how a real venue settles —
    /// the adapter must actually hold the tokens it pays out, so a test simulating a win
    /// has to fund the counterparty side first.
    function execute(address vault, bytes calldata data) external returns (bytes memory) {
        (uint256 spend, uint256 markTo) = abi.decode(data, (uint256, uint256));

        if (spend > 0) {
            token.transferFrom(vault, address(this), spend);
            positions[vault] = markTo;
        } else if (positions[vault] > 0 && markTo == 0) {
            uint256 payout = positions[vault];
            positions[vault] = 0;
            token.transfer(vault, payout);
        } else {
            positions[vault] = markTo;
        }
        return "";
    }

    /// The permission-free exit. Hands back the position's marked value with no operator
    /// and no allowance from the vault — the adapter pushes, it never pulls.
    ///
    /// data = abi.encode(portionBps): 10_000 closes the whole position, less closes part,
    /// which is how a partial exit and a resolved-market redemption both look from here.
    function exit(address vault, bytes calldata data) external returns (uint256) {
        uint256 portionBps = abi.decode(data, (uint256));
        uint256 payout = (positions[vault] * portionBps) / 10_000;
        positions[vault] -= payout;
        if (payout > 0) token.transfer(vault, payout);
        return payout;
    }

    /// Settles atomically, so it pulls for itself.
    function settlementSpender() external view returns (address) {
        return address(this);
    }

    /// Simulate a position moving after the fact.
    function setPositionValue(address vault, uint256 value) external {
        positions[vault] = value;
    }

    /// Return capital to the vault, as closing a position would.
    function settle(address vault, uint256 amount) external {
        positions[vault] = 0;
        token.transfer(vault, amount);
    }

    function positionValue(address vault) external view returns (uint256) {
        return positions[vault];
    }

    function quoteToken() external view returns (address) {
        return address(token);
    }
}

/// A venue that misbehaves: tries to pull more than the vault authorised.
contract GreedyVenueAdapter is IVenueAdapter {
    IERC20 public immutable token;

    constructor(address token_) {
        token = IERC20(token_);
    }

    function execute(address vault, bytes calldata data) external returns (bytes memory) {
        uint256 grab = abi.decode(data, (uint256));
        token.transferFrom(vault, address(this), grab);
        return "";
    }

    /// Treats an "exit" as another chance to pull from the vault. The vault grants no
    /// allowance here, so this reverts — and would be caught by the balance check even if
    /// an allowance were somehow left standing.
    function exit(address vault, bytes calldata data) external returns (uint256) {
        uint256 grab = abi.decode(data, (uint256));
        token.transferFrom(vault, address(this), grab);
        return 0;
    }

    function settlementSpender() external view returns (address) {
        return address(this);
    }

    function positionValue(address) external pure returns (uint256) {
        return 0;
    }

    function quoteToken() external view returns (address) {
        return address(token);
    }
}

/// An order-book venue: the adapter never settles anything itself, and the address that
/// pulls quote tokens is a separate exchange the vault does not control. This is the shape
/// the Polymarket route actually has, and the reason `settlementSpender` exists.
contract BookVenueAdapter is IVenueAdapter {
    IERC20 public immutable token;
    address public immutable exchange;

    constructor(address token_, address exchange_) {
        token = IERC20(token_);
        exchange = exchange_;
    }

    function execute(address, bytes calldata) external pure returns (bytes memory) {
        revert("entry is via the book, not here");
    }

    function exit(address, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function settlementSpender() external view returns (address) {
        return exchange;
    }

    function positionValue(address) external pure returns (uint256) {
        return 0;
    }

    function quoteToken() external view returns (address) {
        return address(token);
    }
}
