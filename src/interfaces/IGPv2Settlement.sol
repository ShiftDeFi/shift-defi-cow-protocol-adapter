// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGPv2Settlement
/// @notice The subset of CoW Protocol's `GPv2Settlement` that this adapter calls.
/// @dev Declared locally rather than imported: CoW's contracts target solc 0.7.6 and do not
///      compile under this repository's pragma. Signatures mirror the deployed contract.
interface IGPv2Settlement {
    /// @notice Cancels an order on-chain, so no trade against it can settle.
    /// @dev Writes `type(uint256).max` over the order's fill record. Callable only by the address
    ///      encoded in `orderUid`, and unconditional — it overwrites whatever the record held,
    ///      including a fill, so fill status must be read before calling it.
    /// @param orderUid The order's unique identifier.
    function invalidateOrder(bytes calldata orderUid) external;

    /// @notice The cumulative amount an order has been filled for.
    /// @dev In units of the order's exact side: the sell amount for a sell order, the buy amount
    ///      for a buy order. `type(uint256).max` means the order was cancelled. The record is
    ///      only meaningful while the order is valid — settlement lets a solver clear it once the
    ///      order has expired, after which a filled, a cancelled and an untouched order all read
    ///      zero.
    /// @param orderUid The order's unique identifier.
    /// @return The amount filled.
    function filledAmount(bytes calldata orderUid) external view returns (uint256);

    /// @notice The contract that pulls sell tokens from an order's owner during settlement.
    /// @dev Token allowances are granted to this address, not to the settlement contract.
    /// @return The vault relayer address.
    function vaultRelayer() external view returns (address);

    /// @notice The EIP-712 domain separator orders are signed against.
    /// @dev Binds a signature to this settlement contract and chain.
    /// @return The domain separator.
    function domainSeparator() external view returns (bytes32);
}
