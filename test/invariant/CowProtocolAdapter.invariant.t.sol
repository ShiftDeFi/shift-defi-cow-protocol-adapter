// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";

/// @notice Drives the adapter with arbitrary deliveries and sweep attempts from
///         arbitrary callers, tracking how much has ever entered the adapter.
contract SweepHandler is Test {
    CowProtocolAdapter internal immutable ADAPTER;
    ERC20Mock internal immutable TOKEN;
    address internal immutable OWNER;

    /// @notice Every token amount that has ever arrived at the adapter.
    uint256 public delivered;

    /// @notice Set if a sweep ever returned successfully while leaving a balance behind.
    bool public sweptPartially;

    constructor(CowProtocolAdapter _adapter, ERC20Mock _token, address _owner) {
        ADAPTER = _adapter;
        TOKEN = _token;
        OWNER = _owner;
    }

    /// @notice Tokens arriving at the adapter — an owner deposit, or the funds
    ///         of an order that was cancelled rather than filled.
    function deliver(uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        TOKEN.mint(address(ADAPTER), amount);
        delivered += amount;
    }

    /// @dev Reverts (nothing to sweep) are an expected outcome, not a failure.
    function sweepAsOwner() external {
        vm.prank(OWNER);
        try ADAPTER.sweep(TOKEN) {
            if (TOKEN.balanceOf(address(ADAPTER)) != 0) sweptPartially = true;
        } catch {}
    }

    /// @dev The point of the run: a rejected sweep must move nothing.
    function sweepAsStranger(address caller) external {
        vm.assume(caller != OWNER);
        vm.prank(caller);
        try ADAPTER.sweep(TOKEN) {} catch {}
    }
}

contract CowProtocolAdapterInvariantTest is StdInvariant, Test {
    address internal constant OWNER = address(0xBEEF);

    CowProtocolAdapter internal adapter;
    ERC20Mock internal token;
    SweepHandler internal handler;

    function setUp() public {
        adapter = new CowProtocolAdapter(OWNER);
        token = new ERC20Mock();
        handler = new SweepHandler(adapter, token, OWNER);

        targetContract(address(handler));
    }

    /// @notice Everything ever delivered to the adapter is either still held by it or has
    ///         reached the owner. A balance leaving to any third address breaks the equality.
    /// @dev Conservation alone does not detect a partial sweep — the shortfall would simply
    ///      stay on the adapter side of the sum. invariant_SweepIsAllOrNothing covers that.
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
