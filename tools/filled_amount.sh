#!/usr/bin/env bash
#
# Read GPv2Settlement's fill record for CoW Protocol orders.
#
#   tools/filled_amount.sh 0x<uid> [0x<uid> ...]   check specific orders
#   cat uids.txt | tools/filled_amount.sh          read uids from stdin, one per line
#   tools/filled_amount.sh --stdin                 the same, forced
#   tools/filled_amount.sh --scan <block>          sample orders that filled from that block on
#
# Options:
#   --rpc <alias|url>    RPC to use, resolved via foundry.toml (default: ethereum)
#   --settlement <addr>  settlement contract (default: the mainnet deployment)
#   --span <n>           --scan: block range width (default: 300)
#   --limit <n>          --scan: maximum orders to sample (default: 25)
#
# STATUS reflects that `filledAmount` is a lossy record. Settlement stores three
# distinguishable values in one slot — untouched, the filled amount, and a
# cancellation marker — but any solver may zero the slot once `validTo` has passed,
# via `freeFilledAmountStorage`. So a zero read is only meaningful while the order is
# still valid:
#
#   FILLED     the order was filled, for AMOUNT
#   CANCELLED  invalidateOrder was called against it
#   OPEN       not yet filled or cancelled, and still valid
#   UNKNOWN    expired reading zero: never filled, or filled and since cleared
#
set -euo pipefail

SETTLEMENT=0x9008D19f58AAbD9eD0D60971565AA8510560ab41
RPC=ethereum
SPAN=300
LIMIT=25
CANCELLED=115792089237316195423570985008687907853269984665640564039457584007913129639935

TRADE_EVENT='Trade(address,address,address,uint256,uint256,uint256,bytes)'
# Offset of the orderUid within a Trade event's data: six 32-byte words of fixed
# fields and the array length, times 64 hex characters, plus 2 for the "0x".
UID_OFFSET=450
UID_CHARS=112

die() {
  echo "filled_amount: $*" >&2
  exit 1
}

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
  exit "${1:-0}"
}

# Human-readable UTC timestamp, from either BSD or GNU date.
format_time() {
  date -u -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null \
    || date -u -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null \
    || echo "$1"
}

# Collect uids of orders that filled in a block range, newest-last, capped at LIMIT.
scan_uids() {
  cast logs --rpc-url "$RPC" --address "$SETTLEMENT" "$TRADE_EVENT" \
    --from-block "$1" --to-block "$(($1 + SPAN))" --json \
    | jq -r --argjson n "$LIMIT" --argjson o "$UID_OFFSET" --argjson c "$UID_CHARS" \
        '.[0:$n] | .[].data | "0x" + .[$o:$o + $c]'
}

# Printed before the first row, so a run that produces nothing stays quiet.
header() {
  if [ "$headed" -eq 0 ]; then
    printf '%-14s %-10s %-16s %s\n' UID STATUS "VALID TO (UTC)" AMOUNT
    headed=1
  fi
}

# A malformed uid is reported and skipped rather than fatal, so one bad line does
# not discard the rest of a list. The exit status still reflects it.
report() {
  local uid=$1 now=$2 amount validTo status

  uid=${uid#0x}
  if [ ${#uid} -ne $UID_CHARS ]; then
    echo "filled_amount: not a 56-byte order uid, skipping: 0x$uid" >&2
    return 1
  fi

  # The uid is digest(32) ++ owner(20) ++ validTo(4); validTo is the trailing word.
  validTo=$(printf '%d' "0x${uid: -8}")
  amount=$(cast call --rpc-url "$RPC" "$SETTLEMENT" \
    "filledAmount(bytes)(uint256)" "0x$uid" | awk '{print $1}')

  if [ "$amount" = "$CANCELLED" ]; then
    status=CANCELLED
    amount=-
  elif [ "$amount" != "0" ]; then
    status=FILLED
  elif [ "$validTo" -ge "$now" ]; then
    status=OPEN
    amount=-
  else
    status=UNKNOWN
    amount=-
  fi

  header
  printf '%-14s %-10s %-16s %s\n' "0x${uid:0:12}" "$status" "$(format_time "$validTo")" "$amount"
}

uids=""
mode=args

while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage ;;
    --stdin) mode=stdin; shift ;;
    --scan) mode=scan; scan_from=${2:?--scan needs a block number}; shift 2 ;;
    --rpc) RPC=${2:?--rpc needs a value}; shift 2 ;;
    --settlement) SETTLEMENT=${2:?--settlement needs a value}; shift 2 ;;
    --span) SPAN=${2:?--span needs a value}; shift 2 ;;
    --limit) LIMIT=${2:?--limit needs a value}; shift 2 ;;
    -*) die "unknown option $1 (--help for usage)" ;;
    *) uids="$uids $1"; shift ;;
  esac
done

command -v cast >/dev/null || die "cast not found — install Foundry"
command -v jq >/dev/null || die "jq not found"

# A pipe with no uid arguments is read as stdin, so `--stdin` is only needed to
# force it. With nothing piped and nothing to do, show the usage instead.
if [ "$mode" = args ] && [ -z "${uids// /}" ]; then
  if [ -t 0 ]; then usage 1; else mode=stdin; fi
fi

if [ "$mode" = scan ]; then
  uids=$(scan_uids "$scan_from")
fi

headed=0
seen=0
failed=0
now=""

# Head timestamp, fetched once and only if there is something to report on — it
# decides OPEN from UNKNOWN, and a run with no input should not touch the network.
check() {
  if [ -z "$now" ]; then
    now=$(cast block latest --rpc-url "$RPC" --field timestamp)
  fi
  seen=$((seen + 1))
  if report "$1" "$now"; then :; else failed=$((failed + 1)); fi
}

if [ "$mode" = stdin ]; then
  if [ -t 0 ]; then
    echo "filled_amount: reading uids from stdin, one per line — Ctrl-D to finish" >&2
  fi
  # Read line by line rather than slurping, so a uid typed at a prompt is answered
  # on Enter instead of waiting for end-of-input. Trailing \r from CRLF input and
  # surrounding whitespace are stripped; blank lines are ignored.
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    check "$line"
  done
else
  for uid in $uids; do
    check "$uid"
  done
fi

[ "$seen" -gt 0 ] || die "no order uids given (--help for usage)"
[ "$failed" -eq 0 ] || exit 1
