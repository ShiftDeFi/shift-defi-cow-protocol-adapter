// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOwnerImmutable} from "./IOwnerImmutable.sol";

/// @title ICowProtocolAdapter
/// @notice Interface for the CoW Protocol adapter. The owner is the contract the adapter
///         instance is bound to; see {IOwnerImmutable} for the access-control surface.
interface ICowProtocolAdapter is IOwnerImmutable {
    /// @notice The stage of an order's life the adapter has recorded.
    /// @dev `None` is the zero value, so a digest that was never placed reads as `None` without
    ///      ever having been written. `Filled` and `Cancelled` are terminal, and a record is
    ///      never deleted, so a digest in either state can never be placed again.
    enum OrderStatus {
        None,
        Pending,
        Filled,
        Cancelled
    }

    /// @notice What the adapter establishes about whether a pending order has filled.
    /// @dev Total: every pending order has one of these verdicts at any moment, and there is no
    ///      arm for "cannot determine". Settlement's fill record decides it wherever that record
    ///      is conclusive, and the lane's relayer allowance decides it otherwise.
    ///
    ///      The allowance can stand in for the record because a lane carries at most one pending
    ///      order per token, so nothing but that order can spend the row: the adapter sets it to
    ///      the order's sell amount at placement and only a pull by the relayer lowers it. That
    ///      makes a shortfall proof of a pull, and a pull proof of a fill, since a fill-or-kill
    ///      order is pulled only as a whole. Nothing clears an allowance for a gas refund, which
    ///      is what the fill record cannot say for itself once the order has expired.
    /// @param Unfilled No sell tokens have been pulled for the order.
    /// @param Filled The order has been filled, so its sell tokens are gone and its bought
    ///        tokens have already been delivered to the owner.
    /// @param Invalidated Settlement holds the cancellation marker for the order. Only the
    ///        order's own lane can write it, and only {cancelOrder} makes it do so, which marks
    ///        the record in the same call — so a pending order reads this only if settlement was
    ///        made to hold the marker some other way.
    enum FillVerdict {
        Unfilled,
        Filled,
        Invalidated
    }

    /// @notice The caller-supplied part of an order.
    /// @dev The remaining fields of a CoW Protocol order are fixed by the adapter: `kind` is
    ///      sell, `receiver` is the owner, `partiallyFillable` is false, `feeAmount` is zero,
    ///      and both balance fields are plain ERC-20.
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
    /// @dev Recorded under the order's EIP-712 digest, the value settlement presents for
    ///      signature verification, and kept after the order resolves: `status` is what separates
    ///      a pending order from a resolved one.
    /// @param sellToken The token the order sells.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param status The stage of the order's life.
    /// @param lane The index of the lane that owns the order, holds its sell tokens and is the
    ///        address encoded in its identifier.
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

    /// @notice Emitted when a lane is deployed, which happens the first time an order needs a
    ///         lane index that has never been used.
    /// @dev Lanes are reused: a lane is freed when its order resolves and is handed to the next
    ///      order that needs one, so the number deployed settles at the greatest number of
    ///      orders ever pending on one sell token at once, not at the number of orders placed.
    /// @param index The lane's index.
    /// @param lane The lane's address.
    event LaneDeployed(uint256 indexed index, address indexed lane);

    /// @notice Emitted when a filled order is resolved and its commitment released.
    /// @dev No tokens move on the order's account: a fill delivered its bought tokens to the
    ///      owner and collected the order's whole sell amount in the same settlement.
    ///      `returned` is what was left on the lane afterwards and has now been sent to the
    ///      owner — anything delivered above the sell amount at placement, plus anything that
    ///      arrived unsolicited.
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
    /// @dev `returned` is what the order's lane held of the sell token, which for a cancellation
    ///      is the order's whole sell amount plus anything that arrived unsolicited: an order the
    ///      adapter is willing to cancel is one it has established was never pulled.
    /// @param orderDigest The order's EIP-712 digest.
    /// @param sellToken The token the order sold.
    /// @param returned The amount drained from the lane to the owner.
    event OrderCancelled(bytes32 indexed orderDigest, address indexed sellToken, uint256 returned);

    /// @notice Emitted when a token balance is returned to the owner.
    /// @param token The token that was swept.
    /// @param amount The amount transferred to the owner.
    event TokensSwept(address indexed token, uint256 amount);

    /// @notice Emitted when a token balance held by a lane is returned to the owner.
    /// @dev Distinct from {TokensSwept} because the balance came from a lane rather than from the
    ///      adapter, and a consumer reconciling where funds sat needs to tell the two apart.
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

    /// @notice Thrown when an order is placed under a digest this adapter has already used.
    /// @dev A digest is spent for the adapter's lifetime, whether its order is still pending or
    ///      has since filled or been cancelled: settlement keys fills by identifier and an
    ///      identifier derives from the digest, so a second order under the same digest could
    ///      never fill. Vary any order field to place another order with otherwise identical
    ///      parameters.
    /// @param orderDigest The digest already recorded.
    error OrderDigestUsed(bytes32 orderDigest);

    /// @notice Thrown when every lane is already carrying a pending order on the sell token.
    /// @dev A sell token has 256 lanes, against an expected handful of concurrent orders. Resolve
    ///      or cancel an order on the token to free one.
    /// @param sellToken The token whose lanes are exhausted.
    error NoFreeLane(address sellToken);

    /// @notice Thrown when a cancellation names an order the adapter establishes has filled.
    /// @dev Cancelling one would overwrite its fill record with settlement's cancellation marker,
    ///      turning the record of a fill into one that reads as cancelled. Resolve it instead.
    ///      `filled` is settlement's fill record, zero where the fill was established from the
    ///      lane's allowance instead.
    /// @param orderDigest The digest named.
    /// @param filled The amount settlement records the order as filled for.
    error OrderFilled(bytes32 orderDigest, uint256 filled);

    /// @notice Thrown when a resolution names an order the adapter cannot establish has filled.
    /// @dev Resolution is for orders that filled. An order that did not is not resolved but
    ///      cancelled, which is the decision to stop waiting and is the owner's to make.
    /// @param orderDigest The digest named.
    /// @param verdict What the adapter establishes about the order instead.
    error OrderNotFilled(bytes32 orderDigest, FillVerdict verdict);

    /// @notice Thrown when an order the adapter placed is still pending.
    /// @dev {requireNoPendingOrders} is a gate, so it either leaves no order pending or reverts: a
    ///      partial resolution would report that a batch had settled while an order it placed was
    ///      still live and fundable. Read {fillVerdict} for each of {pendingOrderDigests} to see
    ///      which orders are holding it up and whether each needs waiting on or cancelling.
    /// @param pendingOrders How many orders are still pending.
    error OrdersStillPending(uint256 pendingOrders);

    /// @notice Thrown when a call names a digest that carries no pending order.
    /// @dev Covers a digest never placed and one whose order has already resolved or been
    ///      cancelled, since a record is kept rather than deleted.
    /// @param orderDigest The digest named.
    error OrderNotPending(bytes32 orderDigest);

    /// @notice Thrown when a call names an index at or above the number of lanes deployed.
    /// @dev Reachable only from {sweepLane}, which can be asked about a lane that does not exist
    ///      yet. Lane allocation also asserts it, where it is unreachable: an index is handed out
    ///      only when every lower one is already carrying an order, and a lane carrying an order
    ///      was deployed to be given it — the assertion is what stops a lane being addressed
    ///      before it has code.
    /// @param index The index asked for.
    /// @param deployed How many lanes exist.
    error LaneIndexOutOfRange(uint256 index, uint256 deployed);

    /// @notice Thrown when a lane sweep names a lane that is carrying a pending order on the
    ///         token.
    /// @dev The sweep takes a lane's whole balance of the token, which while an order is pending
    ///      would be that order's sell tokens. Cancel the order to release them instead.
    /// @param laneIndex The lane named.
    /// @param token The token named.
    error LaneOccupied(uint256 laneIndex, address token);

    /// @notice Thrown when a lane index outside the addressable range is supplied.
    /// @dev Distinct from {LaneIndexOutOfRange}, which is about lanes not yet deployed: an
    ///      index at or above the lane count names no lane at any point in the adapter's life,
    ///      because occupancy is tracked in a 256-bit field and a record holds the index in a
    ///      `uint8`.
    /// @param index The index supplied.
    /// @param laneCount How many lanes a sell token has.
    error LaneIndexTooLarge(uint256 index, uint256 laneCount);

    /// @notice Places an order, pulling its sell tokens from the owner and granting the vault
    ///         relayer the allowance settlement needs to collect them.
    /// @dev Records the order's digest under {orderRecord}, which is what the adapter endorses
    ///      through {isValidSignatureForLane}.
    ///
    ///      The order is assigned a lane — the lowest-numbered one carrying no pending order on
    ///      `params.sellToken` — and that lane, not the adapter, is the order's owner: it holds
    ///      the sell tokens, grants the relayer's allowance and is the address encoded in the
    ///      returned identifier. A lane is deployed only where the index assigned has never been
    ///      used before, and {NoFreeLane} is thrown where the token has all 256 carrying an
    ///      order.
    ///
    ///      Sell tokens are pulled from the caller to that lane within this call, and the lane's
    ///      balance must grow by at least `params.sellAmount`, so a token taking a fee on
    ///      transfer reverts with {SellTokenShortfall}. An order therefore always sells exactly
    ///      `params.sellAmount`, and its identifier is the one {orderUid} derives from the same
    ///      parameters and the lane index in its record. Any excess delivered is left on the
    ///      lane and reaches the owner when the order resolves.
    ///
    ///      The relayer's allowance on the lane is set to `params.sellAmount` outright. Because
    ///      no other order shares that lane's allowance row for the token, what remains of it is
    ///      a witness for this order alone: see {fillVerdict}.
    /// @param params The caller-supplied part of the order.
    /// @return uid The identifier settlement records fills of the order under.
    function placeOrder(OrderParams calldata params) external returns (bytes memory uid);

    /// @notice Resolves one filled order.
    /// @dev The incremental path for when {requireNoPendingOrders} cannot complete; normal
    ///      operation uses that instead. A filled order leaves the pending set only through
    ///      these two — {cancelOrder} refuses one — so this is what recovers a pending set grown
    ///      too large to resolve in a single transaction.
    ///
    ///      Reverts with {OrderNotFilled} unless {fillVerdict} establishes the order as filled;
    ///      clearing one that has not is {cancelOrder}'s job. Only ever removing an established
    ///      fill is what keeps {pendingOrderCount} reaching zero trustworthy however this is
    ///      called.
    ///
    ///      No tokens move on the order's account: the fill delivered the bought tokens to the
    ///      owner and collected the sell amount. Draining the lane carries home a placement
    ///      overshoot or a donation, and nothing where neither happened.
    /// @param orderDigest The EIP-712 digest of the order to resolve.
    function resolveOrder(bytes32 orderDigest) external;

    /// @notice Resolves every filled order the adapter has placed, and reverts unless none is left
    ///         pending.
    /// @dev This is the gate on a consumer's own state machine, called as part of the step that
    ///      depends on a swap's outcome. It succeeds only where no order remains pending, and
    ///      reverts with {OrdersStillPending} otherwise, so a consumer's step reverts on an unmet
    ///      precondition exactly as it would on any other. Resolution is never a transaction of
    ///      its own performed by someone else: an order stays pending until the owner calls this
    ///      or {resolveOrder}, and there is no keeper to depend on.
    ///
    ///      This call resolves every order it establishes as filled, by the same steps
    ///      {resolveOrder} takes for one. Nothing has to be resolved individually first, and for
    ///      a batch whose orders all filled this call on its own is the whole of resolution. An
    ///      order that did not fill is left pending and makes the whole call revert, undoing the
    ///      rest; clearing such an order is {cancelOrder}'s job.
    ///
    ///      Each order's verdict rests only on its own fill record and its own lane's allowance
    ///      row, and resolving an order touches only that row, so resolving one cannot change
    ///      what another resolves to.
    function requireNoPendingOrders() external;

    /// @notice Cancels a pending order, retracting it at settlement and returning its sell
    ///         tokens to the owner.
    /// @dev The decision to stop waiting, and the owner's alone to make. Nothing about an order
    ///      expires it out of the pending set: settlement refuses to fill an expired order, but
    ///      the order stays fundable-looking and its lane stays occupied until this is called.
    ///
    ///      Invalidates the order at settlement through its lane — settlement accepts the call
    ///      only from the address encoded in the identifier — then drops the lane's relayer
    ///      allowance to zero and drains it to the owner. The refund is unconditional because the
    ///      verdict is: an order this function agrees to cancel is one whose lane allowance
    ///      proves nothing was ever pulled for it, so the sell tokens are still there.
    ///
    ///      Reverts with {OrderFilled} for an order established as filled, which is
    ///      {resolveOrder}'s to take. A cancellation is not atomic with the decision to make one:
    ///      between the two, a solver may still fill the order, in which case this reverts and
    ///      the order is resolved instead.
    /// @param orderDigest The EIP-712 digest of the order to cancel.
    function cancelOrder(bytes32 orderDigest) external;

    /// @notice Returns a token balance held by the adapter itself to the owner.
    /// @dev The destination is the immutable owner, and no function on this adapter or on a lane
    ///      takes a destination as a parameter.
    ///
    ///      The whole balance is returned, with no committed amount retained: an order's sell
    ///      tokens are held by its lane rather than by the adapter, so anything the adapter holds
    ///      arrived unsolicited and belongs to the owner. What a lane holds is returned when its
    ///      order resolves or is cancelled.
    /// @param token The token to return.
    function sweep(address token) external;

    /// @notice Returns a token balance held by one of the adapter's lanes to the owner.
    /// @dev The counterpart of {sweep} for balances that arrived at a lane rather than at the
    ///      adapter. A lane's own order sends its leftovers home when it resolves, so this is for
    ///      what turns up on a lane that is not carrying an order on that token — where nothing
    ///      else would ever come along to move it.
    ///
    ///      Reverts with {LaneOccupied} where the lane is carrying a pending order on `token`,
    ///      since the balance would then be that order's sell tokens; releasing those is
    ///      {cancelOrder}'s job. A lane carrying an order on some *other* token is sweepable for
    ///      this one: the two balances are separate and so are the allowance rows behind them.
    /// @param laneIndex The lane to sweep.
    /// @param token The token to return.
    function sweepLane(uint256 laneIndex, address token) external;

    /// @notice Whether the adapter endorses the order carried by an EIP-712 digest under a given
    ///         lane, the judgement behind the ERC-1271 check settlement makes on that lane.
    /// @dev Returns the magic value if and only if the digest carries a pending order *and* that
    ///      order's record names `lane`, so a digest never placed, one already resolved, one
    ///      cancelled, and one pending under a different lane all return zero. The lane check is
    ///      what keeps a lane from endorsing an order another lane holds the sell tokens for:
    ///      settlement asks the address encoded in the identifier, and would otherwise fill an
    ///      order out of a lane that was never funded for it.
    ///
    ///      ERC-1271 makes the check `view`, so the endorsement can only come from state
    ///      {placeOrder} wrote, and {placeOrder} is owner-gated: no other caller can bring a
    ///      digest into the state this function endorses.
    ///
    ///      A pending order is endorsed for as long as its record stays pending, `validTo`
    ///      included: settlement rejects an expired order itself, and the record leaves the
    ///      pending state only through {resolveOrder} or {cancelOrder}. An order that has filled
    ///      but not yet been resolved is therefore still endorsed, which settlement's own
    ///      accounting makes inert — a fill-or-kill order it has already filled cannot be filled
    ///      again.
    /// @param lane The lane being asked, which settlement takes from the order's identifier.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return magicValue `IERC1271.isValidSignature.selector` where the adapter endorses the
    ///         order under that lane, zero otherwise.
    function isValidSignatureForLane(address lane, bytes32 orderDigest) external view returns (bytes4 magicValue);

    /// @notice The unique identifier settlement would record fills of an order under, were it
    ///         placed on a given lane.
    /// @dev Derived from the order's EIP-712 digest, the lane's address and `validTo`. The lane
    ///      is a parameter because it is not a function of the order: {placeOrder} assigns the
    ///      lowest free one, so a caller pre-building an order reads {nextLane} for the index it
    ///      would be given, and one identifying an order already placed reads
    ///      {orderRecord}`.lane`. Reverts with {LaneIndexTooLarge} where `laneIndex` names no
    ///      lane, so an identifier is never returned for a lane that cannot exist.
    /// @param params The caller-supplied part of the order.
    /// @param laneIndex The index of the lane owning the order, below the lane count.
    /// @return The order's 56-byte unique identifier.
    function orderUid(OrderParams calldata params, uint256 laneIndex) external view returns (bytes memory);

    /// @notice The lane the next order selling a token would be placed on.
    /// @dev The lowest-numbered lane carrying no pending order on `sellToken`. Reverts with
    ///      {NoFreeLane} where the token has none, which is the same condition {placeOrder}
    ///      would fail on. The answer holds until the next {placeOrder} on that token, and
    ///      {placeOrder} is owner-gated, so a caller that serialises its own placements can
    ///      derive an order's identifier before placing it.
    /// @param sellToken The token the order would sell.
    /// @return lane The lane's address.
    /// @return index The lane's index.
    function nextLane(address sellToken) external view returns (address lane, uint256 index);

    /// @notice The address of the lane at an index, whether or not it has been deployed yet.
    /// @dev A lane's address is a pure function of its index and this adapter, so it is known
    ///      before the lane exists and can never be taken by anyone else: the address derives
    ///      from the adapter as deployer, so no other account can deploy to it. Undeployed is
    ///      not unbounded: reverts with {LaneIndexTooLarge} at or above the lane count, where no
    ///      index can ever be assigned.
    /// @param index The lane's index, below the lane count.
    /// @return The lane's address.
    function laneAt(uint256 index) external view returns (address);

    /// @notice Which lanes are carrying a pending order on a token.
    /// @dev A bit field: bit `i` is set where lane `i` carries a pending order selling `token`.
    ///      A lane may carry orders on several tokens at once — the rows those orders occupy are
    ///      in different tokens' allowance mappings and do not interact.
    /// @param token The sell token to report on.
    /// @return The bit field of occupied lanes.
    function laneOccupancy(address token) external view returns (uint256);

    /// @notice How many lanes have been deployed.
    /// @dev Rises only in {placeOrder}, and only when an order is assigned an index never used
    ///      before; freeing a lane never lowers it and never destroys a lane. Deployed lanes are
    ///      the indices `0` to this count minus one.
    /// @return The number of lanes deployed.
    function deployedLaneCount() external view returns (uint256);

    /// @notice The implementation every lane delegates its behaviour to.
    /// @dev Deployed by this adapter at construction and bound to it, so lanes cannot be shared
    ///      between adapters. Lanes themselves are minimal proxies to it.
    /// @return The lane implementation address.
    function laneImplementation() external view returns (address);

    /// @notice The order recorded under a digest.
    /// @dev A `status` of `None` means the digest was never placed. The record is retained after
    ///      the order resolves, so a non-pending status is not the absence of a record. This is
    ///      the adapter's record of what it placed; what has filled is read from {settlement}.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return The order record, or a zeroed struct if the digest was never placed.
    function orderRecord(bytes32 orderDigest) external view returns (OrderRecord memory);

    /// @notice What the adapter establishes about whether a pending order has filled.
    /// @dev Exposed so that a consumer can tell what an order needs — waiting on, resolving or
    ///      cancelling — without probing a revert. Reverts with {OrderNotPending} for a digest
    ///      that carries no pending order, there being nothing to judge.
    ///
    ///      The judgement does not depend on `block.timestamp`. An expired order whose fill
    ///      record a solver has cleared reads exactly as it did before expiry, because the
    ///      lane's allowance survives the clearing and answers on the record's behalf.
    /// @param orderDigest The order's EIP-712 digest.
    /// @return verdict What the adapter establishes.
    /// @return filled The amount settlement records the order as filled for, which is zero where
    ///         the verdict came from the lane's allowance instead.
    function fillVerdict(bytes32 orderDigest) external view returns (FillVerdict verdict, uint256 filled);

    /// @notice How many orders the adapter has placed and not resolved.
    /// @dev The size of the set {pendingOrderDigests} returns, so the two can never disagree.
    ///      Zero when no order this adapter placed is outstanding, which is what a consumer
    ///      checks before repointing away from this adapter: an order's identifier is bound to
    ///      the address that placed it, so repointing while one is pending orphans it.
    /// @return The number of pending orders.
    function pendingOrderCount() external view returns (uint256);

    /// @notice The digests of every order the adapter has placed and not resolved.
    /// @dev A digest joins the set when {placeOrder} records the order and leaves it when the
    ///      order resolves or is cancelled; the record itself is kept either way, so a digest
    ///      absent from this set still reads back from {orderRecord}. Order within the set is
    ///      not stable — a removal moves the last entry into the vacated slot.
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
