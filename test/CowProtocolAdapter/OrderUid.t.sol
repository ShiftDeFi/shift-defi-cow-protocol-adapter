// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";

contract CowProtocolAdapterOrderUidTest is CowProtocolAdapterBase {
    address internal constant SELL_TOKEN = address(0xA11CE);
    address internal constant BUY_TOKEN = address(0xB0B);

    function test_OrderUid_Length() public view {
        assertEq(adapter.orderUid(_params()).length, GPv2Order.UID_LENGTH);
    }

    /// @dev Pins the fields the adapter fixes rather than accepting from a caller, for every
    ///      order it will describe. Above all `receiver`, which decides where bought tokens
    ///      land, and `partiallyFillable`, which decides whether fill state stays three-valued:
    ///      a change to either changes the digest and fails here.
    function testFuzz_OrderUid_CommitsToFixedOrderFields(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData,
        bool buyKind
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
            appData: appData,
            kind: buyKind ? ICowProtocolAdapter.OrderKind.Buy : ICowProtocolAdapter.OrderKind.Sell
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
            kind: buyKind ? GPv2Order.KIND_BUY : GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        assertEq(
            adapter.orderUid(params),
            GPv2Order.packOrderUidParams(GPv2Order.hash(expected, DOMAIN_SEPARATOR), address(adapter), validTo)
        );
    }

    /// @dev Settlement reads the owner out of the identifier itself, so an order the adapter
    ///      describes is always one the adapter would have to sign.
    function test_OrderUid_EmbedsAdapterAsOwner() public view {
        bytes memory uid = adapter.orderUid(_params());

        bytes32 tail;
        assembly {
            tail := mload(add(uid, 56))
        }

        assertEq(address(uint160(uint256(tail) >> 32)), address(adapter));
        assertEq(uint32(uint256(tail)), 1_800_000_000);
    }

    /// @dev The identifier is bound to the instance that would place the order; two adapters
    ///      never describe the same order.
    function test_OrderUid_DiffersPerAdapterInstance() public {
        CowProtocolAdapter other = new CowProtocolAdapter(OWNER, address(settlement));

        assertNotEq(keccak256(adapter.orderUid(_params())), keccak256(other.orderUid(_params())));
    }

    function test_OrderUid_DiffersByKind() public view {
        ICowProtocolAdapter.OrderParams memory buyParams = _params();
        buyParams.kind = ICowProtocolAdapter.OrderKind.Buy;

        assertNotEq(keccak256(adapter.orderUid(_params())), keccak256(adapter.orderUid(buyParams)));
    }

    /// @dev A view carries no authority, so it is deliberately reachable by anyone.
    function test_OrderUid_IsUnrestricted() public {
        vm.prank(STRANGER);
        assertEq(adapter.orderUid(_params()).length, GPv2Order.UID_LENGTH);
    }

    function test_RevertIf_OrderUid_ZeroSellToken() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.sellToken = address(0);

        vm.expectRevert(ICowProtocolAdapter.ZeroSellToken.selector);
        adapter.orderUid(params);
    }

    function test_RevertIf_OrderUid_ZeroBuyToken() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.buyToken = address(0);

        vm.expectRevert(ICowProtocolAdapter.ZeroBuyToken.selector);
        adapter.orderUid(params);
    }

    function test_RevertIf_OrderUid_IdenticalTokens() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.buyToken = params.sellToken;

        vm.expectRevert(ICowProtocolAdapter.IdenticalTokens.selector);
        adapter.orderUid(params);
    }

    function test_RevertIf_OrderUid_ZeroSellAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.sellAmount = 0;

        vm.expectRevert(ICowProtocolAdapter.ZeroSellAmount.selector);
        adapter.orderUid(params);
    }

    function test_RevertIf_OrderUid_ZeroBuyAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.buyAmount = 0;

        vm.expectRevert(ICowProtocolAdapter.ZeroBuyAmount.selector);
        adapter.orderUid(params);
    }

    function test_RevertIf_OrderUid_ZeroValidTo() public {
        ICowProtocolAdapter.OrderParams memory params = _params();
        params.validTo = 0;

        vm.expectRevert(ICowProtocolAdapter.ZeroValidTo.selector);
        adapter.orderUid(params);
    }

    function _params() internal pure returns (ICowProtocolAdapter.OrderParams memory params) {
        params = ICowProtocolAdapter.OrderParams({
            sellToken: SELL_TOKEN,
            buyToken: BUY_TOKEN,
            sellAmount: 100e18,
            buyAmount: 99e18,
            validTo: 1_800_000_000,
            appData: keccak256("appData"),
            kind: ICowProtocolAdapter.OrderKind.Sell
        });
    }
}
