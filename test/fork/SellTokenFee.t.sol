// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";

import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

/// @title IUSDT
/// @notice The surface of the deployed USDT contract this test reads and drives.
/// @dev Declared here rather than as an `IERC20`: USDT's `approve` and `transferFrom` return
///      nothing, and its fee parameters are outside the ERC-20 standard entirely.
interface IUSDT {
    /// @notice The account permitted to change the transfer fee parameters.
    function owner() external view returns (address);

    /// @notice Sets the transfer fee rate and the absolute cap on a single fee.
    /// @param newBasisPoints The fee rate, in basis points. The contract requires this below 20.
    /// @param newMaxFee The cap, in whole USDT. The contract requires this below 50.
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external;

    /// @notice The transfer fee rate, in basis points.
    function basisPointsRate() external view returns (uint256);

    /// @notice The absolute cap on a single transfer's fee, in the token's own units.
    function maximumFee() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
    function allowance(address holder, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external;
}

/// @title SellTokenFeeForkTest
/// @notice Establishes what a sell token that charges a fee on `transferFrom` does to an order,
///         against deployed mainnet USDT rather than a mock.
/// @dev Settles the assumption recorded in the design notes: that settlement's pull out of a lane
///      under a fee-charging sell token collects less than the order sells, so a fill-or-kill
///      order simply never fills. It was inferred from the fee mechanics and never pinned.
///
///      Two facts come out of it. USDT's fee is currently switched off on mainnet, so nothing is
///      exposed today. And while it is on, the adapter refuses the order at placement, so the
///      shortfall is only reachable when the fee is switched on after an order was already
///      placed — which is what the collection test sets up.
///
///      The relayer's `transferFrom` out of the lane is performed directly rather than through
///      `settle`, which would need solver authentication and a full batch. That call is the whole
///      of settlement's contact with the lane, and the fee is charged by the token regardless of
///      who the caller is.
///
///      Skips itself when `ETH_RPC_URL` is unset, so it is inert inside `make verify` and runs
///      under `make fork`.
contract SellTokenFeeForkTest is Test {
    /// @dev Pinned so runs are reproducible.
    uint256 internal constant FORK_BLOCK = 21_000_000;

    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant OWNER = address(0xBEEF);

    /// @dev The largest fee USDT's own `setParams` will accept: 19 basis points, capped at 49
    ///      whole USDT.
    uint256 internal constant MAX_BASIS_POINTS = 19;
    uint256 internal constant MAX_FEE = 49;

    uint256 internal constant SELL_AMOUNT = 1000e6;
    uint256 internal constant BUY_AMOUNT = 1 ether;
    uint32 internal constant ORDER_LIFETIME = 30 days;
    bytes32 internal constant APP_DATA = keccak256("SellTokenFeeForkTest.appData");

    CowProtocolAdapter internal adapter;
    IUSDT internal usdt;

    address internal vaultRelayer;
    uint32 internal validTo;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        usdt = IUSDT(USDT);
        adapter = new CowProtocolAdapter(OWNER, SETTLEMENT);
        vaultRelayer = adapter.vaultRelayer();
        validTo = uint32(block.timestamp) + ORDER_LIFETIME;

        deal(USDT, OWNER, SELL_AMOUNT * 2);

        vm.prank(OWNER);
        usdt.approve(address(adapter), SELL_AMOUNT * 2);
    }

    /// @notice USDT's transfer fee is switched off on mainnet, so a pull delivers the full amount
    ///         and an order selling it is placed normally.
    function test_SellTokenFee_IsSwitchedOffOnMainnet() public {
        assertEq(usdt.basisPointsRate(), 0, "fee rate should be zero");
        assertEq(usdt.maximumFee(), 0, "fee cap should be zero");

        vm.prank(OWNER);
        adapter.placeOrder(_orderParams());

        address lane = adapter.laneAt(0);

        assertEq(usdt.balanceOf(lane), SELL_AMOUNT, "lane should hold the whole sell amount");
        assertEq(usdt.allowance(lane, vaultRelayer), SELL_AMOUNT, "relayer should be approved for it");
    }

    /// @notice With the fee switched on, the adapter refuses the order outright: its own pull
    ///         comes up short and nothing is recorded.
    function test_RevertIf_PlaceOrder_SellTokenFeeIsOn_SellTokenShortfall() public {
        _switchFeeOn();

        uint256 fee = _feeOn(SELL_AMOUNT);
        assertGt(fee, 0, "fee should be charged");

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ICowProtocolAdapter.SellTokenShortfall.selector, SELL_AMOUNT, SELL_AMOUNT - fee)
        );
        adapter.placeOrder(_orderParams());

        assertEq(adapter.pendingOrderCount(), 0, "nothing should be pending");
    }

    /// @notice A fee switched on after an order was placed docks settlement's own pull: the
    ///         relayer spends the lane's whole allowance but collects less than the order sells,
    ///         so a fill-or-kill order cannot settle.
    function test_SellTokenFee_SwitchedOnMidFlightShortsSettlementsCollection() public {
        vm.prank(OWNER);
        adapter.placeOrder(_orderParams());

        address lane = adapter.laneAt(0);

        _switchFeeOn();

        uint256 collectedBefore = usdt.balanceOf(SETTLEMENT);

        vm.prank(vaultRelayer);
        usdt.transferFrom(lane, SETTLEMENT, SELL_AMOUNT);

        uint256 collected = usdt.balanceOf(SETTLEMENT) - collectedBefore;

        assertEq(collected, SELL_AMOUNT - _feeOn(SELL_AMOUNT), "settlement should receive the amount less the fee");
        assertLt(collected, SELL_AMOUNT, "settlement should collect less than the order sells");
        assertEq(usdt.allowance(lane, vaultRelayer), 0, "the whole allowance should have been spent");
        assertEq(usdt.balanceOf(lane), 0, "the lane should have been emptied");
    }

    /// @notice The order stays pending and cancellable after such a pull: the adapter has not
    ///         been made to treat the short collection as a resolution.
    function test_SellTokenFee_ShortCollectionLeavesTheOrderPending() public {
        vm.prank(OWNER);
        adapter.placeOrder(_orderParams());

        address lane = adapter.laneAt(0);

        _switchFeeOn();

        vm.prank(vaultRelayer);
        usdt.transferFrom(lane, SETTLEMENT, SELL_AMOUNT);

        assertEq(adapter.pendingOrderCount(), 1, "the order should still be pending");
    }

    /// @dev Switches USDT's transfer fee on at the highest rate the contract itself permits.
    function _switchFeeOn() internal {
        vm.prank(usdt.owner());
        usdt.setParams(MAX_BASIS_POINTS, MAX_FEE);
    }

    /// @dev What USDT charges on a transfer of `amount`, by the deployed contract's own rule.
    function _feeOn(uint256 amount) internal view returns (uint256 fee) {
        fee = amount * usdt.basisPointsRate() / 10_000;

        uint256 cap = usdt.maximumFee();
        if (fee > cap) {
            fee = cap;
        }
    }

    /// @dev A well-formed order selling USDT.
    /// @return params The caller-supplied part of the order.
    function _orderParams() internal view returns (ICowProtocolAdapter.OrderParams memory params) {
        params = ICowProtocolAdapter.OrderParams({
            sellToken: USDT,
            buyToken: WETH,
            sellAmount: SELL_AMOUNT,
            buyAmount: BUY_AMOUNT,
            validTo: validTo,
            appData: APP_DATA
        });
    }
}
