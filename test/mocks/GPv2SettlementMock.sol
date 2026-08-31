// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGPv2Settlement} from "src/interfaces/IGPv2Settlement.sol";

/// @title GPv2SettlementMock
/// @notice Stands in for `GPv2Settlement` in unit and invariant tests.
/// @dev Mirrors only the surface the adapter calls; grows alongside {IGPv2Settlement}.
contract GPv2SettlementMock is IGPv2Settlement {
    address internal immutable VAULT_RELAYER;
    bytes32 internal immutable DOMAIN_SEPARATOR;

    constructor(address _vaultRelayer, bytes32 _domainSeparator) {
        VAULT_RELAYER = _vaultRelayer;
        DOMAIN_SEPARATOR = _domainSeparator;
    }

    function vaultRelayer() external view returns (address) {
        return VAULT_RELAYER;
    }

    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }
}
