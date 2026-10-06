#!/bin/bash
# Run every test: the MCP server (Python) and the app (Swift Testing). Extra arguments go to swift test.
# With only the Command Line Tools (no Xcode), swift test cannot find the Testing framework on its own,
# so point it there.
set -euo pipefail
cd "$(dirname "$0")"
python3 -m unittest discover -q -s mcp/tests || { echo "MCP tests failed"; exit 1; }
DEV=/Library/Developer/CommandLineTools/Library/Developer
run() {
  if [[ -d "$DEV/Frameworks/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
    swift test -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
      -Xlinker -F -Xlinker "$DEV/Frameworks" \
      -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
  else
    swift test "$@"
  fi
}
# Tests that time real playback, web views or streamed output. Beside 250 parallel tests the Mac is
# too busy for their timing, and they failed the public release (2026-10-06) though each passes
# alone. A full run leaves them out, then runs them by themselves, one at a time.
TIMED='theNextArticleUsesALoadedPage|theHiddenDockedChatSkipsStreamedWords|effectPlaysAtItsSecond|resetWhileRunningKeepsTheNewAsk|watcherSeesAWrite'
if [[ $# -gt 0 ]]; then
  run "$@"
else
  run --skip "$TIMED"
  echo "Timed tests, one at a time..."
  run --filter "$TIMED" --no-parallel
fi
