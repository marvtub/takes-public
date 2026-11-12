#!/bin/bash
# Fast iPhone logic checks on Mac or Linux. UI verification still needs ios/check.sh chat.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc TakesPhone/ChatScrollState.swift tests/ChatScrollStateTests.swift -o "$TMP/check-scroll"
"$TMP/check-scroll"
swiftc TakesPhone/APIContract.swift tests/APIContractTests.swift -o "$TMP/check-api"
"$TMP/check-api"
swiftc TakesPhone/ChatUploadState.swift tests/ChatUploadStateTests.swift -o "$TMP/check-uploads"
"$TMP/check-uploads"
swiftc TakesPhone/PastChatDeletionState.swift tests/PastChatDeletionStateTests.swift -o "$TMP/check-past-chat-deletion"
"$TMP/check-past-chat-deletion"
swiftc TakesPhone/SessionSearchState.swift tests/SessionSearchStateTests.swift -o "$TMP/check-session-search"
"$TMP/check-session-search"
swiftc TakesPhoneUITests/ScreenshotArtifacts.swift tests/ScreenshotArtifactsTests.swift -o "$TMP/check-screenshot-artifacts"
"$TMP/check-screenshot-artifacts"
if [[ -f TakesPhone/Private/MuseDraft.swift ]]; then
    swiftc TakesPhone/Private/MuseDraft.swift tests/MuseDraftTests.swift -o "$TMP/check-muse-draft"
    "$TMP/check-muse-draft"
fi
swiftc TakesPhone/PlaceEffectTiming.swift tests/PlaceEffectTimingTests.swift -o "$TMP/check-place-effect-timing"
"$TMP/check-place-effect-timing"
swiftc TakesPhone/KeychainReplacement.swift tests/KeychainReplacementTests.swift -o "$TMP/check-keychain"
"$TMP/check-keychain"
swiftc TakesPhone/SearchState.swift tests/SearchStateTests.swift -o "$TMP/check-search"
"$TMP/check-search"
swiftc TakesPhone/VoicePolling.swift tests/VoicePollingTests.swift -o "$TMP/check-voice-polling"
"$TMP/check-voice-polling"
swiftc TakesPhone/LatestRefresh.swift tests/LatestRefreshTests.swift -o "$TMP/check-latest-refresh"
"$TMP/check-latest-refresh"
swiftc -frontend -parse TakesPhone/SessionView.swift TakesPhone/CopilotView.swift TakesPhoneUITests/ScreensTests.swift
bash -n check.sh
python3 -m unittest discover -s tests -p 'test_chat_standin.py'
