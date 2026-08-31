// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnerImmutable} from "./interfaces/IOwnerImmutable.sol";

/// @title OwnerImmutable
/// @notice Single-owner access control whose owner is fixed at construction.
/// @dev The owner is `immutable`, not stored, and there is no transfer or renounce path: an
///      instance is permanently bound to the address given at construction.
abstract contract OwnerImmutable is IOwnerImmutable {
    address internal immutable OWNER;

    /// @dev Restricts a function to the owner. The check stays in `_checkOwner`; inlining it
    ///      here trips the `unwrapped-modifier-logic` lint.
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    constructor(address _owner) {
        require(_owner != address(0), ZeroAddress());
        OWNER = _owner;
        emit OwnerSet(_owner);
    }

    function owner() external view returns (address) {
        return OWNER;
    }

    function _checkOwner() internal view {
        require(msg.sender == OWNER, NotOwner(msg.sender));
    }
}
