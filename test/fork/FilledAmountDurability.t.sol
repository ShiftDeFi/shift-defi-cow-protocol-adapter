// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

/// @title IGPv2SettlementFilledAmount
/// @notice The fill-accounting surface of the deployed `GPv2Settlement`.
/// @dev Declared here rather than in {IGPv2Settlement} because the adapter does not call any of
///      it: `freeFilledAmountStorage` is reachable only from settlement itself, and the other two
///      are exercised by this test to establish how the deployed contract behaves.
interface IGPv2SettlementFilledAmount {
    /// @notice The cumulative amount an order has been filled for, keyed by its unique identifier.
    /// @param orderUid The order's unique identifier.
    /// @return The amount filled, in units of the order's exact side.
    function filledAmount(bytes calldata orderUid) external view returns (uint256);

    /// @notice Cancels an order on-chain by writing the cancellation marker over its fill record.
    /// @dev Callable only by the address embedded in `orderUid`.
    /// @param orderUid The order's unique identifier.
    function invalidateOrder(bytes calldata orderUid) external;

    /// @notice Clears the fill records of expired orders to reclaim storage.
    /// @dev Callable only by settlement itself, so a solver reaches it as an interaction within a
    ///      batch. Reverts for any order that has not yet expired.
    /// @param orderUids The unique identifiers of the orders to clear.
    function freeFilledAmountStorage(bytes[] calldata orderUids) external;
}

/// @title FilledAmountDurabilityForkTest
/// @notice Establishes how long `GPv2Settlement` keeps an order's fill record, against the
///         deployed mainnet contract.
/// @dev The adapter reads `filledAmount` to determine an order's outcome, and that read is only
///      meaningful while the record exists. These tests fix the boundary: the record cannot be
///      cleared while the order is still valid, and can be cleared once it has expired — after
///      which a filled, an invalidated and an untouched order are indistinguishable.
///
///      Skips itself when `ETH_RPC_URL` is unset, so it is inert inside `make verify` and runs
///      under `make fork`.
contract FilledAmountDurabilityForkTest is Test {
    /// @dev Any block after the settlement contract's deployment establishes the same behaviour;
    ///      it is pinned so runs are reproducible.
    uint256 internal constant FORK_BLOCK = 21_000_000;

    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant OWNER = address(0xBEEF);

    uint256 internal constant SELL_AMOUNT = 1000e6;
    uint256 internal constant BUY_AMOUNT = 1 ether;
    uint32 internal constant ORDER_LIFETIME = 30 days;
    bytes32 internal constant APP_DATA = keccak256("FilledAmountDurabilityForkTest.appData");

    CowProtocolAdapter internal adapter;
    IGPv2SettlementFilledAmount internal settlement;

    uint32 internal validTo;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        settlement = IGPv2SettlementFilledAmount(SETTLEMENT);
        adapter = new CowProtocolAdapter(OWNER, SETTLEMENT);
        validTo = uint32(block.timestamp) + ORDER_LIFETIME;
    }

    /// @notice The adapter owns the orders it derives identifiers for, and settlement records a
    ///         cancellation against that identifier.
    /// @dev `invalidateOrder` reverts unless the caller is the address settlement extracts from
    ///      the identifier, so this also confirms that the adapter's identifier packing agrees
    ///      with the deployed contract's parsing.
    function test_InvalidateOrder_MarksOrderCancelled() public {
        bytes memory uid = adapter.orderUid(_orderParams());

        assertEq(settlement.filledAmount(uid), 0, "record should start untouched");

        vm.prank(address(adapter));
        settlement.invalidateOrder(uid);

        assertEq(settlement.filledAmount(uid), type(uint256).max, "record should hold the cancellation marker");
    }

    /// @notice A fill record cannot be cleared while its order is still valid.
    /// @dev This is the guarantee the adapter's outcome detection rests on: for as long as
    ///      `validTo` is in the future, a read of `filledAmount` reflects what actually happened.
    function test_RevertIf_FreeFilledAmountStorage_OrderStillValid() public {
        bytes[] memory uids = _invalidatedOrder();

        assertLt(block.timestamp, validTo, "order should still be valid");

        vm.prank(SETTLEMENT);
        vm.expectRevert("GPv2: order still valid");
        settlement.freeFilledAmountStorage(uids);
    }

    /// @notice Once an order has expired its fill record can be cleared, and reads afterwards are
    ///         indistinguishable from an order that was never touched.
    function test_FreeFilledAmountStorage_ClearsRecordOnceExpired() public {
        bytes[] memory uids = _invalidatedOrder();

        vm.warp(uint256(validTo) + 1);

        vm.prank(SETTLEMENT);
        settlement.freeFilledAmountStorage(uids);

        assertEq(settlement.filledAmount(uids[0]), 0, "record should read as untouched");
    }

    /// @dev An order carrying a non-zero fill record, as the single-element array
    ///      `freeFilledAmountStorage` takes. The cancellation marker stands in for a fill: both
    ///      are non-zero values in the same slot, and the clearing path does not distinguish them.
    /// @return uids The order's unique identifier, as a single-element array.
    function _invalidatedOrder() internal returns (bytes[] memory uids) {
        uids = new bytes[](1);
        uids[0] = adapter.orderUid(_orderParams());

        vm.prank(address(adapter));
        settlement.invalidateOrder(uids[0]);

        assertEq(settlement.filledAmount(uids[0]), type(uint256).max, "record should be non-zero");
    }

    /// @dev A well-formed order. The tokens and amounts are never transferred — only the
    ///      identifier derived from them is used.
    /// @return params The caller-supplied part of the order.
    function _orderParams() internal view returns (ICowProtocolAdapter.OrderParams memory params) {
        params = ICowProtocolAdapter.OrderParams({
            sellToken: USDC,
            buyToken: WETH,
            sellAmount: SELL_AMOUNT,
            buyAmount: BUY_AMOUNT,
            validTo: validTo,
            appData: APP_DATA,
            kind: ICowProtocolAdapter.OrderKind.Sell
        });
    }
}
