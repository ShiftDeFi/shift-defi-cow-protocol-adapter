// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnerImmutable} from "./IOwnerImmutable.sol";

/// @title ICowProtocolAdapter
/// @notice Interface for the CoW Protocol adapter. The owner is the contract the adapter
///         instance is bound to; see {IOwnerImmutable} for the access-control surface.
interface ICowProtocolAdapter is IOwnerImmutable {
    /// @notice Whether an order fixes the amount sold or the amount bought.
    enum OrderKind {
        Sell,
        Buy
    }

    /// @notice The caller-supplied part of an order.
    /// @dev The remaining fields of a CoW Protocol order are fixed by the adapter and are not
    ///      accepted from a caller: `receiver` is the immutable owner, `partiallyFillable` is
    ///      false, `feeAmount` is zero, and both balance fields are plain ERC-20.
    /// @param sellToken The token to sell.
    /// @param buyToken The token to buy.
    /// @param sellAmount The amount of `sellToken` to sell, exact for a sell order.
    /// @param buyAmount The amount of `buyToken` to buy, exact for a buy order.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param appData The hash of the order's off-chain metadata.
    /// @param kind Whether `sellAmount` or `buyAmount` is the exact side.
    struct OrderParams {
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        OrderKind kind;
    }

    /// @notice Emitted once at construction, when the adapter is bound to a settlement contract.
    /// @param settlement The CoW Protocol settlement contract the adapter is bound to.
    /// @param vaultRelayer The relayer that settlement reported, read at construction.
    /// @param domainSeparator The EIP-712 domain separator that settlement reported, read at
    ///        construction.
    event SettlementSet(address indexed settlement, address indexed vaultRelayer, bytes32 domainSeparator);

    /// @notice Emitted when a token balance is returned to the owner.
    /// @param token The token that was swept.
    /// @param amount The amount transferred to the owner.
    event TokensSwept(address indexed token, uint256 amount);

    /// @notice Thrown when the zero address is supplied as the settlement contract.
    error ZeroSettlement();

    /// @notice Thrown when the settlement contract reports the zero address as its relayer.
    error ZeroVaultRelayer();

    /// @notice Thrown when the settlement contract reports a zero EIP-712 domain separator.
    error ZeroDomainSeparator();

    /// @notice Thrown when a sweep is attempted for a token the adapter holds none of.
    error NothingToSweep();

    /// @notice Thrown when an order names the zero address as its sell token.
    error ZeroSellToken();

    /// @notice Thrown when an order names the zero address as its buy token.
    error ZeroBuyToken();

    /// @notice Thrown when an order sells and buys the same token.
    error IdenticalTokens();

    /// @notice Thrown when an order sells nothing.
    error ZeroSellAmount();

    /// @notice Thrown when an order buys nothing.
    error ZeroBuyAmount();

    /// @notice Thrown when an order carries no expiry.
    error ZeroValidTo();

    /// @notice Returns the adapter's entire balance of a token to the owner.
    /// @dev The destination is the immutable owner. A settlement and this function are the
    ///      only ways a balance leaves the adapter. Used to reclaim funds committed to an
    ///      order that was cancelled rather than filled.
    /// @param token The token to return in full.
    function sweep(address token) external;

    /// @notice The unique identifier settlement would record fills of an order under.
    /// @dev Derived from the order's EIP-712 digest, this adapter's address and `validTo`. The
    ///      identifier is therefore bound to this adapter instance: the same parameters yield a
    ///      different identifier on any other adapter.
    /// @param params The caller-supplied part of the order.
    /// @return The order's 56-byte unique identifier.
    function orderUid(OrderParams calldata params) external view returns (bytes memory);

    /// @notice The CoW Protocol settlement contract this adapter places orders against.
    /// @dev Immutable — set once at construction, never reassigned.
    /// @return The settlement contract address.
    function settlement() external view returns (address);

    /// @notice The address token allowances are granted to for settlement to pull sell tokens.
    /// @dev Read from {settlement} at construction and fixed thereafter.
    /// @return The vault relayer address.
    function vaultRelayer() external view returns (address);

    /// @notice The EIP-712 domain separator orders placed by this adapter are signed against.
    /// @dev Read from {settlement} at construction and fixed thereafter.
    /// @return The domain separator.
    function domainSeparator() external view returns (bytes32);
}
