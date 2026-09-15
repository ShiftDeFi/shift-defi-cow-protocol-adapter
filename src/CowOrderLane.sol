// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICowOrderLane} from "./interfaces/ICowOrderLane.sol";
import {ICowProtocolAdapter} from "./interfaces/ICowProtocolAdapter.sol";
import {IGPv2Settlement} from "./interfaces/IGPv2Settlement.sol";

/// @title CowOrderLane
/// @notice The address an adapter's order names as its owner, so that the order holds a sell
///         token allowance row of its own.
/// @dev Deployed once per adapter as an implementation, then cloned per lane. A clone
///      `delegatecall`s this code, so every clone reads the immutables baked into this
///      contract's bytecode while `address(this)` is the clone's own address.
///
///      The reentrancy guard's slot belongs to the clone and reads as unentered at any value but
///      the entered one, so a clone is guarded from its first call without running a constructor.
contract CowOrderLane is ICowOrderLane, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal immutable ADAPTER;
    address internal immutable RECIPIENT;
    IGPv2Settlement internal immutable SETTLEMENT;
    address internal immutable VAULT_RELAYER;

    /// @dev Restricts a function to the adapter.
    modifier onlyAdapter() {
        _checkAdapter();
        _;
    }

    /// @dev Every counterparty is fixed here rather than passed per call.
    /// @param _adapter The adapter the lane obeys.
    /// @param _recipient The only address the lane can send value to, the adapter's owner.
    /// @param _settlement The settlement contract the lane cancels orders at.
    /// @param _vaultRelayer The address the lane grants token allowances to.
    constructor(address _adapter, address _recipient, address _settlement, address _vaultRelayer) {
        ADAPTER = _adapter;
        RECIPIENT = _recipient;
        SETTLEMENT = IGPv2Settlement(_settlement);
        VAULT_RELAYER = _vaultRelayer;
    }

    /// @inheritdoc ICowOrderLane
    function approveRelayer(address token, uint256 amount) external onlyAdapter nonReentrant {
        IERC20(token).forceApprove(VAULT_RELAYER, amount);
    }

    /// @inheritdoc ICowOrderLane
    function invalidateOrder(bytes calldata orderUid) external onlyAdapter nonReentrant {
        SETTLEMENT.invalidateOrder(orderUid);
    }

    /// @inheritdoc ICowOrderLane
    function drain(address token) external onlyAdapter nonReentrant returns (uint256) {
        uint256 amount = IERC20(token).balanceOf(address(this));

        if (amount != 0) {
            IERC20(token).safeTransfer(RECIPIENT, amount);
        }

        return amount;
    }

    /// @inheritdoc ICowOrderLane
    function isValidSignature(bytes32 orderDigest, bytes calldata) external view returns (bytes4) {
        return ICowProtocolAdapter(ADAPTER).isValidSignatureForLane(address(this), orderDigest);
    }

    /// @inheritdoc ICowOrderLane
    function adapter() external view returns (address) {
        return ADAPTER;
    }

    /// @inheritdoc ICowOrderLane
    function recipient() external view returns (address) {
        return RECIPIENT;
    }

    /// @inheritdoc ICowOrderLane
    function settlement() external view returns (address) {
        return address(SETTLEMENT);
    }

    /// @inheritdoc ICowOrderLane
    function vaultRelayer() external view returns (address) {
        return VAULT_RELAYER;
    }

    function _checkAdapter() internal view {
        require(msg.sender == ADAPTER, NotAdapter(msg.sender));
    }
}
