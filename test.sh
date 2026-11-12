#!/bin/bash
# Run every test: the MCP server (Python), the app and the search helper. Extra arguments go to swift test.
# With only the Command Line Tools (no Xcode), swift test cannot find the Testing framework on its own,
# so point it there.
set -euo pipefail
cd "$(dirname "$0")"
# Only a --filter or --skip picks the tests; other flags (build.sh passes --quiet) keep the full run.
FULL=1
[[ " $* " == *" --filter "* || " $* " == *" --skip "* ]] && FULL=""
# A full run waits its turn: one at a time on this Mac (scripts/test-queue.sh).
source scripts/test-queue.sh
env -u TAKES_QUEUE_HELD bash scripts/test-queue-tests.sh
if [[ -n "$FULL" ]]; then queue_wait; took "waiting for the test queue"; fi
# Its own temp folder, removed when the run ends (2026-10-11). The MCP tests make folders with
# mkdtemp and leave them: 88,000 piled up in a week, some with copies of whole libraries.
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/takes-test.XXXXXX")"
takes_on_exit "$RUN_TMP"
export TMPDIR="$RUN_TMP/"
if [[ -x scripts/public/test-release-media.sh ]]; then scripts/public/test-release-media.sh; fi
ios/check-outbox.sh
# The tree this run tests, to remember when it passes. Only the private repo: the public copy has no git.
TREE=""
if [[ -n "$FULL" && -f scripts/public/check-public-build.sh ]]; then TREE="$(tree_now)"; fi
# Without the Claude chat id: a suite started inside a Claude session must not write seen-rules files
# (2026-10-10). Tests that need an id set it themselves.
# In parallel processes: one by one they took 280 s (mcp/tests/run_parallel.py).
"${LOW[@]}" env -u CLAUDE_CODE_SESSION_ID python3 mcp/tests/run_parallel.py || { echo "MCP tests failed"; exit 1; }
took "MCP tests (Python)"
# The search helper is its own Swift package, so the app's `swift test` does not see these tests.
XCODE=/Applications/Xcode.app/Contents/Developer
if [[ -d "$XCODE" ]]; then
  (cd embed && DEVELOPER_DIR="$XCODE" "${LOW[@]}" swift test --filter TakesEmbedCLITests)
else
  (cd embed && "${LOW[@]}" swift test --filter TakesEmbedCLITests)
fi
took "search helper CLI tests (Swift)"
if [[ -x scripts/public/tests/media-phone.sh ]]; then scripts/public/tests/media-phone.sh; fi
# The search helper needs Xcode's Metal toolchain, so its package tests run only on Macs that can
# build the helper. They stay in the full gate; a filtered app test should remain quick.
if [[ -n "$FULL" && -d embed && -d "$XCODE" ]] && DEVELOPER_DIR="$XCODE" xcrun metal --version >/dev/null 2>&1; then
  (cd embed && DEVELOPER_DIR="$XCODE" "${LOW[@]}" ../ios/xcodebuild.sh -quiet -scheme TakesEmbed -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-xcode test > .build-xcode.log 2>&1) \
    || { tail -30 embed/.build-xcode.log; echo "Search helper tests failed (embed/.build-xcode.log)." >&2; exit 1; }
  took "search helper tests"
elif [[ -n "$FULL" ]]; then
  echo "No Xcode Metal toolchain: search helper tests skipped."
fi
DEV=/Library/Developer/CommandLineTools/Library/Developer
# PRIO: LOW for the build and the parallel tests, nothing for the timed tests.
PRIO=("${LOW[@]}")
run() {
  if [[ -d "$DEV/Frameworks/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
    "${PRIO[@]}" swift test -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
      -Xlinker -F -Xlinker "$DEV/Frameworks" \
      -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
  else
    "${PRIO[@]}" swift test "$@"
  fi
}
# Tests that time real playback, web views or streamed output. Beside 250 parallel tests the Mac is
# too busy for their timing, and they failed the public release (2026-10-06) though each passes
# alone. A full run leaves them out, then runs them by themselves, one at a time. The fake Codex and
# pi chats and two chat-queue tests joined them (2026-10-18): they failed three releases in a row.
TIMED='aSteerShowsNoErrorAndGoesOn|theNextArticleUsesALoadedPage|theHiddenDockedChatSkipsStreamedWords|resetWhileRunningKeepsTheNewAsk|watcherSeesAWrite|aCodexConversationStartsAThreadAndResumesIt|aPiConversationKeepsItsIDAndTellsTheTakesServer|compactQueuesAloneAndRunsFirst|boardActionsShowAndReachTheAgentOnce|stopEndsARunAndDropsTheQueue|queuedFreshRunStillStartsNew|stopDropsAFreshAsk|aSteerKeepsTheConversationOfAFreshAsk|aSaveRedrawsTheModFast|aClonedSidebarRedrawsFast|aLayoutSaveReloadsWithoutABuild|checkerRequestsRealDataWithNoSectionMods|typingArrowsAndReturnPickTheHighlightedModel'
if [[ -z "$FULL" ]]; then
  run "$@"
else
  run --skip "$TIMED" "$@"
  took "app build and tests (Swift)"
  echo "Timed tests, one at a time..."
  PRIO=(env)
  run --filter "$TIMED" --no-parallel "$@"
  took "timed tests"
  # embed/ is its own package. MLX needs Xcode's Metal toolchain, just as its build in build.sh does.
  XCODE=/Applications/Xcode.app/Contents/Developer
  if [[ -d embed && -d "$XCODE" ]] && DEVELOPER_DIR="$XCODE" xcrun metal --version >/dev/null 2>&1; then
    echo "Search helper tests..."
    (cd embed && DEVELOPER_DIR="$XCODE" "${LOW[@]}" ../ios/xcodebuild.sh -quiet -scheme TakesEmbed \
      -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-xcode test)
    took "search helper tests (Swift)"
  else
    echo "No Xcode Metal toolchain: search helper tests cannot run on this Mac."
  fi
  # A full run also builds and tests the public copy (2026-10-08): code that uses a private
  # plugin passes here and fails there. Only the private repo has the script.
  if [[ -f scripts/public/check-public-build.sh && "${TAKES_SKIP_PUBLIC:-}" != 1 ]]; then
    echo "The public copy..."
    scripts/public/check-public-build.sh
    took "the public copy"
    # Every check passed on this tree: build.sh install does not run them again.
    if [[ -n "$TREE" ]]; then passed_mark "$TREE"; fi
  fi
fi
