// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";

import {GPv2SettlementMock} from "test/mocks/GPv2SettlementMock.sol";

/// @title CowProtocolAdapterBase
/// @notice Shared fixture for every test of {CowProtocolAdapter}: a deployed adapter bound to
///         a mock settlement, plus a token the adapter can hold a balance of.
/// @dev Overrides of {setUp} must call `super.setUp()` first.
abstract contract CowProtocolAdapterBase is Test {
    address internal constant OWNER = address(0xBEEF);
    address internal constant STRANGER = address(0xCAFE);
    address internal constant VAULT_RELAYER = address(0xD00D);
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("CowProtocolAdapterBase.domainSeparator");

    CowProtocolAdapter internal adapter;
    ERC20Mock internal token;
    GPv2SettlementMock internal settlement;

    function setUp() public virtual {
        settlement = new GPv2SettlementMock(VAULT_RELAYER, DOMAIN_SEPARATOR);
        adapter = new CowProtocolAdapter(OWNER, address(settlement));
        token = new ERC20Mock();
    }
}
