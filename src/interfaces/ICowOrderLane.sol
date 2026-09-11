// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title ICowOrderLane
/// @notice Interface for a lane: the address an adapter's order names as its owner, so that the
///         order holds a sell token allowance row of its own.
/// @dev CoW Protocol binds four roles to an order's owner — it holds the sell tokens, grants the
///      vault relayer its allowance, answers the ERC-1271 check, and is the only caller
///      settlement's `invalidateOrder` accepts. Orders naming different lanes share no allowance
///      row.
///
///      A lane holds no state and knows nothing about the order it carries. Its adapter, that
///      adapter's owner, the settlement contract and the vault relayer are fixed in the
///      implementation it delegates to, so no caller supplies any of them.
interface ICowOrderLane is IERC1271 {
    /// @notice Thrown when any address other than the adapter calls the lane.
    /// @param caller The rejected caller.
    error NotAdapter(address caller);

    /// @notice Grants the vault relayer an allowance over the lane's balance of a token.
    /// @dev An absolute set rather than an increase; a lane carries at most one pending order
    ///      per token. Uses `forceApprove`, so a token that refuses to move a non-zero allowance
    ///      directly to another non-zero value is handled.
    /// @param token The token to grant the allowance over.
    /// @param amount The allowance to leave in place.
    function approveRelayer(address token, uint256 amount) external;

    /// @notice Cancels an order this lane owns, so no trade against it can settle.
    /// @dev Settlement accepts the call only from the address encoded in `orderUid`.
    /// @param orderUid The order's unique identifier.
    function invalidateOrder(bytes calldata orderUid) external;

    /// @notice Sends the lane's whole balance of a token to the adapter's owner.
    /// @dev The destination is fixed in the implementation, so the caller does not choose it.
    /// @param token The token to send.
    /// @return amount The amount sent, which is zero where the lane held none.
    function drain(address token) external returns (uint256 amount);

    /// @notice Whether the adapter endorses the order carried by an EIP-712 digest under this
    ///         lane, the ERC-1271 check settlement makes before filling an order the lane owns.
    /// @dev Delegates the judgement to the adapter, which holds the order records. The adapter
    ///      endorses the digest only where its record is pending and names this lane.
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
    /// @dev Fixed in the implementation, which each adapter deploys for itself.
    /// @return The adapter address.
    function adapter() external view returns (address);

    /// @notice The only address the lane can send value to.
    /// @dev The adapter's immutable owner, fixed in the implementation alongside {adapter}.
    /// @return The recipient address.
    function recipient() external view returns (address);

    /// @notice The CoW Protocol settlement contract the lane cancels orders at.
    /// @dev Fixed in the implementation. The same contract the adapter places orders against.
    /// @return The settlement contract address.
    function settlement() external view returns (address);

    /// @notice The address the lane grants token allowances to.
    /// @dev Fixed in the implementation. The spender half of the lane's allowance rows.
    /// @return The vault relayer address.
    function vaultRelayer() external view returns (address);
}
