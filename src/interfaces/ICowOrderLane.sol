// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title ICowOrderLane
/// @notice Interface for a lane: the identity an adapter borrows so that one of its orders owns
///         a row of a sell token's allowance mapping to itself.
/// @dev A lane exists because CoW Protocol binds four roles to the single address an order names
///      as its owner — it holds the sell tokens, grants the vault relayer its allowance, answers
///      the ERC-1271 check, and is the only caller settlement's `invalidateOrder` accepts. An
///      allowance is keyed `allowance[owner][spender]` and the spender is fixed, so orders that
///      name one owner share one row and a shortfall in it cannot be attributed to any single
///      order. Orders that name different lanes do not share a row.
///
///      A lane holds no state and knows nothing about the order it carries. Its adapter, that
///      adapter's owner, the settlement contract and the vault relayer are all fixed in the
///      implementation the lane delegates to, so no caller supplies any of them: the lane's whole
///      surface takes a token, an amount and an order identifier, and there is no parameter that
///      could name a destination for value.
interface ICowOrderLane is IERC1271 {
    /// @notice Thrown when any address other than the adapter calls the lane.
    /// @param caller The rejected caller.
    error NotAdapter(address caller);

    /// @notice Grants the vault relayer an allowance over the lane's balance of a token.
    /// @dev An absolute set rather than an increase, which is correct because a lane carries at
    ///      most one pending order per token: there is no sibling order whose share of the
    ///      allowance an absolute set could revoke. Uses `forceApprove`, so a token that refuses
    ///      to move a non-zero allowance directly to another non-zero value is handled.
    /// @param token The token to grant the allowance over.
    /// @param amount The allowance to leave in place.
    function approveRelayer(address token, uint256 amount) external;

    /// @notice Cancels an order this lane owns, so no trade against it can settle.
    /// @dev Settlement accepts the call only from the address encoded in `orderUid`, which is
    ///      why cancellation is routed through the lane rather than made by the adapter.
    /// @param orderUid The order's unique identifier.
    function invalidateOrder(bytes calldata orderUid) external;

    /// @notice Sends the lane's whole balance of a token to the adapter's owner.
    /// @dev The destination is fixed in the implementation, so the caller does not choose it.
    ///      The whole balance is correct because a lane carries at most one pending order per
    ///      token: everything it holds of that token either belongs to that order or arrived
    ///      unsolicited, and both are the owner's.
    /// @param token The token to send.
    /// @return amount The amount sent, which is zero where the lane held none.
    function drain(address token) external returns (uint256 amount);

    /// @notice Whether the adapter endorses the order carried by an EIP-712 digest under this
    ///         lane, the ERC-1271 check settlement makes before filling an order the lane owns.
    /// @dev Delegates the judgement to the adapter, which holds the order records: the lane has
    ///      no state of its own to answer from. The adapter endorses the digest only where its
    ///      record is pending *and* names this lane, so a lane can never endorse an order that
    ///      another lane owns and pays for.
    /// @param orderDigest The order's EIP-712 digest, the value settlement presents for
    ///        verification.
    /// @param signature Ignored; present because ERC-1271 fixes this signature.
    /// @return magicValue `IERC1271.isValidSignature.selector` where the adapter endorses the
    ///         order, zero otherwise.
    function isValidSignature(bytes32 orderDigest, bytes calldata signature)
        external
        view
        override
        returns (bytes4 magicValue);

    /// @notice The adapter this lane belongs to, and its only permitted caller.
    /// @dev Fixed in the implementation, which each adapter deploys for itself, so a lane is
    ///      bound to one adapter for its lifetime.
    /// @return The adapter address.
    function adapter() external view returns (address);

    /// @notice The only address the lane can send value to.
    /// @dev The adapter's immutable owner. Fixed in the implementation alongside {adapter}.
    /// @return The recipient address.
    function recipient() external view returns (address);

    /// @notice The CoW Protocol settlement contract the lane cancels orders at.
    /// @dev Fixed in the implementation, and the same contract the adapter places orders
    ///      against.
    /// @return The settlement contract address.
    function settlement() external view returns (address);

    /// @notice The address the lane grants token allowances to.
    /// @dev Fixed in the implementation. The spender half of the allowance row a lane exists to
    ///      keep to itself.
    /// @return The vault relayer address.
    function vaultRelayer() external view returns (address);
}
