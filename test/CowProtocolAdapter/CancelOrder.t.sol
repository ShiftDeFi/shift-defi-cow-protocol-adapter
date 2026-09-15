// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterCancelOrderTest is CowProtocolAdapterBase {
    function test_CancelOrder_ReturnsTheSellTokensToTheOwner() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(token.balanceOf(OWNER), OWNER_BALANCE);
        assertEq(token.balanceOf(_laneOf(params)), 0);
    }

    function test_CancelOrder_MarksTheRecordCancelled() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(
            uint256(adapter.orderRecord(_digestOf(params)).status), uint256(ICowProtocolAdapter.OrderStatus.Cancelled)
        );
    }

    function test_CancelOrder_ReleasesTheCommitmentAndThePendingEntry() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(_committedAmount(address(token)), 0);
        assertEq(adapter.pendingOrderCount(), 0);
    }

    /// @dev Settlement holds the cancellation marker afterwards, so no trade against the order
    ///      can land.
    function test_CancelOrder_InvalidatesTheOrderAtSettlement() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();
        bytes memory uid = _uidOf(params);

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(settlement.filledAmount(uid), type(uint256).max);
    }

    function test_CancelOrder_WithdrawsTheEndorsement() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();
        address lane = _laneOf(params);

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(adapter.isValidSignatureForLane(lane, _digestOf(params)), bytes4(0));
    }

    function test_CancelOrder_FreesTheLaneAndRevokesItsAllowance() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();
        address lane = _laneOf(params);

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(adapter.laneOccupancy(address(token)), 0);
        assertEq(token.allowance(lane, VAULT_RELAYER), 0);
    }

    /// @dev A donation to the lane goes home with the refund.
    function test_CancelOrder_ReturnsADonationLeftOnTheLane() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();
        token.mint(_laneOf(params), 6e18);

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(token.balanceOf(OWNER), OWNER_BALANCE + 6e18);
    }

    function test_CancelOrder_EmitsOrderCancelled() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        vm.expectEmit(true, true, false, true);
        emit ICowProtocolAdapter.OrderCancelled(_digestOf(params), address(token), SELL_AMOUNT);

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));
    }

    /// @dev Past expiry a solver may erase the fill record, but the lane's allowance still
    ///      shows nothing was pulled.
    function test_CancelOrder_RefundsAnExpiredOrderWhoseFillRecordWasCleared() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        vm.warp(uint256(VALID_TO) + 1);
        settlement.freeFilledAmountStorage(_uidOf(params));

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        assertEq(token.balanceOf(OWNER), OWNER_BALANCE);
        assertEq(adapter.pendingOrderCount(), 0);
    }

    /// @dev A sibling on the same token filled and both records were erased. Cancelling the
    ///      unfilled order returns its own sell amount out of its own lane.
    function test_CancelOrder_RefundsWithoutTouchingAFilledSibling() public {
        ICowProtocolAdapter.OrderParams memory live = _placeOrder();

        ICowProtocolAdapter.OrderParams memory filled = _sellOrder();
        filled.validTo = VALID_TO + 1;

        vm.prank(OWNER);
        adapter.placeOrder(filled);

        _pullAsRelayer(filled, SELL_AMOUNT);

        vm.warp(uint256(VALID_TO) + 2);
        settlement.freeFilledAmountStorage(_uidOf(live));
        settlement.freeFilledAmountStorage(_uidOf(filled));

        vm.prank(OWNER);
        adapter.cancelOrder(_digestOf(live));

        assertEq(token.balanceOf(OWNER), OWNER_BALANCE - SELL_AMOUNT);
        assertEq(_committedAmount(address(token)), SELL_AMOUNT);
        assertEq(adapter.pendingOrderCount(), 1);
    }

    function test_RevertIf_PlaceOrder_OrderDigestUsed_AfterCancellation() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        vm.startPrank(OWNER);
        adapter.cancelOrder(_digestOf(params));

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderDigestUsed.selector, _digestOf(params)));
        adapter.placeOrder(params);
        vm.stopPrank();
    }

    function test_RevertIf_CancelOrder_NotOwner() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();
        bytes32 orderDigest = _digestOf(params);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.cancelOrder(orderDigest);
    }

    function test_RevertIf_CancelOrder_OrderFilled() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        _placeAndFill(params);

        bytes32 orderDigest = _digestOf(params);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderFilled.selector, orderDigest, SELL_AMOUNT));
        adapter.cancelOrder(orderDigest);
    }

    /// @dev The same refusal once the fill record is gone, from the lane's allowance.
    function test_RevertIf_CancelOrder_OrderFilled_RecordCleared() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();

        _pullAsRelayer(params, SELL_AMOUNT);

        vm.warp(uint256(VALID_TO) + 1);
        settlement.freeFilledAmountStorage(_uidOf(params));

        bytes32 orderDigest = _digestOf(params);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderFilled.selector, orderDigest, 0));
        adapter.cancelOrder(orderDigest);
    }

    function test_RevertIf_CancelOrder_OrderNotPending_NeverPlaced() public {
        bytes32 orderDigest = keccak256("never placed");

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderNotPending.selector, orderDigest));
        adapter.cancelOrder(orderDigest);
    }

    function test_RevertIf_CancelOrder_OrderNotPending_AlreadyCancelled() public {
        ICowProtocolAdapter.OrderParams memory params = _placeOrder();
        bytes32 orderDigest = _digestOf(params);

        vm.startPrank(OWNER);
        adapter.cancelOrder(orderDigest);

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderNotPending.selector, orderDigest));
        adapter.cancelOrder(orderDigest);
        vm.stopPrank();
    }

    function _placeOrder() internal returns (ICowProtocolAdapter.OrderParams memory) {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        return params;
    }
}
