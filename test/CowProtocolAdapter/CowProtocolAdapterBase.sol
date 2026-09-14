// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {GPv2SettlementMock} from "test/mocks/GPv2SettlementMock.sol";

/// @title CowProtocolAdapterBase
/// @notice Shared fixture for every test of {CowProtocolAdapter}: a deployed adapter bound to a
///         mock settlement, a sell token the owner holds and has approved the adapter for, and
///         a buy token, so any test can place an order.
/// @dev Overrides of {setUp} must call `super.setUp()` first.
abstract contract CowProtocolAdapterBase is Test {
    address internal constant OWNER = address(0xBEEF);
    address internal constant STRANGER = address(0xCAFE);
    address internal constant VAULT_RELAYER = address(0xD00D);
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("CowProtocolAdapterBase.domainSeparator");

    uint256 internal constant OWNER_BALANCE = 1_000e18;
    uint256 internal constant SELL_AMOUNT = 100e18;
    uint256 internal constant BUY_AMOUNT = 99e18;
    uint32 internal constant VALID_TO = 1_800_000_000;

    CowProtocolAdapter internal adapter;
    ERC20Mock internal token;
    ERC20Mock internal buyToken;
    GPv2SettlementMock internal settlement;

    function setUp() public virtual {
        settlement = new GPv2SettlementMock(VAULT_RELAYER, DOMAIN_SEPARATOR);
        adapter = new CowProtocolAdapter(OWNER, address(settlement));
        token = new ERC20Mock();
        buyToken = new ERC20Mock();

        token.mint(OWNER, OWNER_BALANCE);

        vm.prank(OWNER);
        token.approve(address(adapter), type(uint256).max);
    }

    /// @notice Places an order and settles it in full: the relayer collects the sell tokens and
    ///         settlement records the fill.
    function _placeAndFill(ICowProtocolAdapter.OrderParams memory params) internal {
        vm.prank(OWNER);
        adapter.placeOrder(params);

        _pullAsRelayer(params, params.sellAmount);
        settlement.setFilledAmount(_uidOf(params), params.sellAmount);
    }

    /// @notice Stands in for a settlement collecting an order's sell tokens, spending the
    ///         allowance the lane granted the relayer.
    function _pullAsRelayer(ICowProtocolAdapter.OrderParams memory params, uint256 amount) internal {
        address lane = _laneOf(params);

        vm.prank(VAULT_RELAYER);
        IERC20(params.sellToken).transferFrom(lane, VAULT_RELAYER, amount);
    }

    /// @notice The lane that owns the order recorded under `params`.
    function _laneOf(ICowProtocolAdapter.OrderParams memory params) internal view returns (address) {
        return adapter.laneAt(adapter.orderRecord(_digestOf(params)).lane);
    }

    /// @notice The identifier settlement records fills of the placed order under.
    function _uidOf(ICowProtocolAdapter.OrderParams memory params) internal view returns (bytes memory) {
        return GPv2Order.packOrderUidParams(_digestOf(params), _laneOf(params), params.validTo);
    }

    /// @notice The order's EIP-712 digest.
    /// @dev Derived independently of the adapter, so a change to the fields it fixes shows up
    ///      here as a mismatch.
    function _digestOf(ICowProtocolAdapter.OrderParams memory params) internal pure returns (bytes32) {
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            receiver: OWNER,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            validTo: params.validTo,
            appData: params.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        return GPv2Order.hash(order, DOMAIN_SEPARATOR);
    }

    /// @notice The total sell amount of every pending order selling `sellToken`, summed from
    ///         the adapter's own records.
    function _committedAmount(address sellToken) internal view returns (uint256 total) {
        bytes32[] memory orderDigests = adapter.pendingOrderDigests();
        uint256 length = orderDigests.length;

        for (uint256 i; i < length; ++i) {
            ICowProtocolAdapter.OrderRecord memory record = adapter.orderRecord(orderDigests[i]);

            if (record.sellToken == sellToken) {
                total += record.sellAmount;
            }
        }
    }

    /// @notice The standard sell order over the fixture's two tokens.
    function _sellOrder() internal view returns (ICowProtocolAdapter.OrderParams memory params) {
        params = ICowProtocolAdapter.OrderParams({
            sellToken: address(token),
            buyToken: address(buyToken),
            sellAmount: SELL_AMOUNT,
            buyAmount: BUY_AMOUNT,
            validTo: VALID_TO,
            appData: keccak256("appData")
        });
    }
}
