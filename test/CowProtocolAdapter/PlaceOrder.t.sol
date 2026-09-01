// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";
import {ERC20FeeOnTransferMock} from "test/mocks/ERC20FeeOnTransferMock.sol";
import {ERC20SurplusOnTransferMock} from "test/mocks/ERC20SurplusOnTransferMock.sol";

contract CowProtocolAdapterPlaceOrderTest is CowProtocolAdapterBase {
    function test_PlaceOrder_PullsSellTokensFromOwner() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(token.balanceOf(address(adapter)), SELL_AMOUNT);
        assertEq(token.balanceOf(OWNER), OWNER_BALANCE - SELL_AMOUNT);
    }

    /// @dev The identifier is the one {orderUid} derives from the same parameters, so the
    ///      matching off-chain order can be built before the placement lands.
    function test_PlaceOrder_ReturnsOrderUid() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(uid.length, GPv2Order.UID_LENGTH);
        assertEq(uid, GPv2Order.packOrderUidParams(_digestOf(params), address(adapter), VALID_TO));
        assertEq(uid, adapter.orderUid(params));
    }

    function test_PlaceOrder_RecordsPendingOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        ICowProtocolAdapter.PendingOrder memory pending = adapter.pendingOrder(_digestOf(params));
        assertEq(pending.sellToken, address(token));
        assertEq(pending.validTo, VALID_TO);
        assertEq(uint256(pending.kind), uint256(ICowProtocolAdapter.OrderKind.Sell));
        assertEq(pending.sellAmount, SELL_AMOUNT);
        assertEq(pending.buyAmount, BUY_AMOUNT);
    }

    function test_PlaceOrder_RecordsBuyKind() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.kind = ICowProtocolAdapter.OrderKind.Buy;

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(uint256(adapter.pendingOrder(_digestOf(params)).kind), uint256(ICowProtocolAdapter.OrderKind.Buy));
    }

    /// @dev Nothing is recorded under a digest the adapter did not place, so presence under the
    ///      digest is what distinguishes the adapter's own orders from anyone else's.
    function test_PlaceOrder_RecordsNothingUnderAnotherDigest() public {
        ICowProtocolAdapter.OrderParams memory other = _sellOrder();
        other.validTo = VALID_TO + 1;

        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(adapter.pendingOrder(_digestOf(other)).sellToken, address(0));
    }

    function test_PlaceOrder_IncrementsPendingOrderCount() public {
        assertEq(adapter.pendingOrderCount(), 0);

        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(adapter.pendingOrderCount(), 1);
    }

    function test_PlaceOrder_RecordsCommittedAmount() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(adapter.committedAmount(address(token)), SELL_AMOUNT);
        assertEq(adapter.committedAmount(address(buyToken)), 0);
    }

    /// @dev The allowance is granted to the relayer that collects sell tokens, not to the
    ///      settlement contract itself.
    function test_PlaceOrder_IncreasesVaultRelayerAllowance() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(token.allowance(address(adapter), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(token.allowance(address(adapter), address(settlement)), 0);
    }

    /// @dev Two concurrent orders on one token must each have their amount available. An
    ///      allowance topped up to the larger of them would let a fill on one consume what the
    ///      other depends on, so the sum is what is asserted here.
    function test_PlaceOrder_AllowanceAndCommitmentAreAdditiveAcrossOrders() public {
        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(_sellOrder());
        adapter.placeOrder(second);
        vm.stopPrank();

        assertEq(token.allowance(address(adapter), VAULT_RELAYER), SELL_AMOUNT * 2);
        assertEq(adapter.committedAmount(address(token)), SELL_AMOUNT * 2);
        assertEq(adapter.pendingOrderCount(), 2);
        assertEq(token.balanceOf(address(adapter)), SELL_AMOUNT * 2);
    }

    function test_PlaceOrder_EmitsOrderPlaced() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        bytes32 orderDigest = _digestOf(params);

        vm.expectEmit(true, true, true, true);
        emit ICowProtocolAdapter.OrderPlaced(
            orderDigest,
            address(token),
            address(buyToken),
            SELL_AMOUNT,
            BUY_AMOUNT,
            VALID_TO,
            ICowProtocolAdapter.OrderKind.Sell,
            GPv2Order.packOrderUidParams(orderDigest, address(adapter), VALID_TO)
        );

        vm.prank(OWNER);
        adapter.placeOrder(params);
    }

    /// @dev A token taking a fee on transfer delivers less than was asked for. The order is
    ///      rejected rather than placed for the smaller amount: every order sells exactly what
    ///      its parameters say, so its identifier stays derivable from them. Such an order
    ///      could not have filled anyway, since settlement's own pull is charged the same fee.
    function test_RevertIf_PlaceOrder_SellTokenShortfall() public {
        ERC20FeeOnTransferMock feeToken = _fundedFeeToken(100);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(feeToken);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICowProtocolAdapter.SellTokenShortfall.selector, SELL_AMOUNT, SELL_AMOUNT - SELL_AMOUNT / 100
            )
        );
        adapter.placeOrder(params);
    }

    /// @dev A rejected order commits nothing: the pull is undone with the call.
    function test_RevertIf_PlaceOrder_SellTokenShortfall_CommitsNothing() public {
        ERC20FeeOnTransferMock feeToken = _fundedFeeToken(100);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(feeToken);

        vm.prank(OWNER);
        try adapter.placeOrder(params) {
            fail();
        } catch {}

        assertEq(feeToken.balanceOf(address(adapter)), 0);
        assertEq(adapter.committedAmount(address(feeToken)), 0);
        assertEq(adapter.pendingOrderCount(), 0);
        assertEq(feeToken.allowance(address(adapter), VAULT_RELAYER), 0);
    }

    /// @dev Any fee at all is a shortfall; there is no tolerance band. Stablecoins are the only
    ///      intended sell side and none of them round on transfer, so an exact delivery is not
    ///      an assumption the adapter has to soften.
    function testFuzz_RevertIf_PlaceOrder_SellTokenShortfall(uint256 feeBasisPoints, uint256 sellAmount) public {
        sellAmount = bound(sellAmount, 1e18, 1_000e18);
        feeBasisPoints = bound(feeBasisPoints, 1, 10_000);

        ERC20FeeOnTransferMock feeToken = _fundedFeeToken(feeBasisPoints);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(feeToken);
        params.sellAmount = sellAmount;

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICowProtocolAdapter.SellTokenShortfall.selector,
                sellAmount,
                sellAmount - sellAmount * feeBasisPoints / 10_000
            )
        );
        adapter.placeOrder(params);
    }

    /// @dev The other direction is accepted: a token that credits more than it moved covers the
    ///      order, and does not enlarge it. The surplus stays uncommitted and is sweepable.
    function test_PlaceOrder_SurplusOnTransfer_CommitsOnlyTheRequestedAmount() public {
        ERC20SurplusOnTransferMock surplusToken = new ERC20SurplusOnTransferMock(100);
        surplusToken.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        surplusToken.approve(address(adapter), type(uint256).max);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(surplusToken);

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(surplusToken.balanceOf(address(adapter)), SELL_AMOUNT + SELL_AMOUNT / 100);
        assertEq(adapter.committedAmount(address(surplusToken)), SELL_AMOUNT);
        assertEq(surplusToken.allowance(address(adapter), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(uid, adapter.orderUid(params));
    }

    /// @dev At any size, what the adapter records, holds and grants the relayer is the amount
    ///      the order says it sells.
    function testFuzz_PlaceOrder_CommitsExactlyTheOrderAmount(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, 1, 1_000e18);
        buyAmount = bound(buyAmount, 1, type(uint128).max);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellAmount = sellAmount;
        params.buyAmount = buyAmount;

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(uid, adapter.orderUid(params));
        assertEq(token.balanceOf(address(adapter)), sellAmount);
        assertEq(adapter.committedAmount(address(token)), sellAmount);
        assertEq(token.allowance(address(adapter), VAULT_RELAYER), sellAmount);
        assertEq(adapter.pendingOrder(_digestOf(params)).sellAmount, sellAmount);
    }

    function test_RevertIf_PlaceOrder_NotOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IOwnerImmutable.NotOwner.selector, STRANGER));
        adapter.placeOrder(_sellOrder());
    }

    function test_RevertIf_PlaceOrder_ZeroSellToken() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(0);

        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.ZeroSellToken.selector);
        adapter.placeOrder(params);
    }

    function test_RevertIf_PlaceOrder_ZeroBuyToken() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.buyToken = address(0);

        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.ZeroBuyToken.selector);
        adapter.placeOrder(params);
    }

    function test_RevertIf_PlaceOrder_IdenticalTokens() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.buyToken = params.sellToken;

        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.IdenticalTokens.selector);
        adapter.placeOrder(params);
    }

    function test_RevertIf_PlaceOrder_ZeroSellAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellAmount = 0;

        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.ZeroSellAmount.selector);
        adapter.placeOrder(params);
    }

    function test_RevertIf_PlaceOrder_ZeroBuyAmount() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.buyAmount = 0;

        vm.prank(OWNER);
        vm.expectRevert(ICowProtocolAdapter.ZeroBuyAmount.selector);
        adapter.placeOrder(params);
    }

    /// @dev An order whose expiry has passed can never fill, so its funds would be committed to
    ///      nothing until it is cancelled.
    function test_RevertIf_PlaceOrder_ValidToInPast() public {
        vm.warp(VALID_TO + 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.ValidToInPast.selector, VALID_TO, VALID_TO + 1));
        adapter.placeOrder(_sellOrder());
    }

    /// @dev The boundary: settlement stops filling at `validTo`, so an order expiring in the
    ///      current block is rejected too.
    function test_RevertIf_PlaceOrder_ValidToInPast_CurrentBlock() public {
        vm.warp(VALID_TO);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.ValidToInPast.selector, VALID_TO, VALID_TO));
        adapter.placeOrder(_sellOrder());
    }

    /// @dev Settlement keys fills by identifier, so a second order sharing a digest could never
    ///      fill while still holding sell tokens against it.
    function test_RevertIf_PlaceOrder_OrderAlreadyPending() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.startPrank(OWNER);
        adapter.placeOrder(params);

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderAlreadyPending.selector, _digestOf(params)));
        adapter.placeOrder(params);
        vm.stopPrank();
    }

    /// @dev The rejected duplicate commits nothing: no second pull, no further allowance.
    function test_PlaceOrder_RejectedDuplicateChangesNothing() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.startPrank(OWNER);
        adapter.placeOrder(params);
        try adapter.placeOrder(params) {
            fail();
        } catch {}
        vm.stopPrank();

        assertEq(token.balanceOf(address(adapter)), SELL_AMOUNT);
        assertEq(adapter.committedAmount(address(token)), SELL_AMOUNT);
        assertEq(adapter.pendingOrderCount(), 1);
        assertEq(token.allowance(address(adapter), VAULT_RELAYER), SELL_AMOUNT);
    }

    /// @dev Sell tokens come from the owner, so an owner that has not approved the adapter
    ///      cannot have an order placed against its balance.
    function test_RevertIf_PlaceOrder_OwnerHasNotApproved() public {
        vm.prank(OWNER);
        token.approve(address(adapter), 0);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, SELL_AMOUNT)
        );
        adapter.placeOrder(_sellOrder());
    }

    function _fundedFeeToken(uint256 feeBasisPoints) internal returns (ERC20FeeOnTransferMock feeToken) {
        feeToken = new ERC20FeeOnTransferMock(feeBasisPoints);
        feeToken.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        feeToken.approve(address(adapter), type(uint256).max);
    }

    /// @dev Derived independently of the adapter, so a change to the fields it fixes shows up
    ///      here as a mismatch rather than being carried along.
    function _digestOf(ICowProtocolAdapter.OrderParams memory params) internal view returns (bytes32) {
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            receiver: OWNER,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            validTo: params.validTo,
            appData: params.appData,
            feeAmount: 0,
            kind: params.kind == ICowProtocolAdapter.OrderKind.Sell ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        return GPv2Order.hash(order, adapter.domainSeparator());
    }
}
