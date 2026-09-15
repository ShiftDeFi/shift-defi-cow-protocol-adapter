// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GPv2Order
/// @notice CoW Protocol's order type, and the EIP-712 derivation of an order's digest and
///         unique identifier.
/// @dev Mirrors CoW Protocol's own `GPv2Order` library, which is not imported because CoW's
///      contracts target solc 0.7.6 and do not compile under this repository's pragma. The
///      field order, the type string and the constants below are fixed by the deployed
///      settlement contract: changing any of them changes every digest this adapter produces.
library GPv2Order {
    /// @notice A CoW Protocol order, in the form the settlement contract verifies.
    /// @param sellToken The token sold to the settlement contract.
    /// @param buyToken The token bought from the settlement contract.
    /// @param receiver The account bought tokens are transferred to.
    /// @param sellAmount The amount of `sellToken` sold, exact for a sell order.
    /// @param buyAmount The amount of `buyToken` bought, exact for a buy order.
    /// @param validTo The unix timestamp after which the order is no longer fillable.
    /// @param appData The hash of the order's off-chain metadata.
    /// @param feeAmount The fee taken in `sellToken` on top of `sellAmount`.
    /// @param kind Whether the order is {KIND_SELL} or {KIND_BUY}.
    /// @param partiallyFillable Whether settlement may fill the order in more than one trade.
    /// @param sellTokenBalance Where settlement sources `sellToken` from.
    /// @param buyTokenBalance Where settlement delivers `buyToken` to.
    struct Data {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    /// @dev The EIP-712 type string of {Data}. The three `string` fields are encoded as the
    ///      keccak256 of their value, which is what the `bytes32` constants below hold.
    string internal constant TYPE_STRING = "Order(address sellToken,address buyToken,address receiver,"
        "uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,"
        "string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)";

    /// @notice The EIP-712 type hash of {Data}, `keccak256(TYPE_STRING)`.
    bytes32 internal constant TYPE_HASH = 0xd5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489;

    /// @notice Order kind for a sell order, `keccak256("sell")`. `sellAmount` is exact.
    bytes32 internal constant KIND_SELL = 0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775;

    /// @notice Order kind for a buy order, `keccak256("buy")`. `buyAmount` is exact.
    bytes32 internal constant KIND_BUY = 0x6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc;

    /// @notice Token balance held as a plain ERC-20 balance, `keccak256("erc20")`.
    bytes32 internal constant BALANCE_ERC20 = 0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9;

    /// @notice The length in bytes of an order's unique identifier.
    uint256 internal constant UID_LENGTH = 56;

    /// @notice Computes an order's EIP-712 digest, the value settlement verifies a signature
    ///         against.
    /// @param order The order to hash.
    /// @param domainSeparator The EIP-712 domain separator of the settlement contract the
    ///        order is placed against.
    /// @return orderDigest The order's EIP-712 digest.
    function hash(Data memory order, bytes32 domainSeparator) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPE_HASH,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                order.kind,
                order.partiallyFillable,
                order.sellTokenBalance,
                order.buyTokenBalance
            )
        );

        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    /// @notice Packs the parameters that identify an order into its unique identifier, the
    ///         key settlement records fills and cancellations under.
    /// @param orderDigest The order's EIP-712 digest.
    /// @param owner The account that placed the order and whose signature settlement verifies.
    /// @param validTo The order's `validTo`.
    /// @return orderUid The order's {UID_LENGTH}-byte unique identifier.
    function packOrderUidParams(bytes32 orderDigest, address owner, uint32 validTo)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(orderDigest, owner, validTo);
    }
}
