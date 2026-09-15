// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterOrderUidOfTest is CowProtocolAdapterBase {
    function test_OrderUidOf_Length() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        bytes32 orderDigest = adapter.placeOrder(params);

        assertEq(adapter.orderUidOf(orderDigest).length, GPv2Order.UID_LENGTH);
    }

    /// @dev The identifier {orderUid} derives for the lane the order was placed on.
    function test_OrderUidOf_MatchesOrderUid() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        bytes32 orderDigest = adapter.placeOrder(params);

        assertEq(adapter.orderUidOf(orderDigest), adapter.orderUid(params, 0));
        assertEq(adapter.orderUidOf(orderDigest), _uidOf(params));
    }

    /// @dev The lane comes from the record, so a caller needs no knowledge of which index the
    ///      allocator handed the order.
    function test_OrderUidOf_UsesTheLaneTheOrderWasPlacedOn() public {
        ICowProtocolAdapter.OrderParams memory first = _sellOrder();
        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(first);
        bytes32 orderDigest = adapter.placeOrder(second);
        vm.stopPrank();

        assertEq(adapter.orderRecord(orderDigest).lane, 1);
        assertEq(adapter.orderUidOf(orderDigest), adapter.orderUid(second, 1));
        assertNotEq(keccak256(adapter.orderUidOf(orderDigest)), keccak256(adapter.orderUid(second, 0)));
    }

    /// @dev A cancelled order keeps its record, and its identifier is what settlement holds the
    ///      invalidation under.
    function test_OrderUidOf_AnswersForACancelledOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.startPrank(OWNER);
        bytes32 orderDigest = adapter.placeOrder(params);
        adapter.cancelOrder(orderDigest);
        vm.stopPrank();

        assertEq(adapter.orderUidOf(orderDigest), _uidOf(params));
    }

    /// @dev A resolved order keeps its record, and its identifier is what settlement holds the
    ///      fill under.
    function test_OrderUidOf_AnswersForAResolvedOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        _placeAndFill(params);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        assertEq(adapter.orderUidOf(_digestOf(params)), _uidOf(params));
    }

    /// @dev A view carries no authority, so it is deliberately reachable by anyone.
    function test_OrderUidOf_IsUnrestricted() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        bytes32 orderDigest = adapter.placeOrder(params);

        vm.prank(STRANGER);
        assertEq(adapter.orderUidOf(orderDigest).length, GPv2Order.UID_LENGTH);
    }

    /// @dev Without a record there is no lane and no `validTo` to pack, so the digest alone
    ///      names no identifier.
    function test_RevertIf_OrderUidOf_OrderUnknown() public {
        bytes32 orderDigest = _digestOf(_sellOrder());

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderUnknown.selector, orderDigest));
        adapter.orderUidOf(orderDigest);
    }

    function testFuzz_RevertIf_OrderUidOf_OrderUnknown(bytes32 orderDigest) public {
        vm.assume(orderDigest != _digestOf(_sellOrder()));

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderUnknown.selector, orderDigest));
        adapter.orderUidOf(orderDigest);
    }
}
