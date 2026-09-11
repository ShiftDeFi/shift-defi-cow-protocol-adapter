// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterLaneAtTest is CowProtocolAdapterBase {
    /// @dev The count, not an index: the highest addressable lane is one below it.
    uint256 internal constant LANE_COUNT = 256;

    /// @dev One index names one lane, so two orders on different lanes never share an
    ///      allowance row.
    function testFuzz_LaneAt_DistinctPerIndex(uint256 first, uint256 second) public view {
        first = bound(first, 0, LANE_COUNT - 1);
        second = bound(second, 0, LANE_COUNT - 1);
        vm.assume(first != second);

        assertNotEq(adapter.laneAt(first), adapter.laneAt(second));
    }

    /// @dev A lane's address is known before it has code, so a caller can derive an order's
    ///      identifier ahead of placing it.
    function test_LaneAt_PredictsUndeployedLane() public {
        address predicted = adapter.laneAt(0);

        assertEq(predicted.code.length, 0);
        assertEq(adapter.deployedLaneCount(), 0);

        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(adapter.laneAt(0), predicted);
        assertGt(predicted.code.length, 0);
    }

    /// @dev Occupancy is a 256-bit field, so lane 255 is one the allocator can hand out and a
    ///      record can hold in its `uint8`.
    function test_LaneAt_HighestLaneIsAddressable() public view {
        address highest = adapter.laneAt(LANE_COUNT - 1);

        assertNotEq(highest, address(0));
        assertNotEq(highest, adapter.laneAt(0));
    }

    /// @dev An index at or above the count names no lane at any point in the adapter's life.
    function test_RevertIf_LaneAt_LaneIndexTooLarge() public {
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.LaneIndexTooLarge.selector, LANE_COUNT, LANE_COUNT));
        adapter.laneAt(LANE_COUNT);
    }

    function testFuzz_RevertIf_LaneAt_LaneIndexTooLarge(uint256 index) public {
        index = bound(index, LANE_COUNT, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.LaneIndexTooLarge.selector, index, LANE_COUNT));
        adapter.laneAt(index);
    }
}
