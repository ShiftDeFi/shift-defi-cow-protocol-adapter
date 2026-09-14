// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20HookOnTransferMock, ITransferRecipientHook} from "test/mocks/ERC20HookOnTransferMock.sol";

/// @title TransferWindowDonorMock
/// @notice A third party that delivers tokens to the recipient of a transfer while the
///         transferring call is still running.
/// @dev Used to land value inside the window `_pullSellToken` measures across, between its read
///      of the lane's balance before the pull and its read after. It mints rather than transfers
///      so that the amount arriving is exactly {AMOUNT}, undiminished by the token's own fee.
contract TransferWindowDonorMock is ITransferRecipientHook {
    ERC20HookOnTransferMock internal immutable TOKEN;
    uint256 internal immutable AMOUNT;

    constructor(ERC20HookOnTransferMock _token, uint256 _amount) {
        TOKEN = _token;
        AMOUNT = _amount;
    }

    /// @inheritdoc ITransferRecipientHook
    function onTokensReceived(address to, uint256) external {
        TOKEN.mint(to, AMOUNT);
    }
}
