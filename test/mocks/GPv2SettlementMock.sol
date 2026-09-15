// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGPv2Settlement} from "src/interfaces/IGPv2Settlement.sol";

/// @title GPv2SettlementMock
/// @notice Stands in for `GPv2Settlement` in unit and invariant tests.
/// @dev Mirrors only the surface the adapter calls; grows alongside {IGPv2Settlement}.
contract GPv2SettlementMock is IGPv2Settlement {
    mapping(bytes orderUid => uint256) internal _filledAmounts;

    address internal immutable VAULT_RELAYER;
    bytes32 internal immutable DOMAIN_SEPARATOR;

    error OrderUidMalformed();
    error NotOrderOwner();
    error OrderStillValid();

    constructor(address _vaultRelayer, bytes32 _domainSeparator) {
        VAULT_RELAYER = _vaultRelayer;
        DOMAIN_SEPARATOR = _domainSeparator;
    }

    /// @dev Mirrors settlement: callable only by the address encoded in the identifier, and
    ///      unconditional, so it overwrites a fill.
    function invalidateOrder(bytes calldata orderUid) external {
        (address owner,) = _extractOrderUidParams(orderUid);
        require(owner == msg.sender, NotOrderOwner());

        _filledAmounts[orderUid] = type(uint256).max;
    }

    function filledAmount(bytes calldata orderUid) external view returns (uint256) {
        return _filledAmounts[orderUid];
    }

    /// @dev Records a fill, standing in for the settlement of a trade against the order.
    function setFilledAmount(bytes calldata orderUid, uint256 amount) external {
        _filledAmounts[orderUid] = amount;
    }

    /// @dev Mirrors settlement's storage reclaim, which any solver may call once the order has
    ///      expired.
    function freeFilledAmountStorage(bytes calldata orderUid) external {
        (, uint32 validTo) = _extractOrderUidParams(orderUid);
        require(validTo < block.timestamp, OrderStillValid());

        delete _filledAmounts[orderUid];
    }

    function vaultRelayer() external view returns (address) {
        return VAULT_RELAYER;
    }

    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    /// @dev The identifier is `orderDigest ++ owner ++ validTo`, packed.
    function _extractOrderUidParams(bytes calldata orderUid) internal pure returns (address, uint32) {
        require(orderUid.length == 56, OrderUidMalformed());

        return (address(bytes20(orderUid[32:52])), uint32(bytes4(orderUid[52:56])));
    }
}
