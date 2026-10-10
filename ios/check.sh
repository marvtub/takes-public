#!/bin/bash
# Builds the iPhone app and walks its screens in a hidden simulator against a server (default: a
# stand-in on 127.0.0.1:8797). Screenshots go to $SHOTS. Never opens Simulator.app.
# check.sh offline: starts standin.py and runs the offline test (changes wait, then go out).
# check.sh chat: starts standin.py and tests streaming, keyboard and reading-position changes.
# check.sh parity [Class or Class/test]: starts standin.py and walks the screens that copy the Mac (ParityTests).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SHOTS="${SHOTS:-$PWD/build.noindex/shots}"
mkdir -p "$SHOTS"
xcodegen generate -q
ONLY=()
if [[ "${1:-}" == "offline" || "${1:-}" == "chat" || "${1:-}" == "parity" ]]; then
  PORT=8798
  python3 standin.py $PORT >"$SHOTS/standin.log" 2>&1 &
  STANDIN=$!
  trap 'kill $STANDIN 2>/dev/null' EXIT
  sleep 1
  SERVER="http://127.0.0.1:$PORT"
  if [[ "$1" == "chat" ]]; then
    ONLY=(-only-testing:TakesPhoneUITests/ScreensTests/testChatStaysPut)
  elif [[ "$1" == "parity" ]]; then
    ONLY=(-only-testing:TakesPhoneUITests/${2:-ParityTests})
  else
    ONLY=(-only-testing:TakesPhoneUITests/OfflineTests${2:+/$2})
  fi
fi
TEST_RUNNER_TAKES_SHOTS="$SHOTS" TEST_RUNNER_TAKES_SERVER="${SERVER:-http://127.0.0.1:8797}" \
  xcodebuild -project TakesPhone.xcodeproj -scheme TakesPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build.noindex CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ${ONLY[@]+"${ONLY[@]}"} -test-timeouts-enabled YES -maximum-test-execution-time-allowance 400 test -quiet
echo "Screens in $SHOTS"
