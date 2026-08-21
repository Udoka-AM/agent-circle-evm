// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVenueAdapter } from "../../src/interfaces/IVenueAdapter.sol";

/// A venue that behaves. Pulls the requested spend and books it as a position whose
/// mark-to-market value the test controls directly, so the drawdown and position-cap
/// paths can be driven without a real prediction market.
contract MockVenueAdapter is IVenueAdapter {
    IERC20 public immutable token;
    mapping(bytes32 => uint256) public positions;

    constructor(address token_) {
        token = IERC20(token_);
    }

    /// data = abi.encode(vaultId, spend, markToValue)
    ///
    /// `spend > 0` opens or adds to a position. `spend == 0` with an open position
    /// closes it and returns the marked value to the vault, which is how a real venue
    /// settles — the adapter must actually hold the tokens it pays out, so a test
    /// simulating a win has to fund the counterparty side first.
    function execute(address vault, bytes calldata data) external returns (bytes memory) {
        (bytes32 id, uint256 spend, uint256 markTo) = abi.decode(data, (bytes32, uint256, uint256));

        if (spend > 0) {
            token.transferFrom(vault, address(this), spend);
            positions[id] = markTo;
        } else if (positions[id] > 0 && markTo == 0) {
            uint256 payout = positions[id];
            positions[id] = 0;
            token.transfer(vault, payout);
        } else {
            positions[id] = markTo;
        }
        return "";
    }

    /// Simulate a position moving after the fact.
    function setPositionValue(bytes32 id, uint256 value) external {
        positions[id] = value;
    }

    /// Return capital to the vault, as closing a position would.
    function settle(address vault, bytes32 id, uint256 amount) external {
        positions[id] = 0;
        token.transfer(vault, amount);
    }

    function positionValue(address, bytes32 id) external view returns (uint256) {
        return positions[id];
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

    function positionValue(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function quoteToken() external view returns (address) {
        return address(token);
    }
}
