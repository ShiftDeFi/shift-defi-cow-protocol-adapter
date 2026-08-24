// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

contract CowProtocolAdapterTest is Test {
    address internal constant OWNER = address(0xBEEF);
    address internal constant STRANGER = address(0xCAFE);

    CowProtocolAdapter internal adapter;
    ERC20Mock internal token;

    function setUp() public {
        adapter = new CowProtocolAdapter(OWNER);
        token = new ERC20Mock();
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(adapter.owner(), OWNER);
    }

    function test_Constructor_EmitsOwnerSet() public {
        vm.expectEmit(true, false, false, false);
        emit IOwnerImmutable.OwnerSet(OWNER);
        new CowProtocolAdapter(OWNER);
    }

    function test_RevertIf_Constructor_ZeroAddress() public {
        vm.expectRevert(IOwnerImmutable.ZeroAddress.selector);
        new CowProtocolAdapter(address(0));
    }

    function test_Sweep_TransfersFullBalanceToOwner() public {
        token.mint(address(adapter), 100 ether);

        vm.prank(OWNER);
        adapter.sweep(token);

        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(OWNER), 100 ether);
    }

    function test_Sweep_EmitsTokensSwept() public {
        token.mint(address(adapter), 100 ether);

        vm.expectEmit(true, false, false, true);
        emit ICowProtocolAdapter.TokensSwept(address(token), 100 ether);

        vm.prank(OWNER);
        adapter.sweep(token);
    }

    function test_RevertIf_Sweep_NotOwner() public {
        token.mint(address(adapter), 100 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.sweep(token);
    }

    function test_RevertIf_Sweep_NothingToSweep() public {
        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.NothingToSweep.selector);
        adapter.sweep(token);
    }
}
