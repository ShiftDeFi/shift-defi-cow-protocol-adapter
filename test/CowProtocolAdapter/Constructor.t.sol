// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {IOwnerImmutable} from "src/interfaces/IOwnerImmutable.sol";

import {CowProtocolAdapterBase} from "test/CowProtocolAdapter/CowProtocolAdapterBase.sol";
import {GPv2SettlementMock} from "test/mocks/GPv2SettlementMock.sol";

contract CowProtocolAdapterConstructorTest is CowProtocolAdapterBase {
    function test_Constructor_SetsOwner() public view {
        assertEq(adapter.owner(), OWNER);
    }

    function test_Constructor_SetsSettlement() public view {
        assertEq(adapter.settlement(), address(settlement));
    }

    function test_Constructor_SetsVaultRelayer() public view {
        assertEq(adapter.vaultRelayer(), VAULT_RELAYER);
    }

    function test_Constructor_SetsDomainSeparator() public view {
        assertEq(adapter.domainSeparator(), DOMAIN_SEPARATOR);
    }

    function test_Constructor_EmitsOwnerSet() public {
        vm.expectEmit(true, false, false, false);
        emit IOwnerImmutable.OwnerSet(OWNER);
        new CowProtocolAdapter(OWNER, address(settlement));
    }

    function test_Constructor_EmitsSettlementSet() public {
        vm.expectEmit(true, true, false, true);
        emit ICowProtocolAdapter.SettlementSet(address(settlement), VAULT_RELAYER, DOMAIN_SEPARATOR);
        new CowProtocolAdapter(OWNER, address(settlement));
    }

    function test_RevertIf_Constructor_ZeroOwner() public {
        vm.expectRevert(IOwnerImmutable.ZeroAddress.selector);
        new CowProtocolAdapter(address(0), address(settlement));
    }

    function test_RevertIf_Constructor_ZeroSettlement() public {
        vm.expectRevert(ICowProtocolAdapter.ZeroSettlement.selector);
        new CowProtocolAdapter(OWNER, address(0));
    }

    function test_RevertIf_Constructor_ZeroVaultRelayer() public {
        GPv2SettlementMock unrelayed = new GPv2SettlementMock(address(0), DOMAIN_SEPARATOR);

        vm.expectRevert(ICowProtocolAdapter.ZeroVaultRelayer.selector);
        new CowProtocolAdapter(OWNER, address(unrelayed));
    }

    function test_RevertIf_Constructor_ZeroDomainSeparator() public {
        GPv2SettlementMock undomained = new GPv2SettlementMock(VAULT_RELAYER, bytes32(0));

        vm.expectRevert(ICowProtocolAdapter.ZeroDomainSeparator.selector);
        new CowProtocolAdapter(OWNER, address(undomained));
    }

    /// @dev The settlement address is called during construction, so a non-contract is
    ///      rejected by the compiler's extcodesize check, with empty revert data.
    function test_RevertIf_Constructor_SettlementNotAContract() public {
        vm.expectRevert(bytes(""));
        new CowProtocolAdapter(OWNER, STRANGER);
    }
}
