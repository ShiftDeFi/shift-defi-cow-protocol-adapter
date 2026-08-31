// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGPv2Settlement
/// @notice The subset of CoW Protocol's `GPv2Settlement` that this adapter calls.
/// @dev Declared locally rather than imported: CoW's contracts target solc 0.7.6 and do not
///      compile under this repository's pragma. Signatures mirror the deployed contract.
interface IGPv2Settlement {
    /// @notice The contract that pulls sell tokens from an order's owner during settlement.
    /// @dev Token allowances are granted to this address, not to the settlement contract.
    /// @return The vault relayer address.
    function vaultRelayer() external view returns (address);

    /// @notice The EIP-712 domain separator orders are signed against.
    /// @dev Binds a signature to this settlement contract and chain.
    /// @return The domain separator.
    function domainSeparator() external view returns (bytes32);
}
