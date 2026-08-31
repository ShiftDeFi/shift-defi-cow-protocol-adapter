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

    function sweep(address token) external onlyOwner {
        require(token != address(0), ZeroAddress());

        uint256 amount = IERC20(token).balanceOf(address(this));
        require(amount != 0, NothingToSweep());

        emit TokensSwept(token, amount);
        IERC20(token).safeTransfer(OWNER, amount);
    }

    function orderUid(OrderParams calldata params) external view returns (bytes memory) {
        _validateOrderParams(params);

        GPv2Order.Data memory order = _buildOrder(params);
        return GPv2Order.packOrderUidParams(order.hash(DOMAIN_SEPARATOR), address(this), params.validTo);
    }

    function settlement() external view returns (address) {
        return address(SETTLEMENT);
    }

    function vaultRelayer() external view returns (address) {
        return VAULT_RELAYER;
    }

    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    /// @dev Expands caller-supplied parameters into the full order settlement verifies. Every
    ///      field not present in {OrderParams} is fixed here rather than accepted from a
    ///      caller: `receiver` is the immutable owner, so a settlement can only ever deliver
    ///      bought tokens home; `partiallyFillable` is false, which keeps an order's fill
    ///      state to filled, cancelled or untouched.
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

    /// @dev `kind` needs no check here: solc rejects an out-of-range enum value when it
    ///      decodes the parameter.
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
