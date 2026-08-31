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
        assertEq(token.balanceOf(OWNER), 100e18);
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
}
