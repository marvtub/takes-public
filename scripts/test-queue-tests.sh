#!/bin/bash
# The queue publishes a complete ticket before another waiter can inspect it.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/takes-queue-test.XXXXXX")"
CACHE="$ROOT/cache"
STATE="$ROOT/state"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/test-queue.sh"
mkdir -p "$CACHE" "$STATE"
A_PID=""
B_PID=""
cleanup() {
  [[ -n "$A_PID" ]] && kill "$A_PID" 2>/dev/null || true
  [[ -n "$B_PID" ]] && kill "$B_PID" 2>/dev/null || true
  [[ -n "$A_PID" ]] && wait "$A_PID" 2>/dev/null || true
  [[ -n "$B_PID" ]] && wait "$B_PID" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

wait_for() {
  local description="$1" attempt=0
  shift
  while ! "$@"; do
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 200 ]]; then
      echo "Queue test timed out: $description" >&2
      return 1
    fi
    sleep 0.01
  done
}

two_tickets() {
  local count=0 ticket
  for ticket in "$CACHE/takes-test-queue"/*; do
    [[ -f "$ticket" ]] && count=$((count + 1))
  done
  [[ "$count" -eq 2 ]]
}

# Pause the first waiter after its ticket file is opened but before printf writes the PID.
# A second waiter must never see that incomplete ticket.
bash -c '
  set -euo pipefail
  source "$1"
  TAKES_CACHE="$2"
  STATE_PATH="$3"
  printf() {
    if [[ "$1" == "%s\\n%s at %s\\n" ]]; then
      touch "$STATE_PATH/a-ready"
      while [[ ! -e "$STATE_PATH/a-publish" ]]; do command sleep 0.01; done
    fi
    builtin printf "$@"
  }
  sleep() {
    touch "$STATE_PATH/a-waiting"
    command sleep 0.01
  }
  queue_wait
  touch "$STATE_PATH/a-acquired"
  while [[ ! -e "$STATE_PATH/a-release" ]]; do command sleep 0.01; done
' bash "$SCRIPT" "$CACHE" "$STATE" 2>"$STATE/a.err" &
A_PID=$!

wait_for "the first ticket write to pause" test -e "$STATE/a-ready"

bash -c '
  set -euo pipefail
  source "$1"
  TAKES_CACHE="$2"
  STATE_PATH="$3"
  sleep() { command sleep 0.01; }
  queue_wait
  touch "$STATE_PATH/b-acquired"
  while [[ ! -e "$STATE_PATH/b-release" ]]; do command sleep 0.01; done
' bash "$SCRIPT" "$CACHE" "$STATE" 2>"$STATE/b.err" &
B_PID=$!

wait_for "the second waiter to acquire the queue" test -e "$STATE/b-acquired"
touch "$STATE/a-publish"
wait_for "both complete tickets to become visible" two_tickets
wait_for "the first waiter to wait behind the published ticket" test -e "$STATE/a-waiting"
[[ ! -e "$STATE/a-acquired" ]]

touch "$STATE/b-release"
wait_for "the first waiter to acquire the released queue" test -e "$STATE/a-acquired"
touch "$STATE/a-release"
wait "$B_PID"
B_PID=""
wait "$A_PID"
A_PID=""

# Losing a published ticket must stop the waiter instead of leaving it in the polling loop.
bash -c '
  set -euo pipefail
  source "$1"
  TAKES_CACHE="$2"
  queue_wait
  touch "$3/holder-acquired"
  while [[ ! -e "$3/holder-release" ]]; do command sleep 0.01; done
' bash "$SCRIPT" "$CACHE" "$STATE" 2>"$STATE/holder.err" &
B_PID=$!
wait_for "the holder to acquire the queue" test -e "$STATE/holder-acquired"

bash -c '
  set -euo pipefail
  source "$1"
  TAKES_CACHE="$2"
  STATE_PATH="$3"
  sleep() {
    touch "$STATE_PATH/victim-waiting"
    command sleep 0.01
  }
  if queue_wait; then
    exit 1
  fi
  touch "$STATE_PATH/victim-failed"
' bash "$SCRIPT" "$CACHE" "$STATE" 2>"$STATE/victim.err" &
A_PID=$!
wait_for "the second waiter to enter the polling loop" test -e "$STATE/victim-waiting"

VICTIM_TICKET=""
for ticket in "$CACHE/takes-test-queue"/*; do
  if [[ "$(head -1 "$ticket" 2>/dev/null || true)" == "$A_PID" ]]; then
    VICTIM_TICKET="$ticket"
    break
  fi
done
[[ -n "$VICTIM_TICKET" ]]
rm -f "$VICTIM_TICKET"
wait_for "the waiter with a missing ticket to fail" test -e "$STATE/victim-failed"
grep -q "ticket disappeared" "$STATE/victim.err"

touch "$STATE/holder-release"
wait "$A_PID"
A_PID=""
wait "$B_PID"
B_PID=""
