// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Test} from "forge-std/Test.sol";

import {CowProtocolAdapter} from "src/CowProtocolAdapter.sol";
import {ICowProtocolAdapter} from "src/interfaces/ICowProtocolAdapter.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {GPv2SettlementMock} from "test/mocks/GPv2SettlementMock.sol";

/// @notice Drives an order through its whole life — placed, filled by a solver, resolved or
///         cancelled — alongside unsolicited deliveries and sweeps, over two sell tokens.
/// @dev Sells tokens of its own rather than the shared fixture token, so its balance accounting
///      is not disturbed by {SweepHandler}. Every mint is counted in {minted}, which the
///      conservation invariant is stated against.
///
///      Two sell tokens rather than one, because lane occupancy is tracked per token. That lanes
///      are shared across tokens, and that a lane collision is only a collision within a single
///      token, are both invisible to a single-token run.
///
///      Reverts are an expected outcome throughout, so each action counts only what the adapter
///      accepted.
contract OrderLifecycleHandler is Test {
    CowProtocolAdapter internal immutable ADAPTER;
    GPv2SettlementMock internal immutable SETTLEMENT;
    ERC20Mock internal immutable TOKEN_A;
    ERC20Mock internal immutable TOKEN_B;
    address internal immutable OWNER;
    address internal immutable BUY_TOKEN;
    address internal immutable VAULT_RELAYER;

    /// @notice Every digest this handler ever placed, in placement order.
    bytes32[] public digests;

    /// @notice Orders the adapter accepted and has not yet resolved or cancelled.
    uint256 public pending;

    /// @notice The sell amounts of those orders, summed per sell token.
    mapping(address sellToken => uint256) public committed;

    /// @notice Everything this handler ever minted of a token, wherever it now sits.
    mapping(address token => uint256) public minted;

    /// @notice How much of each order's sell amount a fill has collected out of its lane.
    mapping(bytes32 orderDigest => uint256) public pulled;

    /// @notice Set if the adapter's deployed lane count was ever seen to fall across an action.
    bool public laneCountFell;

    /// @notice Set if any action other than placing an order was ever seen to change that count.
    bool public lanesMovedOutsidePlacement;

    /// @dev How many sell tokens this handler places orders over.
    uint256 internal constant SELL_TOKEN_COUNT = 2;

    /// @dev Varies `validTo` and `appData`, so successive orders do not share a digest.
    uint32 internal nonce;

    /// @dev Lanes are allocated only in `placeOrder`, so the count may rise across an accepted
    ///      placement. Nothing retires a lane, so it must never fall.
    modifier lanesMayOnlyRise() {
        uint256 lanesBefore = ADAPTER.deployedLaneCount();
        _;
        if (ADAPTER.deployedLaneCount() < lanesBefore) {
            laneCountFell = true;
        }
    }

    /// @dev No entry point other than `placeOrder` touches the count at all, a placement the
    ///      adapter rejects included.
    modifier lanesUnmoved() {
        uint256 lanesBefore = ADAPTER.deployedLaneCount();
        _;
        if (ADAPTER.deployedLaneCount() != lanesBefore) {
            lanesMovedOutsidePlacement = true;
        }
    }

    constructor(CowProtocolAdapter _adapter, GPv2SettlementMock _settlement, address _owner, address _buyToken) {
        ADAPTER = _adapter;
        SETTLEMENT = _settlement;
        OWNER = _owner;
        BUY_TOKEN = _buyToken;
        VAULT_RELAYER = _adapter.vaultRelayer();
        TOKEN_A = new ERC20Mock();
        TOKEN_B = new ERC20Mock();
    }

    /// @notice How many sell tokens orders are placed over.
    function sellTokenCount() external pure returns (uint256) {
        return SELL_TOKEN_COUNT;
    }

    /// @notice One of the tokens the orders placed here sell.
    function sellTokenAt(uint256 index) external view returns (ERC20Mock) {
        return index == 0 ? TOKEN_A : TOKEN_B;
    }

    /// @dev The lane an order would take is read before placing, so what arrives can be
    ///      measured on it.
    function placeOrderAsOwner(uint256 tokenSeed, uint256 sellAmount, uint256 buyAmount) external lanesMayOnlyRise {
        ERC20Mock sellToken = _sellTokenAt(tokenSeed);
        sellAmount = bound(sellAmount, 1, 1e30);
        buyAmount = bound(buyAmount, 1, 1e30);

        _mint(sellToken, OWNER, sellAmount);
        vm.prank(OWNER);
        sellToken.approve(address(ADAPTER), sellAmount);

        vm.prank(OWNER);
        try ADAPTER.placeOrder(_params(sellToken, sellAmount, buyAmount)) returns (bytes32 orderDigest) {
            digests.push(orderDigest);
            ++pending;
            committed[address(sellToken)] += sellAmount;
        } catch {}
    }

    /// @dev A rejected placement must record nothing, pull nothing and deploy no lane.
    function placeOrderAsStranger(address caller, uint256 tokenSeed, uint256 sellAmount, uint256 buyAmount)
        external
        lanesUnmoved
    {
        vm.assume(caller != OWNER);
        sellAmount = bound(sellAmount, 1, 1e30);
        buyAmount = bound(buyAmount, 1, 1e30);

        vm.prank(caller);
        try ADAPTER.placeOrder(_params(_sellTokenAt(tokenSeed), sellAmount, buyAmount)) {} catch {}
    }

    /// @notice A solver settling one of the pending orders: the relayer collects the sell tokens
    ///         out of the order's own lane and settlement records the fill.
    /// @dev `share` lets the pull fall short of the sell amount, as a buy order filling under its
    ///      limit would. Either way it is a fill.
    function fillOrderAsSolver(uint256 seed, uint256 share) external lanesUnmoved {
        (bytes32 orderDigest, ICowProtocolAdapter.OrderRecord memory record) = _pendingOrderAt(seed);
        if (record.status != ICowProtocolAdapter.OrderStatus.Pending) {
            return;
        }

        ERC20Mock sellToken = ERC20Mock(record.sellToken);
        address lane = ADAPTER.laneAt(record.lane);
        uint256 amount = bound(share, 1, sellToken.allowance(lane, VAULT_RELAYER));

        vm.prank(VAULT_RELAYER);
        sellToken.transferFrom(lane, VAULT_RELAYER, amount);
        pulled[orderDigest] += amount;

        SETTLEMENT.setFilledAmount(_uidOf(orderDigest, record), record.sellAmount);
    }

    /// @notice A solver reclaiming the fill record's storage once the order has expired.
    function clearFillRecordAsSolver(uint256 seed) external lanesUnmoved {
        (bytes32 orderDigest, ICowProtocolAdapter.OrderRecord memory record) = _pendingOrderAt(seed);
        if (record.status != ICowProtocolAdapter.OrderStatus.Pending) {
            return;
        }

        vm.warp(uint256(record.validTo) + 1);

        try SETTLEMENT.freeFilledAmountStorage(_uidOf(orderDigest, record)) {} catch {}
    }

    function resolveOrderAsOwner(uint256 seed) external lanesUnmoved {
        (bytes32 orderDigest, ICowProtocolAdapter.OrderRecord memory record) = _pendingOrderAt(seed);

        vm.prank(OWNER);
        try ADAPTER.resolveOrder(orderDigest) {
            --pending;
            committed[record.sellToken] -= record.sellAmount;
        } catch {}
    }

    function cancelOrderAsOwner(uint256 seed) external lanesUnmoved {
        (bytes32 orderDigest, ICowProtocolAdapter.OrderRecord memory record) = _pendingOrderAt(seed);

        vm.prank(OWNER);
        try ADAPTER.cancelOrder(orderDigest) {
            --pending;
            committed[record.sellToken] -= record.sellAmount;
        } catch {}
    }

    /// @dev Succeeds only where every order resolved.
    function requireNoPendingOrdersAsOwner() external lanesUnmoved {
        vm.prank(OWNER);
        try ADAPTER.requireNoPendingOrders() {
            pending = 0;
            committed[address(TOKEN_A)] = 0;
            committed[address(TOKEN_B)] = 0;
        } catch {}
    }

    /// @notice Tokens arriving at the adapter outside any order.
    function donate(uint256 tokenSeed, uint256 amount) external lanesUnmoved {
        _mint(_sellTokenAt(tokenSeed), address(ADAPTER), bound(amount, 1, 1e30));
    }

    /// @notice Tokens arriving at a lane outside any order.
    function donateToLane(uint256 seed, uint256 tokenSeed, uint256 amount) external lanesUnmoved {
        uint256 lanes = ADAPTER.deployedLaneCount();
        if (lanes == 0) {
            return;
        }

        _mint(_sellTokenAt(tokenSeed), ADAPTER.laneAt(bound(seed, 0, lanes - 1)), bound(amount, 1, 1e30));
    }

    function sweepAsOwner(uint256 tokenSeed) external lanesUnmoved {
        vm.prank(OWNER);
        try ADAPTER.sweep(address(_sellTokenAt(tokenSeed))) {} catch {}
    }

    function sweepLaneAsOwner(uint256 seed, uint256 tokenSeed) external lanesUnmoved {
        uint256 lanes = ADAPTER.deployedLaneCount();
        if (lanes == 0) {
            return;
        }

        uint256 index = bound(seed, 0, lanes - 1);

        vm.prank(OWNER);
        try ADAPTER.sweepLane(index, address(_sellTokenAt(tokenSeed))) {} catch {}
    }

    /// @notice How many orders this handler has placed over the whole run.
    function placed() external view returns (uint256) {
        return digests.length;
    }

    /// @notice How many lanes carry a pending order, summed over both sell tokens.
    /// @dev A lane counts once per token occupying it, since one lane can carry an order on each
    ///      token at the same time. That sum, not a single token's, is what the pending count is.
    function occupiedLaneCount() external view returns (uint256) {
        return _occupiedLaneCount(address(TOKEN_A)) + _occupiedLaneCount(address(TOKEN_B));
    }

    /// @notice A token's balance across every address it can legitimately be held at.
    /// @dev The relayer stands in for settlement, holding whatever a fill collected.
    function totalHeld(address token) external view returns (uint256) {
        uint256 total = ERC20Mock(token).balanceOf(OWNER) + ERC20Mock(token).balanceOf(address(ADAPTER))
            + ERC20Mock(token).balanceOf(VAULT_RELAYER);

        uint256 lanes = ADAPTER.deployedLaneCount();

        for (uint256 i; i < lanes; ++i) {
            total += ERC20Mock(token).balanceOf(ADAPTER.laneAt(i));
        }

        return total;
    }

    /// @dev Splits the fuzzer's seed across the two sell tokens.
    function _sellTokenAt(uint256 seed) internal view returns (ERC20Mock) {
        return seed % SELL_TOKEN_COUNT == 0 ? TOKEN_A : TOKEN_B;
    }

    function _mint(ERC20Mock token, address to, uint256 amount) internal {
        token.mint(to, amount);
        minted[address(token)] += amount;
    }

    /// @dev How many lanes the token's occupancy field marks as carrying an order.
    function _occupiedLaneCount(address token) internal view returns (uint256) {
        uint256 occupancy = ADAPTER.laneOccupancy(token);
        uint256 count;

        for (uint256 i; i < 256; ++i) {
            if (occupancy & (1 << i) != 0) {
                ++count;
            }
        }

        return count;
    }

    /// @dev One of the digests placed so far, with its current record. Returns a zeroed record
    ///      where nothing has been placed yet.
    function _pendingOrderAt(uint256 seed) internal view returns (bytes32, ICowProtocolAdapter.OrderRecord memory) {
        ICowProtocolAdapter.OrderRecord memory record;

        uint256 length = digests.length;
        if (length == 0) {
            return (bytes32(0), record);
        }

        bytes32 orderDigest = digests[bound(seed, 0, length - 1)];

        return (orderDigest, ADAPTER.orderRecord(orderDigest));
    }

    function _uidOf(bytes32 orderDigest, ICowProtocolAdapter.OrderRecord memory record)
        internal
        view
        returns (bytes memory)
    {
        return GPv2Order.packOrderUidParams(orderDigest, ADAPTER.laneAt(record.lane), record.validTo);
    }

    function _params(ERC20Mock sellToken, uint256 sellAmount, uint256 buyAmount)
        internal
        returns (ICowProtocolAdapter.OrderParams memory)
    {
        ++nonce;

        return ICowProtocolAdapter.OrderParams({
            sellToken: address(sellToken),
            buyToken: BUY_TOKEN,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: uint32(block.timestamp + nonce),
            appData: keccak256(abi.encode(nonce))
        });
    }
}
