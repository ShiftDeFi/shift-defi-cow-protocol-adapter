// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";
import {OrderLifecycleHandler} from "test/invariant/handlers/OrderLifecycleHandler.sol";
import {SweepHandler} from "test/invariant/handlers/SweepHandler.sol";

contract CowProtocolAdapterInvariantTest is CowProtocolAdapterBase {
    SweepHandler internal handler;
    OrderLifecycleHandler internal orderHandler;

    function setUp() public override {
        super.setUp();

        handler = new SweepHandler(adapter, token, OWNER);
        targetContract(address(handler));

        orderHandler = new OrderLifecycleHandler(adapter, settlement, OWNER, address(new ERC20Mock()));
        targetContract(address(orderHandler));
    }

    /// @notice Everything ever delivered to the adapter is either still held by it or has
    ///         reached the owner.
    /// @dev A partial sweep still satisfies this sum; invariant_SweepIsAllOrNothing covers that.
    function invariant_FundsOnlyEverLeaveToOwner() public view {
        assertEq(token.balanceOf(address(adapter)) + token.balanceOf(OWNER), OWNER_BALANCE + handler.delivered());
    }

    /// @notice A sweep that returns successfully has moved the entire balance.
    function invariant_SweepIsAllOrNothing() public view {
        assertFalse(handler.sweptPartially());
    }

    /// @notice The sweep destination is the immutable owner and nothing can repoint it.
    function invariant_OwnerNeverChanges() public view {
        assertEq(adapter.owner(), OWNER);
    }

    /// @notice Every order the adapter counts as pending is one the owner placed and neither
    ///         resolved nor cancelled.
    function invariant_PendingOrderCountMatchesOrdersOutstanding() public view {
        assertEq(adapter.pendingOrderCount(), orderHandler.pending());
    }

    /// @notice What the adapter's pending records add up to is what the lanes' balances grew by,
    ///         held separately for each sell token.
    function invariant_PendingSellAmountsMatchWhatArrived() public view {
        uint256 tokens = orderHandler.sellTokenCount();

        for (uint256 t; t < tokens; ++t) {
            address sellToken = address(orderHandler.sellTokenAt(t));

            assertEq(_committedAmount(sellToken), orderHandler.committed(sellToken));
        }
    }

    /// @notice Every token this handler ever created is still with the owner, on the adapter,
    ///         on a lane, or collected by a settlement.
    /// @dev Stated per token, so a shortfall in one cannot be masked by a surplus in the other.
    function invariant_FundsNeverLeaveTheSystem() public view {
        uint256 tokens = orderHandler.sellTokenCount();

        for (uint256 t; t < tokens; ++t) {
            address sellToken = address(orderHandler.sellTokenAt(t));

            assertEq(orderHandler.totalHeld(sellToken), orderHandler.minted(sellToken));
        }
    }

    /// @notice No lane ever approves the relayer for more than the order it is carrying sells.
    function invariant_LaneAllowanceNeverExceedsItsOrder() public view {
        bytes32[] memory orderDigests = adapter.pendingOrderDigests();

        for (uint256 i; i < orderDigests.length; ++i) {
            ICowProtocolAdapter.OrderRecord memory record = adapter.orderRecord(orderDigests[i]);

            assertLe(IERC20(record.sellToken).allowance(adapter.laneAt(record.lane), VAULT_RELAYER), record.sellAmount);
        }
    }

    /// @notice A pending order's lane approves the relayer for exactly what the order has left
    ///         to give: its sell amount, less whatever a fill has already collected.
    /// @dev The strong form of invariant_LaneAllowanceNeverExceedsItsOrder, and the equality the
    ///      fill verdict reads the allowance as a witness of. It is deliberately not bounded
    ///      below by one: a fill that collects the whole sell amount leaves a still-pending order
    ///      approving nothing, until the owner resolves it.
    function invariant_LaneAllowanceIsItsOrderLessWhatWasPulled() public view {
        bytes32[] memory orderDigests = adapter.pendingOrderDigests();
        uint256 length = orderDigests.length;

        for (uint256 i; i < length; ++i) {
            ICowProtocolAdapter.OrderRecord memory record = adapter.orderRecord(orderDigests[i]);

            assertEq(
                IERC20(record.sellToken).allowance(adapter.laneAt(record.lane), VAULT_RELAYER),
                record.sellAmount - orderHandler.pulled(orderDigests[i])
            );
        }
    }

    /// @notice A lane carrying no order on a token approves nothing over it.
    /// @dev Per token: a lane free of one sell token may still be carrying an order on the other,
    ///      and its allowance over that one says nothing about this one.
    function invariant_FreeLaneApprovesNothing() public view {
        uint256 lanes = adapter.deployedLaneCount();
        uint256 tokens = orderHandler.sellTokenCount();

        for (uint256 t; t < tokens; ++t) {
            ERC20Mock sellToken = orderHandler.sellTokenAt(t);
            uint256 occupancy = adapter.laneOccupancy(address(sellToken));

            for (uint256 i; i < lanes; ++i) {
                if (occupancy & (1 << i) == 0) {
                    assertEq(sellToken.allowance(adapter.laneAt(i), VAULT_RELAYER), 0);
                }
            }
        }
    }

    /// @notice No two pending orders on one token share a lane, so a shortfall in an allowance
    ///         row is attributable to one order.
    /// @dev The collision is per sell token, not global: two orders on different tokens sharing
    ///      one lane is the reuse the design is built on, since they occupy different rows of
    ///      that lane's allowance mapping.
    function invariant_PendingOrdersNeverShareALane() public view {
        bytes32[] memory orderDigests = adapter.pendingOrderDigests();
        uint256 length = orderDigests.length;
        uint256 tokens = orderHandler.sellTokenCount();

        for (uint256 t; t < tokens; ++t) {
            address sellToken = address(orderHandler.sellTokenAt(t));
            uint256 seen;

            for (uint256 i; i < length; ++i) {
                ICowProtocolAdapter.OrderRecord memory record = adapter.orderRecord(orderDigests[i]);
                if (record.sellToken != sellToken) {
                    continue;
                }

                uint256 bit = 1 << record.lane;

                assertEq(seen & bit, 0);
                seen |= bit;
            }
        }
    }

    /// @notice One lane per pending order, summed across both sell tokens: no more and no fewer.
    /// @dev The real statement of the property. On a single token it degenerates into a count of
    ///      that token's occupancy bits and says nothing about sharing lanes between tokens.
    function invariant_LaneOccupancyMatchesPendingOrders() public view {
        assertEq(orderHandler.occupiedLaneCount(), adapter.pendingOrderCount());
    }

    /// @notice The deployed lanes are the dense prefix of indices, and every lane below the
    ///         count has code.
    function invariant_DeployedLanesAreADensePrefix() public view {
        uint256 lanes = adapter.deployedLaneCount();

        assertEq(adapter.laneAt(lanes).code.length, 0);

        for (uint256 i; i < lanes; ++i) {
            assertGt(adapter.laneAt(i).code.length, 0);
        }
    }

    /// @notice The number of lanes deployed never exceeds the number of orders ever placed.
    function invariant_DeployedLanesNeverExceedOrdersPlaced() public view {
        assertLe(adapter.deployedLaneCount(), orderHandler.placed());
    }

    /// @notice The deployed lane count never falls: a resolved order's lane is freed for reuse,
    ///         never retired.
    function invariant_DeployedLaneCountNeverFalls() public view {
        assertFalse(orderHandler.laneCountFell());
    }

    /// @notice Placing an order is the only thing that deploys a lane. Every other entry point
    ///         leaves the count where it was, a placement the adapter rejected included.
    function invariant_LanesAreOnlyDeployedByPlacement() public view {
        assertFalse(orderHandler.lanesMovedOutsidePlacement());
    }

    /// @notice An order's record is never deleted, so a digest the adapter has used stays used.
    function invariant_EveryPlacedDigestKeepsItsRecord() public view {
        uint256 placed = orderHandler.placed();

        for (uint256 i; i < placed; ++i) {
            assertNotEq(
                uint256(adapter.orderRecord(orderHandler.digests(i)).status),
                uint256(ICowProtocolAdapter.OrderStatus.None)
            );
        }
    }
}
