// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOwnerImmutable
/// @notice Interface for single-owner access control whose owner is fixed at construction.
interface IOwnerImmutable {
    /// @notice Emitted once at construction, when the owner is set.
    /// @param owner The address the contract is permanently bound to.
    event OwnerSet(address indexed owner);

    /// @notice Thrown when the address supplied as parameter is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a caller other than the owner calls an owner-only function.
    /// @param caller The rejected caller.
    error NotOwner(address caller);

    /// @notice The address this contract is permanently bound to.
    /// @dev Immutable — set once at construction, never reassigned.
    /// @return The owner address.
    function owner() external view returns (address);
}
