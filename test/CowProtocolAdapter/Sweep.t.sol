// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterSweepTest is CowProtocolAdapterBase {
    function test_Sweep_TransfersFullBalanceToOwner() public {
        token.mint(address(adapter), 100e18);

        vm.prank(OWNER);
        adapter.sweep(address(token));

        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(OWNER), OWNER_BALANCE + 100e18);
    }

    /// @dev Sell tokens behind a pending order stay put; only what exceeds them is returned.
    function test_Sweep_RetainsBalanceCommittedToPendingOrders() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        token.mint(address(adapter), 7e18);

        vm.prank(OWNER);
        adapter.sweep(address(token));

        assertEq(token.balanceOf(address(adapter)), SELL_AMOUNT);
        assertEq(adapter.committedAmount(address(token)), SELL_AMOUNT);
    }

    function test_Sweep_EmitsTokensSweptForTheUncommittedAmount() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        token.mint(address(adapter), 7e18);

        vm.expectEmit(true, false, false, true);
        emit ICowProtocolAdapter.TokensSwept(address(token), 7e18);

        vm.prank(OWNER);
        adapter.sweep(address(token));
    }

    function test_Sweep_EmitsTokensSwept() public {
        token.mint(address(adapter), 100e18);

        vm.expectEmit(true, false, false, true);
        emit ICowProtocolAdapter.TokensSwept(address(token), 100e18);

        vm.prank(OWNER);
        adapter.sweep(address(token));
    }

    function test_RevertIf_Sweep_NotOwner() public {
        token.mint(address(adapter), 100e18);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.sweep(address(token));
    }

    function test_RevertIf_Sweep_ZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(IOwnerImmutable.ZeroAddress.selector);
        adapter.sweep(address(0));
    }

    function test_RevertIf_Sweep_NothingToSweep() public {
        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.NothingToSweep.selector);
        adapter.sweep(address(token));
    }

    /// @dev The whole balance is committed, so the order has to be cancelled before these funds
    ///      can be returned. Sweeping is not a way around a pending order.
    function test_RevertIf_Sweep_NoUncommittedBalance() public {
        vm.startPrank(OWNER);
        adapter.placeOrder(_sellOrder());

        vm.expectRevert(
            abi.encodeWithSelector(ICowProtocolAdapter.NoUncommittedBalance.selector, SELL_AMOUNT, SELL_AMOUNT)
        );
        adapter.sweep(address(token));
        vm.stopPrank();
    }

    /// @dev A settlement collecting an order's sell tokens leaves the balance below what is
    ///      still recorded as committed. That must not underflow into a sweep of the remainder.
    function test_RevertIf_Sweep_BalanceBelowCommitted() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        vm.prank(address(adapter));
        token.transfer(VAULT_RELAYER, SELL_AMOUNT - 1e18);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.NoUncommittedBalance.selector, 1e18, SELL_AMOUNT));
        adapter.sweep(address(token));
    }
}
