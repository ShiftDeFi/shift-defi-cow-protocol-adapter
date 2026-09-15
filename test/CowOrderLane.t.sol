// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {ICowOrderLane} from "src/interfaces/ICowOrderLane.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

/// @notice Tests for {CowOrderLane}, which exists only as an adapter's clone, so the fixture is
///         the adapter's own.
contract CowOrderLaneTest is CowProtocolAdapterBase {
    function test_Lane_ReadsImplementationImmutablesAsItsOwn() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        ICowOrderLane lane = ICowOrderLane(_laneOf(params));

        assertNotEq(address(lane), adapter.laneImplementation());
        assertEq(lane.adapter(), address(adapter));
        assertEq(lane.recipient(), OWNER);
        assertEq(lane.settlement(), address(settlement));
        assertEq(lane.vaultRelayer(), VAULT_RELAYER);
    }

    function test_Lane_LanesShareAnImplementationAndDifferOnlyInAddress() public {
        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(_sellOrder());
        adapter.placeOrder(second);
        vm.stopPrank();

        ICowOrderLane first = ICowOrderLane(adapter.laneAt(0));
        ICowOrderLane other = ICowOrderLane(adapter.laneAt(1));

        assertNotEq(address(first), address(other));
        assertEq(first.adapter(), other.adapter());
        assertEq(first.recipient(), other.recipient());
    }

    function test_Drain_SendsTheWholeBalanceToTheRecipient() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        token.mint(lane, 3e18);

        vm.prank(address(adapter));
        uint256 drained = ICowOrderLane(lane).drain(address(token));

        assertEq(drained, SELL_AMOUNT + 3e18);
        assertEq(token.balanceOf(lane), 0);
        assertEq(token.balanceOf(OWNER), OWNER_BALANCE - SELL_AMOUNT + drained);
    }

    /// @dev Drained without a transfer, so a token that rejects zero-value transfers cannot
    ///      block the caller.
    function test_Drain_ReturnsZeroForAnEmptyLane() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);

        vm.prank(address(adapter));
        assertEq(ICowOrderLane(lane).drain(address(buyToken)), 0);
    }

    /// @dev The lane grants the allowance and the adapter grants none of its own.
    function test_ApproveRelayer_SetsTheAllowanceAbsolutely() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);

        vm.prank(address(adapter));
        ICowOrderLane(lane).approveRelayer(address(token), 5e18);

        assertEq(token.allowance(lane, VAULT_RELAYER), 5e18);
    }

    /// @dev Settlement accepts the cancellation only from the address encoded in the
    ///      identifier.
    function test_InvalidateOrder_MarksTheOrderCancelledAtSettlement() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        bytes memory uid = _uidOf(params);

        vm.prank(address(adapter));
        ICowOrderLane(lane).invalidateOrder(uid);

        assertEq(settlement.filledAmount(uid), type(uint256).max);
    }

    function test_IsValidSignature_EndorsesAPendingOrderOnItsOwnLane() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(
            ICowOrderLane(_laneOf(params)).isValidSignature(_digestOf(params), ""), IERC1271.isValidSignature.selector
        );
    }

    function test_IsValidSignature_RefusesAnOrderBelongingToAnotherLane() public {
        ICowProtocolAdapter.OrderParams memory first = _sellOrder();
        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(first);
        adapter.placeOrder(second);
        vm.stopPrank();

        assertEq(_laneOf(first), adapter.laneAt(0));
        assertEq(_laneOf(second), adapter.laneAt(1));

        assertEq(ICowOrderLane(_laneOf(second)).isValidSignature(_digestOf(first), ""), bytes4(0));
        assertEq(ICowOrderLane(_laneOf(first)).isValidSignature(_digestOf(second), ""), bytes4(0));
    }

    function test_IsValidSignature_RefusesADigestNeverPlaced() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(ICowOrderLane(_laneOf(params)).isValidSignature(keccak256("never placed"), ""), bytes4(0));
    }

    /// @dev The implementation owns no orders, so it endorses nothing even for a digest that
    ///      is pending on a lane.
    function test_IsValidSignature_RefusesEverythingOnTheImplementation() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(ICowOrderLane(adapter.laneImplementation()).isValidSignature(_digestOf(params), ""), bytes4(0));
    }

    function test_RevertIf_ApproveRelayer_NotAdapter() public {
        address lane = _placedLane();

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(ICowOrderLane.NotAdapter.selector, STRANGER));
        ICowOrderLane(lane).approveRelayer(address(token), 1);
    }

    /// @dev The owner is not the lane's caller either; every lane action runs through the
    ///      adapter.
    function test_RevertIf_ApproveRelayer_NotAdapter_CalledByOwner() public {
        address lane = _placedLane();

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowOrderLane.NotAdapter.selector, OWNER));
        ICowOrderLane(lane).approveRelayer(address(token), 1);
    }

    function test_RevertIf_Drain_NotAdapter() public {
        address lane = _placedLane();

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(ICowOrderLane.NotAdapter.selector, STRANGER));
        ICowOrderLane(lane).drain(address(token));
    }

    function test_RevertIf_InvalidateOrder_NotAdapter() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        bytes memory uid = _uidOf(params);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(ICowOrderLane.NotAdapter.selector, STRANGER));
        ICowOrderLane(lane).invalidateOrder(uid);
    }

    /// @dev A lane with an order on it.
    function _placedLane() internal returns (address) {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        return _laneOf(params);
    }
}
