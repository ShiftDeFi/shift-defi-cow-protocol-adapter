// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ITransferRecipientHook
/// @notice The notification an {ERC20HookOnTransferMock} delivers once a transfer has credited
///         its recipient.
interface ITransferRecipientHook {
    /// @notice Called after `to` has been credited, while the transferring call is still running.
    /// @param to The account that was credited.
    /// @param value The amount it was credited with.
    function onTokensReceived(address to, uint256 value) external;
}

/// @title ERC20HookOnTransferMock
/// @notice An ERC-20 that burns a fixed proportion of every transfer and then hands control to a
///         registered hook, the way an ERC-777 `tokensReceived` notification does.
/// @dev Stands in for a token that lets a third party act between a caller's two balance reads,
///      which is what it takes to reach inside the measurement window in `_pullSellToken`. The
///      fee is charged and the hook fired on transfers between accounts only, not on minting or
///      burning, and the hook is suppressed while it is already running so that a hook which
///      itself moves the token does not recurse.
contract ERC20HookOnTransferMock is ERC20 {
    ITransferRecipientHook internal hook;
    bool internal notifying;

    /// @notice The denominator the fee is expressed against.
    uint256 internal constant BASIS_POINTS = 10_000;

    uint256 internal immutable FEE_BASIS_POINTS;

    constructor(uint256 _feeBasisPoints) ERC20("ERC20HookOnTransferMock", "E20H") {
        FEE_BASIS_POINTS = _feeBasisPoints;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    /// @notice Registers the hook notified after each transfer between accounts.
    function setHook(ITransferRecipientHook _hook) external {
        hook = _hook;
    }

    /// @notice What a transfer of `value` burns as a fee.
    function feeOn(uint256 value) external view returns (uint256) {
        return value * FEE_BASIS_POINTS / BASIS_POINTS;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * FEE_BASIS_POINTS / BASIS_POINTS;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);

        if (address(hook) == address(0) || notifying) {
            return;
        }

        notifying = true;
        hook.onTokensReceived(to, value - fee);
        notifying = false;
    }
}
