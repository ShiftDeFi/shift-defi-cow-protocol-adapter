// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterFillVerdictTest is CowProtocolAdapterBase {
    function test_FillVerdict_UnfilledForAFreshOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        _assertVerdict(params, ICowProtocolAdapter.FillVerdict.Unfilled, 0);
    }

    function test_FillVerdict_FilledFromTheSettlementRecord() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        settlement.setFilledAmount(_uidOf(params), SELL_AMOUNT);

        _assertVerdict(params, ICowProtocolAdapter.FillVerdict.Filled, SELL_AMOUNT);
    }

    /// @dev Expiry is not part of the judgement: an order nobody touched reads the same after
    ///      `validTo` as before it.
    function test_FillVerdict_UnfilledAfterExpiryWhenNothingWasPulled() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        vm.warp(uint256(VALID_TO) + 1);
        settlement.freeFilledAmountStorage(_uidOf(params));

        _assertVerdict(params, ICowProtocolAdapter.FillVerdict.Unfilled, 0);
    }

    /// @dev Past expiry a solver may erase the fill record, after which a filled order and an
    ///      untouched one read the same from settlement. The lane's allowance survives it.
    function test_FillVerdict_FilledFromTheLaneAllowanceOnceTheRecordIsCleared() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        _pullAsRelayer(params, SELL_AMOUNT);

        vm.warp(uint256(VALID_TO) + 1);
        settlement.freeFilledAmountStorage(_uidOf(params));

        _assertVerdict(params, ICowProtocolAdapter.FillVerdict.Filled, 0);
    }

    /// @dev Two orders sell the same token at once, one fills, and both fill records are
    ///      erased. Each order was the only spender of its own lane's row, so each verdict holds.
    function test_FillVerdict_AttributesAFillAcrossConcurrentOrdersOnOneToken() public {
        ICowProtocolAdapter.OrderParams memory unfilled = _sellOrder();
        ICowProtocolAdapter.OrderParams memory filled = _sellOrder();
        filled.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(unfilled);
        adapter.placeOrder(filled);
        vm.stopPrank();

        assertNotEq(_laneOf(unfilled), _laneOf(filled));

        _pullAsRelayer(filled, SELL_AMOUNT);

        vm.warp(uint256(VALID_TO) + 2);
        settlement.freeFilledAmountStorage(_uidOf(unfilled));
        settlement.freeFilledAmountStorage(_uidOf(filled));

        _assertVerdict(unfilled, ICowProtocolAdapter.FillVerdict.Unfilled, 0);
        _assertVerdict(filled, ICowProtocolAdapter.FillVerdict.Filled, 0);
    }

    /// @dev The verdict compares the row against the sell amount rather than against zero, so a
    ///      row left short is a pull whatever it still holds. Settlement pulls a sell order's
    ///      amount whole, so the partial pull is staged directly on the mock.
    function test_FillVerdict_FilledWhereTheRowWasLeftShortOfTheSellAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        _pullAsRelayer(params, 1);

        vm.warp(uint256(VALID_TO) + 1);
        settlement.freeFilledAmountStorage(_uidOf(params));

        _assertVerdict(params, ICowProtocolAdapter.FillVerdict.Filled, 0);
    }

    /// @dev Distinguished from a fill: the order's sell tokens are still on its lane, which a
    ///      filled order's are not.
    function test_FillVerdict_InvalidatedWhereSettlementHoldsTheCancellationMarker() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        bytes memory uid = _uidOf(params);

        vm.prank(lane);
        settlement.invalidateOrder(uid);

        _assertVerdict(params, ICowProtocolAdapter.FillVerdict.Invalidated, type(uint256).max);
    }

    function test_RevertIf_FillVerdict_OrderNotPending_NeverPlaced() public {
        bytes32 orderDigest = keccak256("never placed");

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderNotPending.selector, orderDigest));
        adapter.fillVerdict(orderDigest);
    }

    /// @dev A view carries no authority, so it is deliberately reachable by anyone.
    function test_FillVerdict_IsUnrestricted() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        bytes32 orderDigest = _digestOf(params);

        vm.prank(STRANGER);
        (ICowProtocolAdapter.FillVerdict verdict,) = adapter.fillVerdict(orderDigest);

        assertEq(uint256(verdict), uint256(ICowProtocolAdapter.FillVerdict.Unfilled));
    }

    function _assertVerdict(
        ICowProtocolAdapter.OrderParams memory params,
        ICowProtocolAdapter.FillVerdict expected,
        uint256 expectedFilled
    ) internal view {
        (ICowProtocolAdapter.FillVerdict verdict, uint256 filled) = adapter.fillVerdict(_digestOf(params));

        assertEq(uint256(verdict), uint256(expected));
        assertEq(filled, expectedFilled);
    }
}
