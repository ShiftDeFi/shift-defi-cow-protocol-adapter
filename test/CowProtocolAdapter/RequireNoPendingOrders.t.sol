// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterRequireNoPendingOrdersTest is CowProtocolAdapterBase {
    /// @dev An adapter with nothing outstanding lets the call through, with no resolution
    ///      transaction having run first.
    function test_RequireNoPendingOrders_SucceedsWithNothingPending() public {
        vm.prank(OWNER);
        adapter.requireNoPendingOrders();

        assertEq(adapter.pendingOrderCount(), 0);
    }

    function test_RequireNoPendingOrders_ResolvesEveryFilledOrder() public {
        ICowProtocolAdapter.OrderParams[3] memory orders = _threeFilledOrders();

        vm.prank(OWNER);
        adapter.requireNoPendingOrders();

        assertEq(adapter.pendingOrderCount(), 0);
        assertEq(_committedAmount(address(token)), 0);
        assertEq(adapter.laneOccupancy(address(token)), 0);

        for (uint256 i; i < orders.length; ++i) {
            assertEq(
                uint256(adapter.orderRecord(_digestOf(orders[i])).status),
                uint256(ICowProtocolAdapter.OrderStatus.Filled)
            );
        }
    }

    /// @dev The lanes a batch used are freed together, so the next batch reuses them.
    function test_RequireNoPendingOrders_FreesEveryLaneForTheNextBatch() public {
        _threeFilledOrders();

        vm.prank(OWNER);
        adapter.requireNoPendingOrders();

        assertEq(adapter.deployedLaneCount(), 3);

        ICowProtocolAdapter.OrderParams memory next = _sellOrder();
        next.appData = keccak256("second batch");

        vm.prank(OWNER);
        adapter.placeOrder(next);

        assertEq(_laneOf(next), adapter.laneAt(0));
        assertEq(adapter.deployedLaneCount(), 3);
    }

    /// @dev Orders on different sell tokens resolve in the same call.
    function test_RequireNoPendingOrders_ResolvesAcrossSellTokens() public {
        ICowProtocolAdapter.OrderParams memory first = _sellOrder();

        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.sellToken = address(buyToken);
        second.buyToken = address(token);

        buyToken.mint(OWNER, OWNER_BALANCE);
        vm.prank(OWNER);
        buyToken.approve(address(adapter), type(uint256).max);

        _placeAndFill(first);
        _placeAndFill(second);

        vm.prank(OWNER);
        adapter.requireNoPendingOrders();

        assertEq(adapter.pendingOrderCount(), 0);
        assertEq(_committedAmount(address(token)), 0);
        assertEq(_committedAmount(address(buyToken)), 0);
        assertEq(adapter.laneOccupancy(address(token)), 0);
        assertEq(adapter.laneOccupancy(address(buyToken)), 0);
    }

    function test_RequireNoPendingOrders_EmitsOrderResolvedPerOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        _placeAndFill(params);

        vm.expectEmit(true, true, false, true);
        emit ICowProtocolAdapter.OrderResolved(_digestOf(params), address(token), SELL_AMOUNT, SELL_AMOUNT, 0);

        vm.prank(OWNER);
        adapter.requireNoPendingOrders();
    }

    function test_RevertIf_RequireNoPendingOrders_NotOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.requireNoPendingOrders();
    }

    /// @dev The count reported is what is left after the filled orders were taken out.
    function test_RevertIf_RequireNoPendingOrders_OrdersStillPending() public {
        ICowProtocolAdapter.OrderParams memory filled = _sellOrder();
        ICowProtocolAdapter.OrderParams memory live = _sellOrder();
        live.validTo = VALID_TO + 1;

        _placeAndFill(filled);

        vm.prank(OWNER);
        adapter.placeOrder(live);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrdersStillPending.selector, 1));
        adapter.requireNoPendingOrders();
    }

    /// @dev All or nothing: the revert undoes the orders it did resolve.
    function test_RevertIf_RequireNoPendingOrders_OrdersStillPending_ResolvesNothing() public {
        ICowProtocolAdapter.OrderParams memory filled = _sellOrder();
        ICowProtocolAdapter.OrderParams memory live = _sellOrder();
        live.validTo = VALID_TO + 1;

        _placeAndFill(filled);

        vm.prank(OWNER);
        adapter.placeOrder(live);

        vm.prank(OWNER);
        try adapter.requireNoPendingOrders() {
            fail();
        } catch {}

        assertEq(adapter.pendingOrderCount(), 2);
        assertEq(_committedAmount(address(token)), SELL_AMOUNT * 2);
        assertEq(adapter.laneOccupancy(address(token)), 3);
        assertEq(
            uint256(adapter.orderRecord(_digestOf(filled)).status), uint256(ICowProtocolAdapter.OrderStatus.Pending)
        );
    }

    /// @dev Places three orders on one token and settles all of them.
    function _threeFilledOrders() internal returns (ICowProtocolAdapter.OrderParams[3] memory) {
        ICowProtocolAdapter.OrderParams[3] memory orders;

        for (uint256 i; i < orders.length; ++i) {
            orders[i] = _sellOrder();
            orders[i].validTo = VALID_TO + uint32(i);

            _placeAndFill(orders[i]);
        }

        return orders;
    }

    /// @dev Quantifies how the gate scales with the pending set: a fixed base, plus a marginal
    ///      cost for each order it has to resolve on the way through. The ceiling is a
    ///      regression bound on that marginal cost, not the measurement itself.
    function test_RequireNoPendingOrders_GasScalesWithThePendingSet() public {
        uint256 oneOrder = _gateCost(1);
        uint256 sixteenOrders = _gateCost(16);

        assertGt(sixteenOrders, oneOrder);
        assertLt((sixteenOrders - oneOrder) / 15, 25_000);
    }

    /// @dev Gas the gate burns clearing `orderCount` filled orders, measured from a clean state
    ///      each time so the two measurements are comparable.
    function _gateCost(uint256 orderCount) internal returns (uint256) {
        uint256 snapshot = vm.snapshotState();

        for (uint256 i; i < orderCount; ++i) {
            ICowProtocolAdapter.OrderParams memory params = _sellOrder();
            params.sellAmount = SELL_AMOUNT / 100 + i;
            params.appData = keccak256(abi.encode(i));

            _placeAndFill(params);
        }

        vm.prank(OWNER);
        uint256 gasBefore = gasleft();
        adapter.requireNoPendingOrders();
        uint256 used = gasBefore - gasleft();

        vm.revertToState(snapshot);

        return used;
    }
}
