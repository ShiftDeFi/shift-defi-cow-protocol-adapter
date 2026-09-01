// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";

/// @notice Drives the adapter with order placements, unaccounted deliveries and sweeps, all on
///         one token, tracking everything that entered and left.
/// @dev Sells a token of its own rather than the shared fixture token, so this handler's
///      balance accounting is not disturbed by {SweepHandler}.
contract PlaceOrderHandler is Test {
    CowProtocolAdapter internal immutable ADAPTER;
    ERC20Mock internal immutable TOKEN;
    address internal immutable OWNER;
    address internal immutable BUY_TOKEN;

    /// @notice Orders the adapter accepted.
    uint256 public placed;

    /// @notice The balance the adapter actually gained across every accepted order, summed.
    uint256 public committed;

    /// @notice Tokens that reached the adapter without belonging to any order.
    uint256 public donated;

    /// @notice Tokens a sweep returned to the owner.
    uint256 public returned;

    /// @dev Varies `validTo` and `appData`, so successive orders do not share a digest.
    uint32 internal nonce;

    constructor(CowProtocolAdapter _adapter, address _owner, address _buyToken) {
        ADAPTER = _adapter;
        OWNER = _owner;
        BUY_TOKEN = _buyToken;
        TOKEN = new ERC20Mock();
    }

    /// @notice The token every order placed here sells.
    function sellToken() external view returns (ERC20Mock) {
        return TOKEN;
    }

    /// @dev Reverts are an expected outcome, not a failure; only accepted orders are counted.
    function placeOrderAsOwner(uint256 sellAmount, uint256 buyAmount, bool buyKind) external {
        sellAmount = bound(sellAmount, 1, 1e30);
        buyAmount = bound(buyAmount, 1, 1e30);

        TOKEN.mint(OWNER, sellAmount);
        vm.prank(OWNER);
        TOKEN.approve(address(ADAPTER), sellAmount);

        uint256 balanceBefore = TOKEN.balanceOf(address(ADAPTER));

        vm.prank(OWNER);
        try ADAPTER.placeOrder(_params(sellAmount, buyAmount, buyKind)) {
            ++placed;
            committed += TOKEN.balanceOf(address(ADAPTER)) - balanceBefore;
        } catch {}
    }

    /// @dev The point of the run: a rejected placement must record nothing and pull nothing.
    function placeOrderAsStranger(address caller, uint256 sellAmount, uint256 buyAmount) external {
        vm.assume(caller != OWNER);
        sellAmount = bound(sellAmount, 1, 1e30);
        buyAmount = bound(buyAmount, 1, 1e30);

        vm.prank(caller);
        try ADAPTER.placeOrder(_params(sellAmount, buyAmount, false)) {} catch {}
    }

    /// @notice Tokens arriving at the adapter outside any order, which a sweep may return.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        TOKEN.mint(address(ADAPTER), amount);
        donated += amount;
    }

    /// @dev Reverts (nothing uncommitted to return) are an expected outcome, not a failure.
    function sweepAsOwner() external {
        uint256 balanceBefore = TOKEN.balanceOf(address(ADAPTER));

        vm.prank(OWNER);
        try ADAPTER.sweep(address(TOKEN)) {
            returned += balanceBefore - TOKEN.balanceOf(address(ADAPTER));
        } catch {}
    }

    function _params(uint256 sellAmount, uint256 buyAmount, bool buyKind)
        internal
        returns (ICowProtocolAdapter.OrderParams memory params)
    {
        ++nonce;

        params = ICowProtocolAdapter.OrderParams({
            sellToken: address(TOKEN),
            buyToken: BUY_TOKEN,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: uint32(block.timestamp + nonce),
            appData: keccak256(abi.encode(nonce)),
            kind: buyKind ? ICowProtocolAdapter.OrderKind.Buy : ICowProtocolAdapter.OrderKind.Sell
        });
    }
}
