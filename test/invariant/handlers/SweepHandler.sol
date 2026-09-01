// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

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

    /// @notice Set if a sweep ever returned successfully while leaving behind more than the
    ///         balance committed to pending orders.
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
        try ADAPTER.sweep(address(TOKEN)) {
            if (TOKEN.balanceOf(address(ADAPTER)) != ADAPTER.committedAmount(address(TOKEN))) {
                sweptPartially = true;
            }
        } catch {}
    }

    /// @dev The point of the run: a rejected sweep must move nothing.
    function sweepAsStranger(address caller) external {
        vm.assume(caller != OWNER);
        vm.prank(caller);
        try ADAPTER.sweep(address(TOKEN)) {} catch {}
    }
}
