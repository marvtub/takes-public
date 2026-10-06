#!/bin/bash
# Fast scroll-policy checks on Mac or Linux. UI verification still needs ios/check.sh chat.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc TakesPhone/ChatScrollState.swift tests/ChatScrollStateTests.swift -o "$TMP/check-scroll"
"$TMP/check-scroll"
swiftc -frontend -parse TakesPhone/SessionView.swift TakesPhone/CopilotView.swift TakesPhoneUITests/ScreensTests.swift
bash -n check.sh
python3 -m unittest discover -s tests -p 'test_chat_standin.py'
