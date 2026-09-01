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
    /// @dev The remaining fields of a CoW Protocol order are fixed by the adapter: `receiver`
    ///      is the owner, `partiallyFillable` is false, `feeAmount` is zero, and both balance
    ///      fields are plain ERC-20.
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

    /// @notice An order the adapter has placed and that has not been resolved.
    /// @dev Recorded under the order's EIP-712 digest, the value settlement presents for
    ///      signature verification.
    /// @param sellToken The token the order sells. Non-zero exactly while the order is pending.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param kind Whether `sellAmount` or `buyAmount` is the exact side.
    /// @param sellAmount The amount of `sellToken` the order sells.
    /// @param buyAmount The amount of buy token the order buys.
    struct PendingOrder {
        address sellToken;
        uint32 validTo;
        OrderKind kind;
        uint256 sellAmount;
        uint256 buyAmount;
    }

    /// @notice Emitted once at construction, when the adapter is bound to a settlement contract.
    /// @param settlement The CoW Protocol settlement contract the adapter is bound to.
    /// @param vaultRelayer The relayer that settlement reported, read at construction.
    /// @param domainSeparator The EIP-712 domain separator that settlement reported, read at
    ///        construction.
    event SettlementSet(address indexed settlement, address indexed vaultRelayer, bytes32 domainSeparator);

    /// @notice Emitted when an order is placed and its sell tokens are committed to it.
    /// @param orderDigest The order's EIP-712 digest, the key it is recorded under.
    /// @param sellToken The token the order sells.
    /// @param buyToken The token the order buys.
    /// @param sellAmount The amount of `sellToken` the order sells.
    /// @param buyAmount The amount of `buyToken` the order buys.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param kind Whether `sellAmount` or `buyAmount` is the exact side.
    /// @param uid The identifier settlement records fills of the order under.
    event OrderPlaced(
        bytes32 indexed orderDigest,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        OrderKind kind,
        bytes uid
    );

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

    /// @notice Thrown when a sweep is attempted for a token whose whole balance is committed to
    ///         pending orders.
    /// @param balance The adapter's balance of the token.
    /// @param committed The part of it committed to pending orders.
    error NoUncommittedBalance(uint256 balance, uint256 committed);

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

    /// @notice Thrown when an order is placed with an expiry that has already passed.
    /// @param validTo The order's expiry.
    /// @param timestamp The block timestamp it was compared against.
    error ValidToInPast(uint32 validTo, uint256 timestamp);

    /// @notice Thrown when an order's sell token delivered less to the adapter than was pulled.
    /// @dev Measured as the adapter's balance change across the pull, so a token taking a fee
    ///      on transfer is rejected.
    /// @param requested The amount the adapter pulled.
    /// @param received The balance change it measured.
    error SellTokenShortfall(uint256 requested, uint256 received);

    /// @notice Thrown when an order identical to one already pending is placed again.
    /// @dev A digest stays pending from {placeOrder} until the order is resolved. Vary
    ///      `validTo` or `appData` to place a second order with otherwise identical parameters.
    /// @param orderDigest The digest already recorded as pending.
    error OrderAlreadyPending(bytes32 orderDigest);

    /// @notice Places an order, pulling its sell tokens from the owner and granting the vault
    ///         relayer the allowance settlement needs to collect them.
    /// @dev Records the order's digest under {pendingOrder}, which is what the adapter signs
    ///      for. Sell tokens are pulled from the caller within this call; the adapter's balance
    ///      must grow by at least `params.sellAmount`, so a token taking a fee on transfer
    ///      reverts with {SellTokenShortfall} and any excess is left uncommitted, recoverable
    ///      with {sweep}. An order
    ///      therefore always sells exactly `params.sellAmount`, and its identifier is the one
    ///      {orderUid} derives from the same parameters.
    ///
    ///      The relayer allowance is increased by `params.sellAmount` on every call, so
    ///      concurrent orders on one token hold the sum of their amounts.
    /// @param params The caller-supplied part of the order.
    /// @return uid The identifier settlement records fills of the order under.
    function placeOrder(OrderParams calldata params) external returns (bytes memory uid);

    /// @notice Returns the part of a token's balance that no pending order commits to the
    ///         owner.
    /// @dev The destination is the immutable owner. A settlement and this function are the only
    ///      ways a balance leaves the adapter. What {committedAmount} reports for the token is
    ///      retained, so the sell tokens behind a pending order are reachable only once that
    ///      order has been cancelled.
    /// @param token The token to return.
    function sweep(address token) external;

    /// @notice The unique identifier settlement would record fills of an order under.
    /// @dev Derived from the order's EIP-712 digest, this adapter's address and `validTo`, so
    ///      the same parameters yield a different identifier on any other adapter.
    /// @param params The caller-supplied part of the order.
    /// @return The order's 56-byte unique identifier.
    function orderUid(OrderParams calldata params) external view returns (bytes memory);

    /// @notice The order recorded under a digest, if one is pending.
    /// @dev A `sellToken` of zero means no order is pending under `orderDigest`. This is the
    ///      adapter's record of what it placed; what has filled is read from {settlement}.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return The pending order, or a zeroed struct if none is pending under that digest.
    function pendingOrder(bytes32 orderDigest) external view returns (PendingOrder memory);

    /// @notice How many orders the adapter has placed and not resolved.
    /// @dev Incremented by {placeOrder}. Zero when no order this adapter placed is
    ///      outstanding.
    /// @return The number of pending orders.
    function pendingOrderCount() external view returns (uint256);

    /// @notice How much of a token the adapter's pending orders sell in total.
    /// @dev The sum of the sell amounts of every pending order selling `token`. {sweep}
    ///      retains this much and returns only what exceeds it.
    /// @param token The token to total.
    /// @return The total amount committed to pending orders.
    function committedAmount(address token) external view returns (uint256);

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
