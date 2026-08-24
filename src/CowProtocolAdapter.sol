// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICowProtocolAdapter} from "./interfaces/ICowProtocolAdapter.sol";
import {OwnerImmutable} from "./OwnerImmutable.sol";

/// @title CowProtocolAdapter
/// @notice Adapter contract for integrating CoW Protocol swaps.
/// @dev One instance per consuming contract; the owner is that contract, fixed at construction.
contract CowProtocolAdapter is ICowProtocolAdapter, OwnerImmutable {
    using SafeERC20 for IERC20;

    constructor(address _owner) OwnerImmutable(_owner) {}

    function sweep(IERC20 token) external onlyOwner {
        uint256 amount = token.balanceOf(address(this));
        require(amount != 0, NothingToSweep());

        emit TokensSwept(address(token), amount);
        token.safeTransfer(OWNER, amount);
    }
}
