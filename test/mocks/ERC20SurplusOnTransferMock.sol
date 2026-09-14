// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ERC20SurplusOnTransferMock
/// @notice An ERC-20 that credits the recipient of every transfer more than the sender sent.
/// @dev Stands in for a token that distributes to holders as it moves, so that a measured
///      balance change can exceed the amount transferred. The surplus is credited on transfers
///      between accounts only, not on minting or burning.
contract ERC20SurplusOnTransferMock is ERC20 {
    /// @notice The denominator the surplus is expressed against.
    uint256 internal constant BASIS_POINTS = 10_000;

    uint256 internal immutable SURPLUS_BASIS_POINTS;

    constructor(uint256 _surplusBasisPoints) ERC20("ERC20SurplusOnTransferMock", "E20S") {
        SURPLUS_BASIS_POINTS = _surplusBasisPoints;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (from == address(0) || to == address(0)) return;

        super._update(address(0), to, value * SURPLUS_BASIS_POINTS / BASIS_POINTS);
    }
}
