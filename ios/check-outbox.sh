#!/bin/bash
# Fast outbox-persistence checks on Mac or Linux. UI verification still needs ios/check.sh offline.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc TakesPhone/OutboxStore.swift tests/OutboxStoreTests.swift -o "$TMP/check-outbox"
"$TMP/check-outbox"
