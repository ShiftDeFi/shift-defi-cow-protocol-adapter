// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";
import {ERC20FeeOnTransferMock} from "test/mocks/ERC20FeeOnTransferMock.sol";
import {ERC20HookOnTransferMock} from "test/mocks/ERC20HookOnTransferMock.sol";
import {ERC20SurplusOnTransferMock} from "test/mocks/ERC20SurplusOnTransferMock.sol";
import {TransferWindowDonorMock} from "test/mocks/TransferWindowDonorMock.sol";

contract CowProtocolAdapterPlaceOrderTest is CowProtocolAdapterBase {
    function test_PlaceOrder_PullsSellTokensFromOwner() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(token.balanceOf(_laneOf(params)), SELL_AMOUNT);
        assertEq(token.balanceOf(OWNER), OWNER_BALANCE - SELL_AMOUNT);
    }

    /// @dev The identifier is the one {orderUid} derives from the same parameters.
    function test_PlaceOrder_ReturnsOrderUid() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(uid.length, GPv2Order.UID_LENGTH);
        assertEq(uid, GPv2Order.packOrderUidParams(_digestOf(params), _laneOf(params), VALID_TO));
        assertEq(uid, adapter.orderUid(params, 0));
    }

    function test_PlaceOrder_RecordsOrder() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        ICowProtocolAdapter.OrderRecord memory record = adapter.orderRecord(_digestOf(params));
        assertEq(record.sellToken, address(token));
        assertEq(record.validTo, VALID_TO);
        assertEq(uint256(record.status), uint256(ICowProtocolAdapter.OrderStatus.Pending));
        assertEq(record.sellAmount, SELL_AMOUNT);
        assertEq(record.buyAmount, BUY_AMOUNT);
    }

    function test_PlaceOrder_RecordsPendingDigest() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        bytes32[] memory digests = adapter.pendingOrderDigests();
        assertEq(digests.length, 1);
        assertEq(digests[0], _digestOf(params));
    }

    function test_PlaceOrder_RecordsNothingUnderAnotherDigest() public {
        ICowProtocolAdapter.OrderParams memory other = _sellOrder();
        other.validTo = VALID_TO + 1;

        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        assertEq(uint256(adapter.orderRecord(_digestOf(other)).status), uint256(ICowProtocolAdapter.OrderStatus.None));
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

        assertEq(_committedAmount(address(token)), SELL_AMOUNT);
        assertEq(_committedAmount(address(buyToken)), 0);
    }

    /// @dev Granted to the relayer rather than to the settlement contract, and by the lane
    ///      rather than by the adapter.
    function test_PlaceOrder_GrantsVaultRelayerAllowanceOnTheLane() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        address lane = _laneOf(params);
        assertEq(token.allowance(lane, VAULT_RELAYER), SELL_AMOUNT);
        assertEq(token.allowance(lane, address(settlement)), 0);
        assertEq(token.allowance(address(adapter), VAULT_RELAYER), 0);
    }

    function test_PlaceOrder_HoldsSellTokensOnTheLane() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(token.balanceOf(_laneOf(params)), SELL_AMOUNT);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    /// @dev Each lane's allowance covers its own order exactly.
    function test_PlaceOrder_ConcurrentOrdersOnOneTokenTakeSeparateLanes() public {
        ICowProtocolAdapter.OrderParams memory first = _sellOrder();
        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.validTo = VALID_TO + 1;

        vm.startPrank(OWNER);
        adapter.placeOrder(first);
        adapter.placeOrder(second);
        vm.stopPrank();

        assertEq(_laneOf(first), adapter.laneAt(0));
        assertEq(_laneOf(second), adapter.laneAt(1));

        assertEq(token.allowance(_laneOf(first), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(token.allowance(_laneOf(second), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(token.balanceOf(_laneOf(first)), SELL_AMOUNT);
        assertEq(token.balanceOf(_laneOf(second)), SELL_AMOUNT);

        assertEq(_committedAmount(address(token)), SELL_AMOUNT * 2);
        assertEq(adapter.pendingOrderCount(), 2);
        assertEq(adapter.laneOccupancy(address(token)), 3);
        assertEq(adapter.deployedLaneCount(), 2);
    }

    /// @dev The address it lands on is the one predicted before it existed.
    function test_PlaceOrder_DeploysLaneAtThePredictedAddress() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        (address predicted, uint256 index) = adapter.nextLane(address(token));

        assertEq(index, 0);
        assertEq(predicted.code.length, 0);
        assertEq(adapter.deployedLaneCount(), 0);

        vm.expectEmit(true, true, false, false);
        emit ICowProtocolAdapter.LaneDeployed(0, predicted);

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(_laneOf(params), predicted);
        assertGt(predicted.code.length, 0);
        assertEq(adapter.deployedLaneCount(), 1);
    }

    /// @dev An order on a second sell token takes lane 0 again; the two orders occupy rows in
    ///      different tokens' allowance mappings.
    function test_PlaceOrder_LanesAreSharedAcrossSellTokens() public {
        ICowProtocolAdapter.OrderParams memory first = _sellOrder();

        ICowProtocolAdapter.OrderParams memory second = _sellOrder();
        second.sellToken = address(buyToken);
        second.buyToken = address(token);

        buyToken.mint(OWNER, OWNER_BALANCE);
        vm.startPrank(OWNER);
        buyToken.approve(address(adapter), type(uint256).max);

        adapter.placeOrder(first);
        adapter.placeOrder(second);
        vm.stopPrank();

        assertEq(_laneOf(first), _laneOf(second));
        assertEq(adapter.deployedLaneCount(), 1);
        assertEq(adapter.laneOccupancy(address(token)), 1);
        assertEq(adapter.laneOccupancy(address(buyToken)), 1);
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
            adapter.laneAt(0),
            GPv2Order.packOrderUidParams(orderDigest, adapter.laneAt(0), VALID_TO)
        );

        vm.prank(OWNER);
        adapter.placeOrder(params);
    }

    /// @dev A token taking a fee on transfer delivers less than was asked for. The order is
    ///      rejected rather than placed for the smaller amount.
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

    function test_RevertIf_PlaceOrder_SellTokenShortfall_CommitsNothing() public {
        ERC20FeeOnTransferMock feeToken = _fundedFeeToken(100);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(feeToken);

        vm.prank(OWNER);
        try adapter.placeOrder(params) {
            fail();
        } catch {}

        assertEq(feeToken.balanceOf(address(adapter)), 0);
        assertEq(_committedAmount(address(feeToken)), 0);
        assertEq(adapter.pendingOrderCount(), 0);
        assertEq(feeToken.allowance(address(adapter), VAULT_RELAYER), 0);
    }

    /// @dev Any fee at all is a shortfall; there is no tolerance band.
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

    /// @dev A token that credits more than it moved covers the order without enlarging it.
    function test_PlaceOrder_SurplusOnTransfer_CommitsOnlyTheRequestedAmount() public {
        ERC20SurplusOnTransferMock surplusToken = new ERC20SurplusOnTransferMock(100);
        surplusToken.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        surplusToken.approve(address(adapter), type(uint256).max);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(surplusToken);

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(surplusToken.balanceOf(_laneOf(params)), SELL_AMOUNT + SELL_AMOUNT / 100);
        assertEq(_committedAmount(address(surplusToken)), SELL_AMOUNT);
        assertEq(surplusToken.allowance(_laneOf(params), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(uid, adapter.orderUid(params, 0));
    }

    function testFuzz_PlaceOrder_CommitsExactlyTheOrderAmount(uint256 sellAmount, uint256 buyAmount) public {
        sellAmount = bound(sellAmount, 1, 1_000e18);
        buyAmount = bound(buyAmount, 1, type(uint128).max);

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellAmount = sellAmount;
        params.buyAmount = buyAmount;

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(uid, adapter.orderUid(params, 0));
        assertEq(token.balanceOf(_laneOf(params)), sellAmount);
        assertEq(_committedAmount(address(token)), sellAmount);
        assertEq(token.allowance(_laneOf(params), VAULT_RELAYER), sellAmount);
        assertEq(adapter.orderRecord(_digestOf(params)).sellAmount, sellAmount);
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

    function test_RevertIf_PlaceOrder_ValidToInPast() public {
        vm.warp(VALID_TO + 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.ValidToInPast.selector, VALID_TO, VALID_TO + 1));
        adapter.placeOrder(_sellOrder());
    }

    /// @dev Settlement stops filling at `validTo`, so an order expiring in the current block is
    ///      rejected too.
    function test_RevertIf_PlaceOrder_ValidToInPast_CurrentBlock() public {
        vm.warp(VALID_TO);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.ValidToInPast.selector, VALID_TO, VALID_TO));
        adapter.placeOrder(_sellOrder());
    }

    function test_RevertIf_PlaceOrder_OrderDigestUsed() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.startPrank(OWNER);
        adapter.placeOrder(params);

        vm.expectRevert(abi.encodeWithSelector(ICowProtocolAdapter.OrderDigestUsed.selector, _digestOf(params)));
        adapter.placeOrder(params);
        vm.stopPrank();
    }

    /// @dev No second pull, no further allowance.
    function test_PlaceOrder_RejectedDuplicateChangesNothing() public {
        ICowProtocolAdapter.OrderParams memory params = _sellOrder();

        vm.startPrank(OWNER);
        adapter.placeOrder(params);
        try adapter.placeOrder(params) {
            fail();
        } catch {}
        vm.stopPrank();

        assertEq(token.balanceOf(_laneOf(params)), SELL_AMOUNT);
        assertEq(_committedAmount(address(token)), SELL_AMOUNT);
        assertEq(adapter.pendingOrderCount(), 1);
        assertEq(token.allowance(_laneOf(params), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(adapter.deployedLaneCount(), 1);
    }

    function test_RevertIf_PlaceOrder_OwnerHasNotApproved() public {
        vm.prank(OWNER);
        token.approve(address(adapter), 0);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, SELL_AMOUNT)
        );
        adapter.placeOrder(_sellOrder());
    }

    /// @dev A third party landing value on the lane between `_pullSellToken`'s two balance reads
    ///      makes the measured delta reach the sell amount even though the owner's transfer was
    ///      docked a fee. The placement succeeds, and it is sound that it does: the check reads
    ///      the lane's actual balance change, so the tokens making up the difference are really
    ///      on the lane and the order is funded in full.
    function test_PlaceOrder_DonationInsideTheMeasurementWindowCoversTheFee() public {
        ERC20HookOnTransferMock hookToken = _fundedHookToken(100);
        uint256 fee = hookToken.feeOn(SELL_AMOUNT);
        hookToken.setHook(new TransferWindowDonorMock(hookToken, fee));

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(hookToken);

        vm.prank(OWNER);
        bytes memory uid = adapter.placeOrder(params);

        assertEq(hookToken.balanceOf(_laneOf(params)), SELL_AMOUNT);
        assertEq(hookToken.allowance(_laneOf(params), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(_committedAmount(address(hookToken)), SELL_AMOUNT);
        assertEq(uid, adapter.orderUid(params, 0));
    }

    /// @dev The owner still parts with the whole sell amount; the fee it lost was made up by the
    ///      donor, not by the adapter recording a smaller order.
    function test_PlaceOrder_DonationInsideTheMeasurementWindowDoesNotSpareTheOwner() public {
        ERC20HookOnTransferMock hookToken = _fundedHookToken(100);
        uint256 fee = hookToken.feeOn(SELL_AMOUNT);
        hookToken.setHook(new TransferWindowDonorMock(hookToken, fee));

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(hookToken);

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(hookToken.balanceOf(OWNER), OWNER_BALANCE - SELL_AMOUNT);
        assertEq(adapter.orderRecord(_digestOf(params)).sellAmount, SELL_AMOUNT);
    }

    /// @dev A donation over the fee covers the order without enlarging it, as a surplus token
    ///      does.
    function test_PlaceOrder_DonationInsideTheMeasurementWindowCommitsOnlyTheRequestedAmount() public {
        ERC20HookOnTransferMock hookToken = _fundedHookToken(100);
        uint256 fee = hookToken.feeOn(SELL_AMOUNT);
        hookToken.setHook(new TransferWindowDonorMock(hookToken, fee + 1e18));

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(hookToken);

        vm.prank(OWNER);
        adapter.placeOrder(params);

        assertEq(hookToken.balanceOf(_laneOf(params)), SELL_AMOUNT + 1e18);
        assertEq(hookToken.allowance(_laneOf(params), VAULT_RELAYER), SELL_AMOUNT);
        assertEq(_committedAmount(address(hookToken)), SELL_AMOUNT);
    }

    /// @dev A donation short of the fee leaves the delta short, and the placement is rejected on
    ///      the amount that actually arrived.
    function test_RevertIf_PlaceOrder_DonationInsideTheMeasurementWindowUndershootsTheFee_SellTokenShortfall() public {
        ERC20HookOnTransferMock hookToken = _fundedHookToken(100);
        uint256 fee = hookToken.feeOn(SELL_AMOUNT);
        hookToken.setHook(new TransferWindowDonorMock(hookToken, fee - 1));

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(hookToken);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ICowProtocolAdapter.SellTokenShortfall.selector, SELL_AMOUNT, SELL_AMOUNT - 1)
        );
        adapter.placeOrder(params);
    }

    /// @dev The lane is funded to the sell amount however the fee and the donation are sized, so
    ///      long as the placement is accepted at all.
    function testFuzz_PlaceOrder_DonationInsideTheMeasurementWindow(uint256 feeBasisPoints, uint256 donation) public {
        feeBasisPoints = bound(feeBasisPoints, 1, 10_000);

        ERC20HookOnTransferMock hookToken = _fundedHookToken(feeBasisPoints);
        uint256 fee = hookToken.feeOn(SELL_AMOUNT);
        donation = bound(donation, 0, 2 * fee);
        hookToken.setHook(new TransferWindowDonorMock(hookToken, donation));

        ICowProtocolAdapter.OrderParams memory params = _sellOrder();
        params.sellToken = address(hookToken);

        vm.prank(OWNER);
        try adapter.placeOrder(params) {
            assertGe(hookToken.balanceOf(_laneOf(params)), SELL_AMOUNT);
            assertEq(_committedAmount(address(hookToken)), SELL_AMOUNT);
        } catch {
            assertLt(donation, fee);
            assertEq(adapter.pendingOrderCount(), 0);
        }
    }

    /// @dev Quantifies what deploying a lane adds to a placement, the figure cost discussions
    ///      quote. Both measured placements are the adapter's second, so cold-start warming is
    ///      common to the two and the difference is the clone: one takes a second lane on the
    ///      token it already has an order on, the other takes the lane already deployed, on a
    ///      token that has none. The ceiling is a regression bound, not the measurement.
    function test_PlaceOrder_LaneDeploymentGasCost() public {
        vm.prank(OWNER);
        adapter.placeOrder(_sellOrder());

        uint256 snapshot = vm.snapshotState();

        ICowProtocolAdapter.OrderParams memory deploying = _sellOrder();
        deploying.appData = keccak256("a second order on the same token");

        vm.prank(OWNER);
        uint256 gasBefore = gasleft();
        adapter.placeOrder(deploying);
        uint256 deployingCost = gasBefore - gasleft();

        vm.revertToState(snapshot);

        ERC20Mock otherToken = new ERC20Mock();
        otherToken.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        otherToken.approve(address(adapter), type(uint256).max);

        ICowProtocolAdapter.OrderParams memory reusing = _sellOrder();
        reusing.sellToken = address(otherToken);

        vm.prank(OWNER);
        gasBefore = gasleft();
        adapter.placeOrder(reusing);
        uint256 reusingCost = gasBefore - gasleft();

        assertGt(deployingCost, reusingCost);
        assertLt(deployingCost - reusingCost, 60_000);
    }

    function _fundedFeeToken(uint256 feeBasisPoints) internal returns (ERC20FeeOnTransferMock feeToken) {
        feeToken = new ERC20FeeOnTransferMock(feeBasisPoints);
        feeToken.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        feeToken.approve(address(adapter), type(uint256).max);
    }

    function _fundedHookToken(uint256 feeBasisPoints) internal returns (ERC20HookOnTransferMock hookToken) {
        hookToken = new ERC20HookOnTransferMock(feeBasisPoints);
        hookToken.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        hookToken.approve(address(adapter), type(uint256).max);
    }
}
