// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterResolveOrderTest is CowProtocolAdapterBase {
    function test_ResolveOrder_MarksTheRecordFilled() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(
            uint256(adapter.orderRecord(_digestOf(params)).status), uint256(ICowProtocolAdapter.OrderStatus.Filled)
        );
    }

    /// @dev The record outlives the order, so the digest stays spent and cannot be placed again.
    function test_ResolveOrder_KeepsTheRecordAndItsFields() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        ICowProtocolAdapter.OrderRecord memory record = adapter.orderRecord(_digestOf(params));
        assertEq(record.sellToken, address(token));
        assertEq(record.sellAmount, SELL_AMOUNT);
        assertEq(record.validTo, VALID_TO);
    }

    function test_ResolveOrder_ReleasesTheCommitmentAndThePendingEntry() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(_committedAmount(address(token)), 0);
        assertEq(adapter.pendingOrderCount(), 0);
        assertEq(adapter.pendingOrderDigests().length, 0);
    }

    /// @dev A freed lane is reusable, so the next order takes it rather than deploying another.
    function test_ResolveOrder_FreesTheLaneForReuse() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());
        address lane = _laneOf(params);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(adapter.laneOccupancy(address(token)), 0);
        assertEq(adapter.deployedLaneCount(), 1);

        ICowProtocolAdapter.OrderParams memory next = _sellOrder();
        next.validTo = VALID_TO + 1;

        vm.prank(OWNER);
        adapter.placeOrder(next);

        assertEq(_laneOf(next), lane);
        assertEq(adapter.deployedLaneCount(), 1);
    }

    /// @dev The lane is left holding nothing and approving nothing, which is the state the next
    ///      order to take it expects.
    function test_ResolveOrder_LeavesTheLaneEmptyAndUnapproved() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());
        address lane = _laneOf(params);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(token.balanceOf(lane), 0);
        assertEq(token.allowance(lane, VAULT_RELAYER), 0);
    }

    /// @dev Whatever a fill leaves on the lane goes home with the resolution. A sell order's
    ///      amount is pulled whole, so the short pull is staged directly on the mock.
    function test_ResolveOrder_DrainsWhatAFillLeftOnTheLane() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        _pullAsRelayer(params, SELL_AMOUNT - 4e18);
        settlement.setFilledAmount(_uidOf(params), BUY_AMOUNT);

        uint256 ownerBalanceBefore = token.balanceOf(OWNER);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(token.balanceOf(OWNER), ownerBalanceBefore + 4e18);
        assertEq(token.balanceOf(_laneOf(params)), 0);
    }

    /// @dev The drain is the whole balance, whatever left it there.
    function test_ResolveOrder_DrainsADonationLeftOnTheLane() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());
        token.mint(_laneOf(params), 5e18);

        uint256 ownerBalanceBefore = token.balanceOf(OWNER);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(token.balanceOf(OWNER), ownerBalanceBefore + 5e18);
    }

    function test_ResolveOrder_EmitsOrderResolved() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());

        vm.expectEmit(true, true, false, true);
        emit ICowProtocolAdapter.OrderResolved(_digestOf(params), address(token), SELL_AMOUNT, SELL_AMOUNT, 0);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));
    }

    /// @dev Resolution works from the lane's allowance alone.
    function test_ResolveOrder_ResolvesAnOrderWhoseFillRecordWasCleared() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        _pullAsRelayer(params, SELL_AMOUNT);

        vm.warp(uint256(VALID_TO) + 1);
        settlement.freeFilledAmountStorage(_uidOf(params));

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(adapter.pendingOrderCount(), 0);
    }

    /// @dev The two orders touch different lanes, so resolving one moves no row the other is
    ///      judged against.
    function test_ResolveOrder_LeavesASiblingOrderUntouched() public {
        ICowProtocolAdapter.OrderParams memory sibling = _sellOrder();
        ICowProtocolAdapter.OrderParams memory filled = _sellOrder();
        filled.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(sibling);
        adapter.placeOrder(filled);
        vm.stopPrank();

        _pullAsRelayer(filled, SELL_AMOUNT);
        settlement.setFilledAmount(_uidOf(filled), SELL_AMOUNT);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(filled));

        (ICowProtocolAdapter.FillVerdict verdict,) = adapter.fillVerdict(_digestOf(sibling));

        assertEq(uint256(verdict), uint256(ICowProtocolAdapter.FillVerdict.Unfilled));
        assertEq(_committedAmount(address(token)), SELL_AMOUNT);
        assertEq(adapter.pendingOrderCount(), 1);
        assertEq(token.balanceOf(_laneOf(sibling)), SELL_AMOUNT);
        assertEq(token.allowance(_laneOf(sibling), VAULT_RELAYER), SELL_AMOUNT);
    }

    function test_RevertIf_ResolveOrder_NotOwner() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());
        bytes32 orderDigest = _digestOf(params);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.resolveOrder(orderDigest);
    }

    /// @dev Only cancellation removes an order that has not filled.
    function test_RevertIf_ResolveOrder_OrderNotFilled_StillUnfilled() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        bytes32 orderDigest = _digestOf(params);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICowProtocolAdapter.OrderNotFilled.selector, orderDigest, ICowProtocolAdapter.FillVerdict.Unfilled
            )
        );
        adapter.resolveOrder(orderDigest);
    }

    function test_RevertIf_ResolveOrder_OrderNotFilled_Invalidated() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        bytes32 orderDigest = _digestOf(params);
        bytes memory uid = _uidOf(params);

        vm.prank(lane);
        settlement.invalidateOrder(uid);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICowProtocolAdapter.OrderNotFilled.selector, orderDigest, ICowProtocolAdapter.FillVerdict.Invalidated
            )
        );
        adapter.resolveOrder(orderDigest);
    }

    function test_RevertIf_ResolveOrder_OrderNotPending_NeverPlaced() public {
        bytes32 orderDigest = keccak256("never placed");

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderNotPending.selector, orderDigest));
        adapter.resolveOrder(orderDigest);
    }

    function test_RevertIf_ResolveOrder_OrderNotPending_AlreadyResolved() public {
        ICowProtocolAdapter.OrderParams memory params = _fillOrder(_sellOrder());
        bytes32 orderDigest = _digestOf(params);

        vm.startPrank(OWNER);
        adapter.resolveOrder(orderDigest);

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderNotPending.selector, orderDigest));
        adapter.resolveOrder(orderDigest);
        vm.stopPrank();
    }

    /// @dev Places `params`, settles it in full and hands the parameters back.
    function _fillOrder(ICowProtocolAdapter.OrderParams memory params)
        internal
        returns (ICowProtocolAdapter.OrderParams memory)
    {
        _placeAndFill(params);

        return params;
    }
}
