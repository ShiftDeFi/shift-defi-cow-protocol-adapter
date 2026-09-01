// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

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

    /// @notice The standard sell order over the fixture's two tokens.
    function _sellOrder() internal view returns (ICowProtocolAdapter.OrderParams memory params) {
        params = ICowProtocolAdapter.OrderParams({
            sellToken: address(token),
            buyToken: address(buyToken),
            sellAmount: SELL_AMOUNT,
            buyAmount: BUY_AMOUNT,
            validTo: VALID_TO,
            appData: keccak256("appData"),
            kind: ICowProtocolAdapter.OrderKind.Sell
        });
    }
}
