// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICowProtocolAdapter} from "./interfaces/ICowProtocolAdapter.sol";
import {IGPv2Settlement} from "./interfaces/IGPv2Settlement.sol";
import {GPv2Order} from "./libraries/GPv2Order.sol";
import {OwnerImmutable} from "./OwnerImmutable.sol";

/// @title CowProtocolAdapter
/// @notice Adapter contract for integrating CoW Protocol swaps.
/// @dev One instance per consuming contract; the owner is that contract, fixed at construction.
contract CowProtocolAdapter is ICowProtocolAdapter, OwnerImmutable {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for IERC20;

    uint256 internal _pendingOrderCount;
    mapping(bytes32 orderDigest => PendingOrder) internal _pendingOrders;
    mapping(address sellToken => uint256) internal _committedAmounts;

    IGPv2Settlement internal immutable SETTLEMENT;
    address internal immutable VAULT_RELAYER;
    bytes32 internal immutable DOMAIN_SEPARATOR;

    constructor(address _owner, address _settlement) OwnerImmutable(_owner) {
        require(_settlement != address(0), ZeroSettlement());

        address relayer = IGPv2Settlement(_settlement).vaultRelayer();
        require(relayer != address(0), ZeroVaultRelayer());

        bytes32 separator = IGPv2Settlement(_settlement).domainSeparator();
        require(separator != bytes32(0), ZeroDomainSeparator());

        SETTLEMENT = IGPv2Settlement(_settlement);
        VAULT_RELAYER = relayer;
        DOMAIN_SEPARATOR = separator;

        emit SettlementSet(_settlement, relayer, separator);
    }

    /// @inheritdoc ICowProtocolAdapter
    function placeOrder(OrderParams calldata params) external onlyOwner returns (bytes memory uid) {
        _validateOrderParams(params);
        require(params.validTo > block.timestamp, ValidToInPast(params.validTo, block.timestamp));

        _pullSellToken(params.sellToken, params.sellAmount);

        GPv2Order.Data memory order = _buildOrder(params);
        bytes32 orderDigest = order.hash(DOMAIN_SEPARATOR);
        require(_pendingOrders[orderDigest].sellToken == address(0), OrderAlreadyPending(orderDigest));

        _pendingOrders[orderDigest] = PendingOrder({
            sellToken: params.sellToken,
            validTo: params.validTo,
            kind: params.kind,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount
        });
        ++_pendingOrderCount;
        _committedAmounts[params.sellToken] += params.sellAmount;

        uid = GPv2Order.packOrderUidParams(orderDigest, address(this), params.validTo);

        emit OrderPlaced(
            orderDigest,
            params.sellToken,
            params.buyToken,
            params.sellAmount,
            params.buyAmount,
            params.validTo,
            params.kind,
            uid
        );

        IERC20(params.sellToken).safeIncreaseAllowance(VAULT_RELAYER, params.sellAmount);
    }

    /// @inheritdoc ICowProtocolAdapter
    function sweep(address token) external onlyOwner {
        require(token != address(0), ZeroAddress());

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance != 0, NothingToSweep());

        uint256 committed = _committedAmounts[token];
        require(balance > committed, NoUncommittedBalance(balance, committed));

        uint256 amount = balance - committed;

        emit TokensSwept(token, amount);
        IERC20(token).safeTransfer(OWNER, amount);
    }

    /// @inheritdoc ICowProtocolAdapter
    function orderUid(OrderParams calldata params) external view returns (bytes memory) {
        _validateOrderParams(params);

        GPv2Order.Data memory order = _buildOrder(params);
        return GPv2Order.packOrderUidParams(order.hash(DOMAIN_SEPARATOR), address(this), params.validTo);
    }

    /// @inheritdoc ICowProtocolAdapter
    function pendingOrder(bytes32 orderDigest) external view returns (PendingOrder memory) {
        return _pendingOrders[orderDigest];
    }

    /// @inheritdoc ICowProtocolAdapter
    function pendingOrderCount() external view returns (uint256) {
        return _pendingOrderCount;
    }

    /// @inheritdoc ICowProtocolAdapter
    function committedAmount(address token) external view returns (uint256) {
        return _committedAmounts[token];
    }

    /// @inheritdoc ICowProtocolAdapter
    function settlement() external view returns (address) {
        return address(SETTLEMENT);
    }

    /// @inheritdoc ICowProtocolAdapter
    function vaultRelayer() external view returns (address) {
        return VAULT_RELAYER;
    }

    /// @inheritdoc ICowProtocolAdapter
    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    /// @dev Pulls sell tokens from the caller and requires the adapter's balance to grow by at
    ///      least `amount`, so a token taking a fee on transfer reverts. A larger delivery is
    ///      accepted and the excess left uncommitted.
    /// @param token The order's sell token.
    /// @param amount The amount to pull.
    function _pullSellToken(address token, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;

        require(received >= amount, SellTokenShortfall(amount, received));
    }

    /// @dev Expands caller-supplied parameters into the full order settlement verifies. The
    ///      fields absent from {OrderParams} are fixed here: `receiver` is the owner,
    ///      `feeAmount` is zero, `partiallyFillable` is false, and both balance fields are
    ///      plain ERC-20.
    /// @param params The caller-supplied part of the order.
    /// @return order The order in the form settlement verifies.
    function _buildOrder(OrderParams memory params) internal view returns (GPv2Order.Data memory order) {
        order = GPv2Order.Data({
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            receiver: OWNER,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            validTo: params.validTo,
            appData: params.appData,
            feeAmount: 0,
            kind: params.kind == OrderKind.Sell ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    /// @dev `kind` is not checked: solc rejects an out-of-range enum value when decoding it.
    /// @param params The caller-supplied part of the order.
    function _validateOrderParams(OrderParams memory params) internal pure {
        require(params.sellToken != address(0), ZeroSellToken());
        require(params.buyToken != address(0), ZeroBuyToken());
        require(params.sellToken != params.buyToken, IdenticalTokens());
        require(params.sellAmount != 0, ZeroSellAmount());
        require(params.buyAmount != 0, ZeroBuyAmount());
        require(params.validTo != 0, ZeroValidTo());
    }
}
