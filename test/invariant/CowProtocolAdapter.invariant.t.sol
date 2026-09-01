// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";
import {PlaceOrderHandler} from "test/invariant/handlers/PlaceOrderHandler.sol";
import {SweepHandler} from "test/invariant/handlers/SweepHandler.sol";

contract CowProtocolAdapterInvariantTest is CowProtocolAdapterBase {
    SweepHandler internal handler;
    PlaceOrderHandler internal orderHandler;

    function setUp() public override {
        super.setUp();

        handler = new SweepHandler(adapter, token, OWNER);
        targetContract(address(handler));

        orderHandler = new PlaceOrderHandler(adapter, OWNER, address(new ERC20Mock()));
        targetContract(address(orderHandler));
    }

    /// @notice Everything ever delivered to the adapter is either still held by it or has
    ///         reached the owner. A balance leaving to any third address breaks the equality.
    /// @dev A partial sweep still satisfies this sum, so it is not covered here;
    ///      invariant_SweepIsAllOrNothing covers that case.
    function invariant_FundsOnlyEverLeaveToOwner() public view {
        assertEq(token.balanceOf(address(adapter)) + token.balanceOf(OWNER), OWNER_BALANCE + handler.delivered());
    }

    /// @notice A sweep that returns successfully has moved the entire balance; it never
    ///         leaves a remainder stranded on the adapter.
    function invariant_SweepIsAllOrNothing() public view {
        assertFalse(handler.sweptPartially());
    }

    /// @notice The sweep destination is the immutable owner and nothing can repoint it.
    function invariant_OwnerNeverChanges() public view {
        assertEq(adapter.owner(), OWNER);
    }

    /// @notice Every order the adapter recorded is one the owner placed. A rejected caller
    ///         never adds to the count, on any path.
    function invariant_PendingOrderCountMatchesOrdersPlaced() public view {
        assertEq(adapter.pendingOrderCount(), orderHandler.placed());
    }

    /// @notice What the adapter records as committed is what its balance actually grew by, so
    ///         a token that delivered less than an order sells could not have been recorded.
    function invariant_CommittedAmountMatchesWhatArrived() public view {
        assertEq(adapter.committedAmount(address(orderHandler.sellToken())), orderHandler.committed());
    }

    /// @notice A sweep never reaches the sell tokens a pending order commits. The only way to
    ///         recover those is to cancel the order first.
    function invariant_SweepNeverTakesCommittedFunds() public view {
        assertGe(
            orderHandler.sellToken().balanceOf(address(adapter)),
            adapter.committedAmount(address(orderHandler.sellToken()))
        );
    }

    /// @notice Everything that entered the adapter is still held by it or was returned to the
    ///         owner, across placements, unaccounted deliveries and sweeps alike.
    function invariant_AdapterBalanceAccountsForEveryMovement() public view {
        assertEq(
            orderHandler.sellToken().balanceOf(address(adapter)),
            orderHandler.committed() + orderHandler.donated() - orderHandler.returned()
        );
    }

    /// @notice The relayer allowance is the sum of every pending order's amount rather than the
    ///         largest of them, so concurrent orders on one token never share a cap.
    function invariant_RelayerAllowanceIsTheSumOfCommitments() public view {
        assertEq(orderHandler.sellToken().allowance(address(adapter), VAULT_RELAYER), orderHandler.committed());
    }
}
