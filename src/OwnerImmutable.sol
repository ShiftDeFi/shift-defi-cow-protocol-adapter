// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnerImmutable} from "./interfaces/IOwnerImmutable.sol";

/// @title OwnerImmutable
/// @notice Single-owner access control whose owner is fixed at construction.
/// @dev Deliberately not OpenZeppelin's `Ownable`. The owner here is `immutable` rather than
///      stored, and there is no transfer or renounce path: an instance is permanently bound to
///      one address, so a transferable owner would be a liability rather than a feature.
abstract contract OwnerImmutable is IOwnerImmutable {
    address internal immutable OWNER;

    /// @dev Restricts a function to the owner. The check itself lives in a function so it is
    ///      not inlined into every call site.
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
