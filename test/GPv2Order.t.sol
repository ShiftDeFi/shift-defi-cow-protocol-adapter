// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

contract GPv2OrderTest is Test {
    /// @dev Written out independently of {GPv2Order.TYPE_STRING}, which is assembled from
    ///      three adjacent literals, so a mistake at either seam is caught here.
    string internal constant EXPECTED_TYPE_STRING = "Order(address sellToken,address buyToken,address receiver,"
        "uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,"
        "bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)";

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("GPv2OrderTest.domainSeparator");

    function test_TypeString_MatchesEip712Encoding() public pure {
        assertEq(GPv2Order.TYPE_STRING, EXPECTED_TYPE_STRING);
    }

    function test_TypeHash_MatchesTypeString() public pure {
        assertEq(GPv2Order.TYPE_HASH, keccak256(bytes(EXPECTED_TYPE_STRING)));
    }

    function test_KindSell_MatchesLabel() public pure {
        assertEq(GPv2Order.KIND_SELL, keccak256("sell"));
    }

    function test_KindBuy_MatchesLabel() public pure {
        assertEq(GPv2Order.KIND_BUY, keccak256("buy"));
    }

    function test_BalanceErc20_MatchesLabel() public pure {
        assertEq(GPv2Order.BALANCE_ERC20, keccak256("erc20"));
    }

    function test_Hash_MatchesEip712Digest() public pure {
        GPv2Order.Data memory order = _order();

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(EXPECTED_TYPE_STRING)),
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                order.kind,
                order.partiallyFillable,
                order.sellTokenBalance,
                order.buyTokenBalance
            )
        );

        assertEq(
            GPv2Order.hash(order, DOMAIN_SEPARATOR),
            keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash))
        );
    }

    /// @dev Every one of the twelve fields must move the result.
    function test_Hash_DependsOnEveryField() public pure {
        bytes32 base = GPv2Order.hash(_order(), DOMAIN_SEPARATOR);

        GPv2Order.Data memory mutated = _order();
        mutated.sellToken = address(0xDEAD);
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.buyToken = address(0xDEAD);
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.receiver = address(0xDEAD);
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.sellAmount += 1;
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.buyAmount += 1;
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.validTo += 1;
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.appData = keccak256("other");
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.feeAmount += 1;
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.kind = GPv2Order.KIND_BUY;
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.partiallyFillable = true;
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.sellTokenBalance = keccak256("internal");
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);

        mutated = _order();
        mutated.buyTokenBalance = keccak256("internal");
        assertNotEq(GPv2Order.hash(mutated, DOMAIN_SEPARATOR), base);
    }

    /// @dev The domain separator binds a signature to one settlement contract and chain.
    function testFuzz_Hash_DependsOnDomainSeparator(bytes32 otherDomainSeparator) public pure {
        vm.assume(otherDomainSeparator != DOMAIN_SEPARATOR);

        assertNotEq(GPv2Order.hash(_order(), otherDomainSeparator), GPv2Order.hash(_order(), DOMAIN_SEPARATOR));
    }

    function testFuzz_PackOrderUidParams_Layout(bytes32 orderDigest, address owner, uint32 validTo) public pure {
        bytes memory uid = GPv2Order.packOrderUidParams(orderDigest, owner, validTo);
        assertEq(uid.length, GPv2Order.UID_LENGTH);

        bytes32 head;
        bytes32 tail;
        assembly {
            head := mload(add(uid, 32))
            tail := mload(add(uid, 56))
        }

        assertEq(head, orderDigest);
        assertEq(address(uint160(uint256(tail) >> 32)), owner);
        assertEq(uint32(uint256(tail)), validTo);
    }

    function _order() internal pure returns (GPv2Order.Data memory order) {
        order = GPv2Order.Data({
            sellToken: address(0xA11CE),
            buyToken: address(0xB0B),
            receiver: address(0xBEEF),
            sellAmount: 100e18,
            buyAmount: 99e18,
            validTo: 1_800_000_000,
            appData: keccak256("appData"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
