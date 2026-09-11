// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnerImmutable} from "./IOwnerImmutable.sol";

/// @title ICowProtocolAdapter
/// @notice Interface for the CoW Protocol adapter. The owner is the contract the adapter
///         instance is bound to; see {IOwnerImmutable} for the access-control surface.
interface ICowProtocolAdapter is IOwnerImmutable {
    /// @notice The stage of an order's life the adapter has recorded.
    /// @dev `None` is the zero value. `Filled` and `Cancelled` are terminal, and a record is
    ///      never deleted, so a digest in either state can never be placed again.
    enum OrderStatus {
        None,
        Pending,
        Filled,
        Cancelled
    }

    /// @notice What the adapter establishes about whether a pending order has filled.
    /// @dev Every pending order has one of these verdicts. Settlement's fill record decides it
    ///      where that record is conclusive, the lane's relayer allowance otherwise.
    /// @param Unfilled No sell tokens have been pulled for the order.
    /// @param Filled The order has been filled and its bought tokens delivered to the owner.
    /// @param Invalidated Settlement holds the cancellation marker for the order.
    enum FillVerdict {
        Unfilled,
        Filled,
        Invalidated
    }

    /// @notice The caller-supplied part of an order.
    /// @dev The remaining fields are fixed by the adapter: `kind` is sell, `receiver` is the
    ///      owner, `partiallyFillable` is false, `feeAmount` is zero, and both balance fields
    ///      are plain ERC-20.
    /// @param sellToken The token to sell.
    /// @param buyToken The token to buy.
    /// @param sellAmount The exact amount of `sellToken` to sell.
    /// @param buyAmount The least `buyToken` the order accepts for it.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param appData The hash of the order's off-chain metadata.
    struct OrderParams {
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    /// @notice The adapter's record of an order it placed.
    /// @dev Keyed by the order's EIP-712 digest and kept after the order resolves.
    /// @param sellToken The token the order sells.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param status The stage of the order's life.
    /// @param lane The index of the lane that owns the order and holds its sell tokens.
    /// @param sellAmount The exact amount of `sellToken` the order sells.
    /// @param buyAmount The least buy token the order accepts for it.
    struct OrderRecord {
        address sellToken;
        uint32 validTo;
        OrderStatus status;
        uint8 lane;
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
    /// @param sellAmount The exact amount of `sellToken` the order sells.
    /// @param buyAmount The least `buyToken` the order accepts for it.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param lane The address of the lane that owns the order and holds its sell tokens.
    /// @param uid The identifier settlement records fills of the order under.
    event OrderPlaced(
        bytes32 indexed orderDigest,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        address lane,
        bytes uid
    );

    /// @notice Emitted when an order needs a lane index that has never been used.
    /// @param index The lane's index.
    /// @param lane The lane's address.
    event LaneDeployed(uint256 indexed index, address indexed lane);

    /// @notice Emitted when a filled order is resolved and its commitment released.
    /// @param orderDigest The order's EIP-712 digest.
    /// @param sellToken The token the order sold.
    /// @param sellAmount The commitment released, which is what the order sold.
    /// @param filled The sell amount settlement records the order as filled for, zero where the
    ///        fill was established from the lane's allowance instead.
    /// @param returned The amount drained from the lane to the owner.
    event OrderResolved(
        bytes32 indexed orderDigest, address indexed sellToken, uint256 sellAmount, uint256 filled, uint256 returned
    );

    /// @notice Emitted when an order is cancelled and its sell tokens returned.
    /// @param orderDigest The order's EIP-712 digest.
    /// @param sellToken The token the order sold.
    /// @param returned The amount drained from the lane to the owner.
    event OrderCancelled(bytes32 indexed orderDigest, address indexed sellToken, uint256 returned);

    /// @notice Emitted when a token balance held by the adapter is returned to the owner.
    /// @param token The token that was swept.
    /// @param amount The amount transferred to the owner.
    event TokensSwept(address indexed token, uint256 amount);

    /// @notice Emitted when a token balance held by a lane is returned to the owner.
    /// @param laneIndex The lane that was swept.
    /// @param token The token that was swept.
    /// @param amount The amount transferred to the owner.
    event LaneSwept(uint256 indexed laneIndex, address indexed token, uint256 amount);

    /// @notice Thrown when the zero address is supplied as the settlement contract.
    error ZeroSettlement();

    /// @notice Thrown when the settlement contract reports the zero address as its relayer.
    error ZeroVaultRelayer();

    /// @notice Thrown when the settlement contract reports a zero EIP-712 domain separator.
    error ZeroDomainSeparator();

    /// @notice Thrown when a sweep is attempted for a token no balance is held of.
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

    /// @notice Thrown when an order is placed with an expiry that has already passed.
    /// @param validTo The order's expiry.
    /// @param timestamp The block timestamp it was compared against.
    error ValidToInPast(uint32 validTo, uint256 timestamp);

    /// @notice Thrown when an order's sell token delivered less than was pulled.
    /// @dev Measured as the lane's balance change across the pull, so a token taking a fee on
    ///      transfer is rejected.
    /// @param requested The amount the adapter pulled.
    /// @param received The balance change it measured.
    error SellTokenShortfall(uint256 requested, uint256 received);

    /// @notice Thrown when an order is placed under a digest this adapter has already used.
    /// @dev A digest is spent for the adapter's lifetime, whether its order is pending or has
    ///      since resolved. Vary any order field to place another order.
    /// @param orderDigest The digest already recorded.
    error OrderDigestUsed(bytes32 orderDigest);

    /// @notice Thrown when every lane is already carrying a pending order on the sell token.
    /// @dev A sell token has 256 lanes. Resolve or cancel an order on the token to free one.
    /// @param sellToken The token whose lanes are exhausted.
    error NoFreeLane(address sellToken);

    /// @notice Thrown when a cancellation names an order the adapter establishes has filled.
    /// @dev Resolve it instead. `filled` is zero where the fill was established from the lane's
    ///      allowance rather than from settlement's record.
    /// @param orderDigest The digest named.
    /// @param filled The amount settlement records the order as filled for.
    error OrderFilled(bytes32 orderDigest, uint256 filled);

    /// @notice Thrown when a resolution names an order the adapter cannot establish has filled.
    /// @dev Cancel it instead.
    /// @param orderDigest The digest named.
    /// @param verdict What the adapter establishes about the order.
    error OrderNotFilled(bytes32 orderDigest, FillVerdict verdict);

    /// @notice Thrown when an order the adapter placed is still pending.
    /// @dev Read {fillVerdict} for each of {pendingOrderDigests} to see which orders are
    ///      outstanding.
    /// @param pendingOrders How many orders are still pending.
    error OrdersStillPending(uint256 pendingOrders);

    /// @notice Thrown when a call names a digest that carries no pending order.
    /// @dev Covers a digest never placed and one whose order has already resolved or been
    ///      cancelled.
    /// @param orderDigest The digest named.
    error OrderNotPending(bytes32 orderDigest);

    /// @notice Thrown when a call names an index at or above the number of lanes deployed.
    /// @param index The index asked for.
    /// @param deployed How many lanes exist.
    error LaneIndexOutOfRange(uint256 index, uint256 deployed);

    /// @notice Thrown when a lane sweep names a lane that is carrying a pending order on the
    ///         token.
    /// @param laneIndex The lane named.
    /// @param token The token named.
    error LaneOccupied(uint256 laneIndex, address token);

    /// @notice Thrown when a lane index at or above the lane count is supplied.
    /// @dev Distinct from {LaneIndexOutOfRange}, which is about lanes not yet deployed: such an
    ///      index names no lane at any point in the adapter's life.
    /// @param index The index supplied.
    /// @param laneCount How many lanes a sell token has.
    error LaneIndexTooLarge(uint256 index, uint256 laneCount);

    /// @notice Places an order, pulling its sell tokens from the owner and granting the vault
    ///         relayer the allowance settlement needs to collect them.
    /// @dev The order is assigned the lowest-numbered lane carrying no pending order on
    ///      `params.sellToken`, deploying that lane where its index has never been used. The
    ///      lane, not the adapter, owns the order: it holds the sell tokens, grants the
    ///      allowance and is the address encoded in the returned identifier.
    ///
    ///      Reverts with {NoFreeLane} where the token has all 256 lanes occupied, and with
    ///      {SellTokenShortfall} where the lane's balance grows by less than `params.sellAmount`.
    ///      Any excess delivered is left on the lane and reaches the owner when the order
    ///      resolves.
    /// @param params The caller-supplied part of the order.
    /// @return uid The identifier settlement records fills of the order under.
    function placeOrder(OrderParams calldata params) external returns (bytes memory uid);

    /// @notice Resolves one filled order, releasing its commitment and draining its lane to the
    ///         owner.
    /// @dev Reverts with {OrderNotFilled} unless {fillVerdict} establishes the order as filled;
    ///      clearing one that has not is {cancelOrder}'s job. The incremental counterpart of
    ///      {requireNoPendingOrders}, for a pending set too large to resolve in one transaction.
    ///
    ///      No tokens move on the order's account: the fill delivered the bought tokens to the
    ///      owner and collected the sell amount. The drain carries home a placement overshoot or
    ///      a donation, and nothing where neither happened.
    /// @param orderDigest The EIP-712 digest of the order to resolve.
    function resolveOrder(bytes32 orderDigest) external;

    /// @notice Resolves every filled order the adapter has placed, and reverts unless none is left
    ///         pending.
    /// @dev The gate on a consumer's own state machine. Succeeds only where no order remains
    ///      pending, and reverts with {OrdersStillPending} otherwise, undoing the resolutions it
    ///      made. Resolves each filled order by the same steps {resolveOrder} takes for one, so
    ///      nothing has to be resolved individually first.
    function requireNoPendingOrders() external;

    /// @notice Cancels a pending order, retracting it at settlement and returning its sell
    ///         tokens to the owner.
    /// @dev Invalidates the order at settlement through its lane, drops the lane's relayer
    ///      allowance to zero and drains it to the owner. Nothing else takes an order out of the
    ///      pending set on expiry: an expired order stays pending until this is called.
    ///
    ///      Reverts with {OrderFilled} for an order established as filled, which is
    ///      {resolveOrder}'s to take. A solver may fill the order between the decision to cancel
    ///      and this call, in which case it reverts.
    /// @param orderDigest The EIP-712 digest of the order to cancel.
    function cancelOrder(bytes32 orderDigest) external;

    /// @notice Returns a token balance held by the adapter itself to the owner.
    /// @dev The destination is the immutable owner. The whole balance is returned: an order's
    ///      sell tokens are held by its lane, so anything the adapter holds arrived unsolicited.
    ///      Reverts with {NothingToSweep} where the balance is zero.
    /// @param token The token to return.
    function sweep(address token) external;

    /// @notice Returns a token balance held by one of the adapter's lanes to the owner.
    /// @dev For balances that arrived at a lane outside an order; a lane's own order sends its
    ///      leftovers home when it resolves. Reverts with {LaneOccupied} where the lane carries
    ///      a pending order on `token`, and with {NothingToSweep} where the balance is zero. A
    ///      lane carrying an order on another token is sweepable for this one.
    /// @param laneIndex The lane to sweep.
    /// @param token The token to return.
    function sweepLane(uint256 laneIndex, address token) external;

    /// @notice Whether the adapter endorses the order carried by an EIP-712 digest under a given
    ///         lane, the judgement behind the ERC-1271 check settlement makes on that lane.
    /// @dev Returns the magic value only where the digest carries a pending order whose record
    ///      names `lane`, so a digest never placed, one already resolved, one cancelled, and one
    ///      pending under a different lane all return zero.
    ///
    ///      A pending order is endorsed for as long as its record stays pending, `validTo`
    ///      included: settlement rejects an expired order itself.
    /// @param lane The lane being asked, which settlement takes from the order's identifier.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return magicValue `IERC1271.isValidSignature.selector` where the adapter endorses the
    ///         order under that lane, zero otherwise.
    function isValidSignatureForLane(address lane, bytes32 orderDigest) external view returns (bytes4 magicValue);

    /// @notice The unique identifier settlement would record fills of an order under, were it
    ///         placed on a given lane.
    /// @dev Derived from the order's EIP-712 digest, the lane's address and `validTo`. Read
    ///      {nextLane} for the index an order not yet placed would be given, or
    ///      {orderRecord}`.lane` for one already placed. Reverts with {LaneIndexTooLarge} where
    ///      `laneIndex` names no lane.
    /// @param params The caller-supplied part of the order.
    /// @param laneIndex The index of the lane owning the order, below the lane count.
    /// @return The order's 56-byte unique identifier.
    function orderUid(OrderParams calldata params, uint256 laneIndex) external view returns (bytes memory);

    /// @notice The lane the next order selling a token would be placed on.
    /// @dev The lowest-numbered lane carrying no pending order on `sellToken`. Reverts with
    ///      {NoFreeLane} where the token has none. The answer holds until the next {placeOrder}
    ///      on that token.
    /// @param sellToken The token the order would sell.
    /// @return lane The lane's address.
    /// @return index The lane's index.
    function nextLane(address sellToken) external view returns (address lane, uint256 index);

    /// @notice The address of the lane at an index, whether or not it has been deployed yet.
    /// @dev A lane's address is a function of its index and this adapter alone. Reverts with
    ///      {LaneIndexTooLarge} at or above the lane count.
    /// @param index The lane's index, below the lane count.
    /// @return The lane's address.
    function laneAt(uint256 index) external view returns (address);

    /// @notice Which lanes are carrying a pending order on a token.
    /// @dev A bit field: bit `i` is set where lane `i` carries a pending order selling `token`.
    ///      A lane may carry orders on several tokens at once.
    /// @param token The sell token to report on.
    /// @return The bit field of occupied lanes.
    function laneOccupancy(address token) external view returns (uint256);

    /// @notice How many lanes have been deployed.
    /// @dev Rises only in {placeOrder}, and only for an index never used before; freeing a lane
    ///      never lowers it. Deployed lanes are the indices `0` to this count minus one.
    /// @return The number of lanes deployed.
    function deployedLaneCount() external view returns (uint256);

    /// @notice The implementation every lane delegates its behaviour to.
    /// @dev Deployed by this adapter at construction and bound to it. Lanes are minimal proxies
    ///      to it.
    /// @return The lane implementation address.
    function laneImplementation() external view returns (address);

    /// @notice The order recorded under a digest.
    /// @dev A `status` of `None` means the digest was never placed. The record is retained after
    ///      the order resolves.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return The order record, or a zeroed struct if the digest was never placed.
    function orderRecord(bytes32 orderDigest) external view returns (OrderRecord memory);

    /// @notice What the adapter establishes about whether a pending order has filled.
    /// @dev Reverts with {OrderNotPending} for a digest that carries no pending order. The
    ///      judgement does not depend on `block.timestamp`.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return verdict What the adapter establishes.
    /// @return filled The amount settlement records the order as filled for, which is zero where
    ///         the verdict came from the lane's allowance instead.
    function fillVerdict(bytes32 orderDigest) external view returns (FillVerdict verdict, uint256 filled);

    /// @notice How many orders the adapter has placed and not resolved.
    /// @dev The size of the set {pendingOrderDigests} returns.
    /// @return The number of pending orders.
    function pendingOrderCount() external view returns (uint256);

    /// @notice The digests of every order the adapter has placed and not resolved.
    /// @dev A digest joins the set at {placeOrder} and leaves it when the order resolves or is
    ///      cancelled; the record itself is kept either way. Order within the set is not stable.
    /// @return The pending order digests.
    function pendingOrderDigests() external view returns (bytes32[] memory);

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
