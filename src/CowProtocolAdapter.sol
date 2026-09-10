// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CowOrderLane} from "./CowOrderLane.sol";
import {ICowOrderLane} from "./interfaces/ICowOrderLane.sol";
import {ICowProtocolAdapter} from "./interfaces/ICowProtocolAdapter.sol";
import {IGPv2Settlement} from "./interfaces/IGPv2Settlement.sol";
import {GPv2Order} from "./libraries/GPv2Order.sol";
import {OwnerImmutable} from "./OwnerImmutable.sol";

/// @title CowProtocolAdapter
/// @notice Adapter contract for integrating CoW Protocol swaps.
/// @dev One instance per consuming contract; the owner is that contract, fixed at construction.
contract CowProtocolAdapter is ICowProtocolAdapter, OwnerImmutable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using GPv2Order for GPv2Order.Data;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal _deployedLanes;
    mapping(bytes32 orderDigest => OrderRecord) internal _orderRecords;
    mapping(address sellToken => uint256) internal _laneOccupancy;
    EnumerableSet.Bytes32Set internal _pendingDigests;

    /// @dev How many lanes a sell token has, and the width of the occupancy field in
    ///      {_laneOccupancy}: bit `i` stands for lane `i`, so the field holds exactly this many
    ///      lanes and the highest index is one below it.
    uint256 internal constant LANE_COUNT = 256;

    IGPv2Settlement internal immutable SETTLEMENT;
    address internal immutable VAULT_RELAYER;
    bytes32 internal immutable DOMAIN_SEPARATOR;
    address internal immutable LANE_IMPLEMENTATION;

    constructor(address _owner, address _settlement) OwnerImmutable(_owner) {
        require(_settlement != address(0), ZeroSettlement());

        address relayer = IGPv2Settlement(_settlement).vaultRelayer();
        require(relayer != address(0), ZeroVaultRelayer());

        bytes32 separator = IGPv2Settlement(_settlement).domainSeparator();
        require(separator != bytes32(0), ZeroDomainSeparator());

        SETTLEMENT = IGPv2Settlement(_settlement);
        VAULT_RELAYER = relayer;
        DOMAIN_SEPARATOR = separator;
        LANE_IMPLEMENTATION = address(new CowOrderLane(address(this), _owner, _settlement, relayer));

        emit SettlementSet(_settlement, relayer, separator);
    }

    /// @inheritdoc ICowProtocolAdapter
    function placeOrder(OrderParams calldata params) external onlyOwner nonReentrant returns (bytes memory uid) {
        _validateOrderParams(params);
        require(params.validTo > block.timestamp, ValidToInPast(params.validTo, block.timestamp));

        GPv2Order.Data memory order = _buildOrder(params);
        bytes32 orderDigest = order.hash(DOMAIN_SEPARATOR);
        require(_orderRecords[orderDigest].status == OrderStatus.None, OrderDigestUsed(orderDigest));

        (address lane, uint256 index) = _occupyLane(params.sellToken);
        _pullSellToken(lane, params.sellToken, params.sellAmount);

        _orderRecords[orderDigest] = OrderRecord({
            sellToken: params.sellToken,
            validTo: params.validTo,
            status: OrderStatus.Pending,
            lane: index.toUint8(),
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount
        });
        // Redundant against the status check above, and kept because it is what makes the
        // pending set and the record's status two views of one fact rather than two facts.
        require(_pendingDigests.add(orderDigest), OrderDigestUsed(orderDigest));

        uid = GPv2Order.packOrderUidParams(orderDigest, lane, params.validTo);

        emit OrderPlaced(
            orderDigest,
            params.sellToken,
            params.buyToken,
            params.sellAmount,
            params.buyAmount,
            params.validTo,
            lane,
            uid
        );

        ICowOrderLane(lane).approveRelayer(params.sellToken, params.sellAmount);
    }

    /// @inheritdoc ICowProtocolAdapter
    function resolveOrder(bytes32 orderDigest) external onlyOwner nonReentrant {
        OrderRecord memory record = _orderRecords[orderDigest];
        require(record.status == OrderStatus.Pending, OrderNotPending(orderDigest));

        (FillVerdict verdict, uint256 filled) = _fillVerdict(orderDigest, record);
        require(verdict == FillVerdict.Filled, OrderNotFilled(orderDigest, verdict));

        _releaseFilledOrder(orderDigest, record, filled);
    }

    /// @inheritdoc ICowProtocolAdapter
    function requireNoPendingOrders() external onlyOwner nonReentrant {
        bytes32[] memory orderDigests = _pendingDigests.values();
        uint256 length = orderDigests.length;

        for (uint256 i; i < length; ++i) {
            bytes32 orderDigest = orderDigests[i];
            OrderRecord memory record = _orderRecords[orderDigest];

            (FillVerdict verdict, uint256 filled) = _fillVerdict(orderDigest, record);
            if (verdict == FillVerdict.Filled) {
                _releaseFilledOrder(orderDigest, record, filled);
            }
        }

        uint256 stillPending = _pendingDigests.length();
        require(stillPending == 0, OrdersStillPending(stillPending));
    }

    /// @inheritdoc ICowProtocolAdapter
    function cancelOrder(bytes32 orderDigest) external onlyOwner nonReentrant {
        OrderRecord memory record = _orderRecords[orderDigest];
        require(record.status == OrderStatus.Pending, OrderNotPending(orderDigest));

        (FillVerdict verdict, uint256 filled) = _fillVerdict(orderDigest, record);
        require(verdict != FillVerdict.Filled, OrderFilled(orderDigest, filled));

        _orderRecords[orderDigest].status = OrderStatus.Cancelled;
        require(_pendingDigests.remove(orderDigest), OrderNotPending(orderDigest));
        _freeLane(record.sellToken, record.lane);

        address lane = _laneAt(record.lane);

        // Unconditional, and idempotent where settlement already holds the marker: the point is
        // that no trade against this order can settle after the sell tokens have gone home.
        ICowOrderLane(lane).invalidateOrder(GPv2Order.packOrderUidParams(orderDigest, lane, record.validTo));
        ICowOrderLane(lane).approveRelayer(record.sellToken, 0);
        uint256 returned = ICowOrderLane(lane).drain(record.sellToken);

        emit OrderCancelled(orderDigest, record.sellToken, returned);
    }

    /// @inheritdoc ICowProtocolAdapter
    function sweep(address token) external onlyOwner nonReentrant {
        require(token != address(0), ZeroAddress());

        uint256 amount = IERC20(token).balanceOf(address(this));
        require(amount != 0, NothingToSweep());

        emit TokensSwept(token, amount);
        IERC20(token).safeTransfer(OWNER, amount);
    }

    /// @inheritdoc ICowProtocolAdapter
    function sweepLane(uint256 laneIndex, address token) external onlyOwner nonReentrant {
        require(token != address(0), ZeroAddress());

        uint256 deployed = _deployedLanes;
        require(laneIndex < deployed, LaneIndexOutOfRange(laneIndex, deployed));
        require(_laneOccupancy[token] & _laneBit(laneIndex) == 0, LaneOccupied(laneIndex, token));

        uint256 amount = ICowOrderLane(_laneAt(laneIndex)).drain(token);
        require(amount != 0, NothingToSweep());

        emit LaneSwept(laneIndex, token, amount);
    }

    /// @inheritdoc ICowProtocolAdapter
    function isValidSignatureForLane(address lane, bytes32 orderDigest) external view returns (bytes4 magicValue) {
        OrderRecord storage record = _orderRecords[orderDigest];

        if (record.status == OrderStatus.Pending && _laneAt(record.lane) == lane) {
            magicValue = IERC1271.isValidSignature.selector;
        }
    }

    /// @inheritdoc ICowProtocolAdapter
    function orderUid(OrderParams calldata params, uint256 laneIndex) external view returns (bytes memory) {
        _validateOrderParams(params);
        require(laneIndex < LANE_COUNT, LaneIndexTooLarge(laneIndex, LANE_COUNT));

        GPv2Order.Data memory order = _buildOrder(params);
        return GPv2Order.packOrderUidParams(order.hash(DOMAIN_SEPARATOR), _laneAt(laneIndex), params.validTo);
    }

    /// @inheritdoc ICowProtocolAdapter
    function nextLane(address sellToken) external view returns (address lane, uint256 index) {
        index = _lowestFreeLane(sellToken);
        lane = _laneAt(index);
    }

    /// @inheritdoc ICowProtocolAdapter
    function laneAt(uint256 index) external view returns (address) {
        require(index < LANE_COUNT, LaneIndexTooLarge(index, LANE_COUNT));

        return _laneAt(index);
    }

    /// @inheritdoc ICowProtocolAdapter
    function laneOccupancy(address token) external view returns (uint256) {
        return _laneOccupancy[token];
    }

    /// @inheritdoc ICowProtocolAdapter
    function deployedLaneCount() external view returns (uint256) {
        return _deployedLanes;
    }

    /// @inheritdoc ICowProtocolAdapter
    function laneImplementation() external view returns (address) {
        return LANE_IMPLEMENTATION;
    }

    /// @inheritdoc ICowProtocolAdapter
    function orderRecord(bytes32 orderDigest) external view returns (OrderRecord memory) {
        return _orderRecords[orderDigest];
    }

    /// @inheritdoc ICowProtocolAdapter
    function fillVerdict(bytes32 orderDigest) external view returns (FillVerdict, uint256) {
        OrderRecord memory record = _orderRecords[orderDigest];
        require(record.status == OrderStatus.Pending, OrderNotPending(orderDigest));

        return _fillVerdict(orderDigest, record);
    }

    /// @inheritdoc ICowProtocolAdapter
    function pendingOrderCount() external view returns (uint256) {
        return _pendingDigests.length();
    }

    /// @inheritdoc ICowProtocolAdapter
    function pendingOrderDigests() external view returns (bytes32[] memory) {
        return _pendingDigests.values();
    }

    /// @inheritdoc ICowProtocolAdapter
    function settlement() external view returns (address) {
        return address(SETTLEMENT);
    }

    /// @inheritdoc ICowProtocolAdapter
    function vaultRelayer() external view returns (address) {
        return VAULT_RELAYER;
    }

    /// @inheritdoc ICowProtocolAdapter
    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    /// @dev Records a filled order as resolved: releases its commitment, frees its lane and
    ///      sends whatever the lane still holds of the sell token to the owner. The caller has
    ///      established the verdict, so this writes rather than judges.
    ///
    ///      A filled order's whole sell amount was collected by the settlement that filled it,
    ///      so what the drain finds is anything delivered above it at placement, plus anything
    ///      that arrived unsolicited. Both are the owner's. The lane is left approving nothing,
    ///      which is the state the next order to take it expects.
    /// @param orderDigest The order's EIP-712 digest.
    /// @param record The order's record, which must be pending and established as filled.
    /// @param filled The sell amount settlement records the order as filled for.
    function _releaseFilledOrder(bytes32 orderDigest, OrderRecord memory record, uint256 filled) internal {
        _orderRecords[orderDigest].status = OrderStatus.Filled;
        require(_pendingDigests.remove(orderDigest), OrderNotPending(orderDigest));
        _freeLane(record.sellToken, record.lane);

        address lane = _laneAt(record.lane);
        ICowOrderLane(lane).approveRelayer(record.sellToken, 0);
        uint256 returned = ICowOrderLane(lane).drain(record.sellToken);

        emit OrderResolved(orderDigest, record.sellToken, record.sellAmount, filled, returned);
    }

    /// @dev Marks a lane as carrying no order on `sellToken`. Never lowers {deployedLaneCount}
    ///      and never destroys the lane: a freed lane is handed to the next order that needs
    ///      one, which is what keeps the number of lanes at peak concurrency rather than at the
    ///      number of orders ever placed. Only this token's bit is cleared — the lane may be
    ///      carrying orders on other tokens, in rows this one does not touch.
    /// @param sellToken The token the order sold.
    /// @param index The lane's index.
    function _freeLane(address sellToken, uint256 index) internal {
        _laneOccupancy[sellToken] &= ~_laneBit(index);
    }

    /// @dev Marks the lowest free lane on `sellToken` as carrying an order, deploying it where
    ///      that index has never been used. Being handed index `i` means bits `0` to `i - 1` are
    ///      set, so those lanes each carry a pending order and each was therefore deployed:
    ///      `i` never exceeds the number deployed, the deployed lanes are always the dense
    ///      prefix `0` to `_deployedLanes - 1`, and the counter can only rise by one.
    /// @param sellToken The token the order sells.
    /// @return lane The lane's address.
    /// @return index The lane's index.
    function _occupyLane(address sellToken) internal returns (address lane, uint256 index) {
        index = _lowestFreeLane(sellToken);

        uint256 deployed = _deployedLanes;
        require(index <= deployed, LaneIndexOutOfRange(index, deployed));

        if (index == deployed) {
            _deployedLanes = deployed + 1;
            lane = Clones.cloneDeterministic(LANE_IMPLEMENTATION, bytes32(index));

            emit LaneDeployed(index, lane);
        } else {
            lane = _laneAt(index);
        }

        _laneOccupancy[sellToken] |= _laneBit(index);
    }

    /// @dev Pulls sell tokens from the caller to the order's lane and requires the lane's balance
    ///      to grow by at least `amount`, so a token taking a fee on transfer reverts. A larger
    ///      delivery is accepted and reaches the owner when the order resolves.
    /// @param lane The lane that owns the order.
    /// @param token The order's sell token.
    /// @param amount The amount to pull.
    function _pullSellToken(address lane, address token, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(lane);
        IERC20(token).safeTransferFrom(msg.sender, lane, amount);
        uint256 received = IERC20(token).balanceOf(lane) - balanceBefore;

        require(received >= amount, SellTokenShortfall(amount, received));
    }

    /// @dev Judges whether a pending order has filled, per {ICowProtocolAdapter.FillVerdict}.
    ///      Settlement's record decides it wherever that record is conclusive: an amount is a
    ///      fill of this order alone, since a record is keyed by an identifier no other order
    ///      shares. Once the order has expired that record may have been cleared for a gas
    ///      refund, and the lane's relayer allowance decides instead — the adapter set it to
    ///      this order's sell amount at placement, no other order can spend the row, and nothing
    ///      but a pull lowers it, so a shortfall is this order's own fill.
    ///
    ///      The two agree wherever both are available, so which one answers is not observable:
    ///      the allowance arm is reached only for an order whose record reads zero.
    /// @param orderDigest The order's EIP-712 digest.
    /// @param record The order's record, which must be pending.
    /// @return verdict What the adapter establishes about the order.
    /// @return filled The sell amount settlement records the order as filled for.
    function _fillVerdict(bytes32 orderDigest, OrderRecord memory record)
        internal
        view
        returns (FillVerdict verdict, uint256 filled)
    {
        address lane = _laneAt(record.lane);
        filled = SETTLEMENT.filledAmount(GPv2Order.packOrderUidParams(orderDigest, lane, record.validTo));

        if (filled == type(uint256).max) {
            return (FillVerdict.Invalidated, filled);
        }
        if (filled != 0) {
            return (FillVerdict.Filled, filled);
        }
        if (IERC20(record.sellToken).allowance(lane, VAULT_RELAYER) < record.sellAmount) {
            return (FillVerdict.Filled, filled);
        }

        return (FillVerdict.Unfilled, filled);
    }

    /// @dev The occupancy bit standing for a lane index. Exponentiation rather than a shift
    ///      because it fails closed: `2 ** index` reverts once `index` reaches 256, where
    ///      `1 << index` evaluates to zero and would turn the caller's `|=` into a no-op,
    ///      leaving a lane that already carries an order free to be handed a second one.
    ///      {_lowestFreeLane} cannot return an index above 255, so no caller reaches that
    ///      boundary.
    /// @param index The lane's index.
    /// @return The bit for that lane.
    function _laneBit(uint256 index) internal pure returns (uint256) {
        return 2 ** index;
    }

    /// @dev The lowest lane index carrying no pending order on `sellToken`. For an occupancy
    ///      with its lowest clear bit at `k`, `occupancy + 1` carries bit `k` up and clears
    ///      everything below it, and `~occupancy` keeps only bits that are clear, so the two
    ///      agree on bit `k` alone — an exact power of two, which `log2` reads back as `k`.
    /// @param sellToken The token the order sells.
    /// @return The lane's index.
    function _lowestFreeLane(address sellToken) internal view returns (uint256) {
        uint256 occupancy = _laneOccupancy[sellToken];
        require(occupancy != type(uint256).max, NoFreeLane(sellToken));

        return Math.log2(~occupancy & (occupancy + 1));
    }

    /// @dev A lane's address, deployed or not. The adapter is the deployer in the CREATE2
    ///      derivation, so no other account can occupy the address, and a lane's index is
    ///      therefore enough to name it. Pure address math over any `index`, so every external
    ///      entry point bounds its own argument by {LANE_COUNT} first; the internal callers
    ///      pass an index from {_lowestFreeLane} or a record, both already within it.
    /// @param index The lane's index.
    /// @return The lane's address.
    function _laneAt(uint256 index) internal view returns (address) {
        return Clones.predictDeterministicAddress(LANE_IMPLEMENTATION, bytes32(index), address(this));
    }

    /// @dev Expands caller-supplied parameters into the full order settlement verifies. The
    ///      fields absent from {OrderParams} are fixed here: `kind` is sell, `receiver` is the
    ///      owner, `feeAmount` is zero, `partiallyFillable` is false, and both balance fields
    ///      are plain ERC-20.
    /// @param params The caller-supplied part of the order.
    /// @return order The order in the form settlement verifies.
    function _buildOrder(OrderParams memory params) internal view returns (GPv2Order.Data memory order) {
        order = GPv2Order.Data({
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            receiver: OWNER,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            validTo: params.validTo,
            appData: params.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    /// @param params The caller-supplied part of the order.
    function _validateOrderParams(OrderParams memory params) internal pure {
        require(params.sellToken != address(0), ZeroSellToken());
        require(params.buyToken != address(0), ZeroBuyToken());
        require(params.sellToken != params.buyToken, IdenticalTokens());
        require(params.sellAmount != 0, ZeroSellAmount());
        require(params.buyAmount != 0, ZeroBuyAmount());
        require(params.validTo != 0, ZeroValidTo());
    }
}
