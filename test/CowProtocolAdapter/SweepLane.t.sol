// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterSweepLaneTest is CowProtocolAdapterBase {
    /// @dev Only an order's own resolution drains a lane, so a balance arriving while no order
    ///      occupies it has nothing else that would move it.
    function test_SweepLane_ReturnsABalanceLeftOnAFreedLane() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        _placeAndFill(params);

        address lane = _laneOf(params);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        token.mint(lane, 9e18);

        vm.prank(OWNER);
        adapter.sweepLane(0, address(token));

        assertEq(token.balanceOf(lane), 0);
        assertEq(token.balanceOf(OWNER), OWNER_BALANCE - SELL_AMOUNT + 9e18);
    }

    /// @dev The balances are separate, and so are the allowance rows behind them.
    function test_SweepLane_ReturnsAnotherTokenWhileTheLaneCarriesAnOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        buyToken.mint(lane, 4e18);

        vm.prank(OWNER);
        adapter.sweepLane(0, address(buyToken));

        assertEq(buyToken.balanceOf(OWNER), 4e18);
        assertEq(token.balanceOf(lane), SELL_AMOUNT);
    }

    function test_SweepLane_EmitsLaneSwept() public {
        address lane = _freedLane();
        token.mint(lane, 2e18);

        vm.expectEmit(true, true, false, true);
        emit ICowProtocolAdapter.LaneSwept(0, address(token), 2e18);

        vm.prank(OWNER);
        adapter.sweepLane(0, address(token));
    }

    function test_RevertIf_SweepLane_NotOwner() public {
        address lane = _freedLane();
        token.mint(lane, 1e18);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.sweepLane(0, address(token));
    }

    function test_RevertIf_SweepLane_ZeroAddress() public {
        _freedLane();

        vm.prank(OWNER);
        vm.expectRevert(IOwnerImmutable.ZeroAddress.selector);
        adapter.sweepLane(0, address(0));
    }

    /// @dev The whole balance would be the pending order's sell tokens, which only a
    ///      cancellation may release.
    function test_RevertIf_SweepLane_LaneOccupied() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.LaneOccupied.selector, 0, address(token)));
        adapter.sweepLane(0, address(token));
    }

    function test_RevertIf_SweepLane_NothingToSweep() public {
        _freedLane();

        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.NothingToSweep.selector);
        adapter.sweepLane(0, address(token));
    }

    /// @dev A lane that does not exist holds nothing, and naming one gives a named error rather
    ///      than a decode failure on an address with no code.
    function test_RevertIf_SweepLane_LaneIndexOutOfRange() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.LaneIndexOutOfRange.selector, 0, 0));
        adapter.sweepLane(0, address(token));
    }

    /// @dev A lane that exists and carries nothing, which is what a resolved order leaves behind.
    function _freedLane() internal returns (address) {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        _placeAndFill(params);

        address lane = _laneOf(params);

        vm.prank(OWNER);
        adapter.resolveOrder(_digestOf(params));

        return lane;
    }
}
