// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ERC20FeeOnTransferMock
/// @notice An ERC-20 that burns a fixed proportion of every transfer, so the recipient
///         receives less than the sender sent.
/// @dev Stands in for a token whose owner has turned a transfer fee on. The fee is charged on
///      transfers between accounts only, not on minting or burning.
contract ERC20FeeOnTransferMock is ERC20 {
    /// @notice The denominator the fee is expressed against.
    uint256 internal constant BASIS_POINTS = 10_000;

    uint256 internal immutable FEE_BASIS_POINTS;

    constructor(uint256 _feeBasisPoints) ERC20("ERC20FeeOnTransferMock", "E20F") {
        FEE_BASIS_POINTS = _feeBasisPoints;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * FEE_BASIS_POINTS / BASIS_POINTS;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
