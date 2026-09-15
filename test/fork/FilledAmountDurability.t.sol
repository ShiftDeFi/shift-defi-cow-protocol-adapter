// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

/// @title IGPv2SettlementFilledAmount
/// @notice The fill-accounting surface of the deployed `GPv2Settlement`.
/// @dev Declared here rather than in {IGPv2Settlement}: the adapter calls none of it.
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
    /// @dev Callable only by settlement itself. Reverts for any order that has not yet expired.
    /// @param orderUids The unique identifiers of the orders to clear.
    function freeFilledAmountStorage(bytes[] calldata orderUids) external;
}

/// @title FilledAmountDurabilityForkTest
/// @notice Establishes how long `GPv2Settlement` keeps an order's fill record, against the
///         deployed mainnet contract.
/// @dev The record cannot be cleared while the order is still valid, and can be cleared once it
///      has expired — after which a filled, an invalidated and an untouched order read alike.
///
///      Skips itself when `ETH_RPC_URL` is unset, so it is inert inside `make verify` and runs
///      under `make fork`.
contract FilledAmountDurabilityForkTest is Test {
    /// @dev Pinned so runs are reproducible; any block after the settlement contract's
    ///      deployment behaves the same.
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

    /// @notice A lane owns the orders the adapter derives identifiers for, and settlement
    ///         records a cancellation against that identifier.
    /// @dev `invalidateOrder` reverts unless the caller is the address settlement extracts from
    ///      the identifier, so this also confirms that the adapter's identifier packing agrees
    ///      with the deployed contract's parsing.
    function test_InvalidateOrder_MarksOrderCancelled() public {
        bytes memory uid = adapter.orderUid(_orderParams(), 0);

        assertEq(settlement.filledAmount(uid), 0, "record should start untouched");

        vm.prank(adapter.laneAt(0));
        settlement.invalidateOrder(uid);

        assertEq(settlement.filledAmount(uid), type(uint256).max, "record should hold the cancellation marker");
    }

    /// @notice A fill record cannot be cleared while its order is still valid.
    /// @dev For as long as `validTo` is in the future, a read of `filledAmount` reflects what
    ///      happened.
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
    ///      `freeFilledAmountStorage` takes. The cancellation marker stands in for a fill; the
    ///      clearing path does not distinguish them.
    /// @return The order's unique identifier, as a single-element array.
    function _invalidatedOrder() internal returns (bytes[] memory) {
        bytes[] memory uids = new bytes[](1);
        uids[0] = adapter.orderUid(_orderParams(), 0);

        vm.prank(adapter.laneAt(0));
        settlement.invalidateOrder(uids[0]);

        assertEq(settlement.filledAmount(uids[0]), type(uint256).max, "record should be non-zero");

        return uids;
    }

    /// @dev A well-formed order. Only the identifier derived from it is used.
    /// @return The caller-supplied part of the order.
    function _orderParams() internal view returns (ICowProtocolAdapter.OrderParams memory) {
        return ICowProtocolAdapter.OrderParams({
            sellToken: USDC,
            buyToken: WETH,
            sellAmount: SELL_AMOUNT,
            buyAmount: BUY_AMOUNT,
            validTo: validTo,
            appData: APP_DATA
        });
    }
}
