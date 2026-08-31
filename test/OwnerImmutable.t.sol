// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";
import {OwnerImmutable} from "src/OwnerImmutable.sol";

/// @notice Minimal concrete subject, so the base is exercised directly.
contract OwnerImmutableHarness is OwnerImmutable {
    uint256 public calls;

    constructor(address _owner) OwnerImmutable(_owner) {}

    function guarded() external onlyOwner {
        ++calls;
    }
}

contract OwnerImmutableTest is Test {
    address internal constant OWNER = address(0xBEEF);
    address internal constant STRANGER = address(0xCAFE);

    OwnerImmutableHarness internal subject;

    function setUp() public {
        subject = new OwnerImmutableHarness(OWNER);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(subject.owner(), OWNER);
    }

    function test_Constructor_EmitsOwnerSet() public {
        vm.expectEmit(true, false, false, false);
        emit IOwnerImmutable.OwnerSet(OWNER);
        new OwnerImmutableHarness(OWNER);
    }

    function test_RevertIf_Constructor_ZeroAddress() public {
        vm.expectRevert(IOwnerImmutable.ZeroAddress.selector);
        new OwnerImmutableHarness(address(0));
    }

    function test_Guarded_AllowsOwner() public {
        vm.prank(OWNER);
        subject.guarded();
        assertEq(subject.calls(), 1);
    }

    function test_RevertIf_Guarded_NotOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        subject.guarded();
    }

    /// @dev The rejection must hold for every caller but the owner, and the error must name
    ///      the caller it rejected.
    function testFuzz_RevertIf_Guarded_NotOwner(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, caller));
        subject.guarded();

        assertEq(subject.calls(), 0);
    }
}
