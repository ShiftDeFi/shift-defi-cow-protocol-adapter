// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterOrderUidTest is CowProtocolAdapterBase {
    address internal constant SELL_TOKEN = address(0xA11CE);
    address internal constant BUY_TOKEN = address(0xB0B);

    /// @dev The count, not an index: the highest addressable lane is one below it.
    uint256 internal constant LANE_COUNT = 256;

    function test_OrderUid_Length() public view {
        assertEq(adapter.orderUid(_params(), 0).length, GPv2Order.UID_LENGTH);
    }

    /// @dev Pins the fields the adapter fixes rather than accepting from a caller. A change to
    ///      any of them changes the digest and fails here.
    function testFuzz_OrderUid_CommitsToFixedOrderFields(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    ) public view {
        vm.assume(sellToken != address(0) && buyToken != address(0) && sellToken != buyToken);
        sellAmount = bound(sellAmount, 1, type(uint256).max);
        buyAmount = bound(buyAmount, 1, type(uint256).max);
        validTo = uint32(bound(validTo, 1, type(uint32).max));

        ICowProtocolAdapter.OrderParams memory params = ICowProtocolAdapter.OrderParams({
            sellToken: sellToken,
            buyToken: buyToken,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appData
        });

        GPv2Order.Data memory expected = GPv2Order.Data({
            sellToken: sellToken,
            buyToken: buyToken,
            receiver: OWNER,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        assertEq(
            adapter.orderUid(params, 0),
            GPv2Order.packOrderUidParams(GPv2Order.hash(expected, DOMAIN_SEPARATOR), adapter.laneAt(0), validTo)
        );
    }

    /// @dev Settlement reads the owner out of the identifier, and that owner is the lane rather
    ///      than the adapter.
    function test_OrderUid_EmbedsLaneAsOwner() public view {
        bytes memory uid = adapter.orderUid(_params(), 0);

        bytes32 tail;
        assembly {
            tail := mload(add(uid, 56))
        }

        assertEq(address(uint160(uint256(tail) >> 32)), adapter.laneAt(0));
        assertEq(uint32(uint256(tail)), 1_800_000_000);
    }

    /// @dev One index names one lane per adapter, so identifiers differing only in lane differ.
    function test_OrderUid_DiffersByLane() public view {
        assertNotEq(keccak256(adapter.orderUid(_params(), 0)), keccak256(adapter.orderUid(_params(), 1)));
    }

    /// @dev Each adapter deploys its own lane implementation and so predicts different lane
    ///      addresses.
    function test_OrderUid_DiffersPerAdapterInstance() public {
        CowProtocolAdapter other = new CowProtocolAdapter(OWNER, address(settlement));

        assertNotEq(keccak256(adapter.orderUid(_params(), 0)), keccak256(other.orderUid(_params(), 0)));
    }

    /// @dev A view carries no authority, so it is deliberately reachable by anyone.
    function test_OrderUid_IsUnrestricted() public {
        vm.prank(STRANGER);
        assertEq(adapter.orderUid(_params(), 0).length, GPv2Order.UID_LENGTH);
    }

    /// @dev The top of the lane range is a real lane, so an identifier can be derived for it.
    function test_OrderUid_HighestLane() public view {
        assertEq(adapter.orderUid(_params(), LANE_COUNT - 1).length, GPv2Order.UID_LENGTH);
    }

    function test_RevertIf_OrderUid_ZeroSellToken() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.sellToken = address(0);

        vm.expectRevert(ICowProtocolAdapter.ZeroSellToken.selector);
        adapter.orderUid(params, 0);
    }

    function test_RevertIf_OrderUid_ZeroBuyToken() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.buyToken = address(0);

        vm.expectRevert(ICowProtocolAdapter.ZeroBuyToken.selector);
        adapter.orderUid(params, 0);
    }

    function test_RevertIf_OrderUid_IdenticalTokens() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.buyToken = params.sellToken;

        vm.expectRevert(ICowProtocolAdapter.IdenticalTokens.selector);
        adapter.orderUid(params, 0);
    }

    function test_RevertIf_OrderUid_ZeroSellAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.sellAmount = 0;

        vm.expectRevert(ICowProtocolAdapter.ZeroSellAmount.selector);
        adapter.orderUid(params, 0);
    }

    function test_RevertIf_OrderUid_ZeroBuyAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.buyAmount = 0;

        vm.expectRevert(ICowProtocolAdapter.ZeroBuyAmount.selector);
        adapter.orderUid(params, 0);
    }

    function test_RevertIf_OrderUid_ZeroValidTo() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.validTo = 0;

        vm.expectRevert(ICowProtocolAdapter.ZeroValidTo.selector);
        adapter.orderUid(params, 0);
    }

    /// @dev An index at or above the count names no lane the allocator could ever assign.
    function test_RevertIf_OrderUid_LaneIndexTooLarge() public {
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.LaneIndexTooLarge.selector, LANE_COUNT, LANE_COUNT));
        adapter.orderUid(_params(), LANE_COUNT);
    }

    function testFuzz_RevertIf_OrderUid_LaneIndexTooLarge(uint256 laneIndex) public {
        laneIndex = bound(laneIndex, LANE_COUNT, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.LaneIndexTooLarge.selector, laneIndex, LANE_COUNT));
        adapter.orderUid(_params(), laneIndex);
    }

    /// @dev Order parameters are validated ahead of the lane index.
    function test_RevertIf_OrderUid_ZeroSellTokenTakesPrecedenceOverLaneIndex() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.sellToken = address(0);

        vm.expectRevert(ICowProtocolAdapter.ZeroSellToken.selector);
        adapter.orderUid(params, LANE_COUNT);
    }

    function _params() internal pure returns (ICowProtocolAdapter.OrderParams memory) {
        return ICowProtocolAdapter.OrderParams({
            sellToken: SELL_TOKEN,
            buyToken: BUY_TOKEN,
            sellAmount: 100e18,
            buyAmount: 99e18,
            validTo: 1_800_000_000,
            appData: keccak256("appData")
        });
    }
}
