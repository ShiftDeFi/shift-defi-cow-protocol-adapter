// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOwnerImmutable} from "./IOwnerImmutable.sol";

/// @title ICowProtocolAdapter
/// @notice Interface for the CoW Protocol adapter. The owner is the contract the adapter
///         instance is bound to; see {IOwnerImmutable} for the access-control surface.
interface ICowProtocolAdapter is IOwnerImmutable {
    /// @notice Emitted when a token balance is returned to the owner.
    /// @param token The token that was swept.
    /// @param amount The amount transferred to the owner.
    event TokensSwept(address indexed token, uint256 amount);

    /// @notice Thrown when a sweep is attempted for a token the adapter holds none of.
    error NothingToSweep();

    /// @notice Returns the adapter's entire balance of a token to the owner.
    /// @dev The destination is the immutable owner and is deliberately not a parameter:
    ///      a settlement and this function are the only ways a balance leaves the adapter.
    ///      Used to reclaim funds committed to an order that was cancelled rather than filled.
    /// @param token The token to return in full.
    function sweep(IERC20 token) external;
}
