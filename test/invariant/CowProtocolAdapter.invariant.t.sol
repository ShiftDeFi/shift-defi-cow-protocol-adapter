// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";
import {SweepHandler} from "test/invariant/handlers/SweepHandler.sol";

contract CowProtocolAdapterInvariantTest is CowProtocolAdapterBase {
    SweepHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new SweepHandler(adapter, token, OWNER);
        targetContract(address(handler));
    }

    /// @notice Everything ever delivered to the adapter is either still held by it or has
    ///         reached the owner. A balance leaving to any third address breaks the equality.
    /// @dev A partial sweep still satisfies this sum, so it is not covered here;
    ///      invariant_SweepIsAllOrNothing covers that case.
    function invariant_FundsOnlyEverLeaveToOwner() public view {
        assertEq(token.balanceOf(address(adapter)) + token.balanceOf(OWNER), handler.delivered());
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
}
