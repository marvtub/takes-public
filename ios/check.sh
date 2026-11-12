#!/bin/bash
# Builds the iPhone app and walks its screens in a hidden simulator against a server (default: a
# stand-in on 127.0.0.1:8797, started here when none answers). Screenshots go to $SHOTS. Never
# opens Simulator.app. Each test resets the stand-in, so the whole suite can share one.
# check.sh offline: starts standin.py and runs the offline test (changes wait, then go out).
# check.sh chat: starts standin.py and tests streaming, keyboard and reading-position changes.
# check.sh parity [Class or Class/test]: starts standin.py and walks the screens that copy the Mac (ParityTests).
# REAL_MAC with SERVER explicitly skips the fixture reset for a run against a real Mac.
set -euo pipefail
cd "$(dirname "$0")"
./check-scroll.sh
./check-outbox.sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SHOTS="${SHOTS:-$PWD/build.noindex/shots}"
mkdir -p "$PWD/build.noindex" "$SHOTS"
swiftc TakesPhone/KeychainReplacement.swift tests/KeychainReplacementTests.swift -o "$PWD/build.noindex/check-keychain"
"$PWD/build.noindex/check-keychain"
mkdir -p "$SHOTS"
# The public copy omits the private article source and does not need this check.
if [[ -f TakesPhone/Private/ArticleSchemeRequests.swift ]]; then
  (
    ARTICLE_CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/takes-article-check.XXXXXX")
    trap 'rm -rf "$ARTICLE_CHECK_TMP"' EXIT
    swiftc TakesPhone/Private/ArticleSchemeRequests.swift tests/ArticleSchemeRequestsTests.swift \
      -o "$ARTICLE_CHECK_TMP/article-scheme-requests"
    "$ARTICLE_CHECK_TMP/article-scheme-requests"
  )
fi
xcodegen generate -q
ONLY=()
standin() {
  python3 standin.py "$1" >"$SHOTS/standin.log" 2>&1 &
  STANDIN=$!
  trap 'kill $STANDIN 2>/dev/null' EXIT
  sleep 1
  SERVER="http://127.0.0.1:$1"
}
if [[ "${1:-}" == "offline" || "${1:-}" == "chat" || "${1:-}" == "parity" ]]; then
  standin "${PORT:-8798}"
  if [[ "$1" == "chat" ]]; then
    ONLY=(-only-testing:TakesPhoneUITests/ScreensTests/testChatStaysPut)
  elif [[ "$1" == "parity" ]]; then
    ONLY=(-only-testing:TakesPhoneUITests/${2:-ParityTests})
  else
    ONLY=(-only-testing:TakesPhoneUITests/OfflineTests${2:+/$2})
  fi
elif [[ -z "${SERVER:-}" ]] && ! curl -s -m 2 http://127.0.0.1:8797/api/ping >/dev/null; then
  standin 8797
fi
# The simulator has no camera: a test clip stands in for the take (testRecordReview).
FAKE="$PWD/build.noindex/fake-take.mov"
[[ -f "$FAKE" ]] || ffmpeg -loglevel error -f lavfi -i testsrc2=size=1080x1920:rate=30 -t 3 -pix_fmt yuv420p "$FAKE"
# The orientation unit test needs both tracks so it can fail after a partial insertion.
ORIENTATION_FAKE="$PWD/build.noindex/orientation-take.mov"
[[ -f "$ORIENTATION_FAKE" ]] || ffmpeg -loglevel error \
  -f lavfi -i testsrc2=size=64x96:rate=5 -f lavfi -i sine=frequency=1000:sample_rate=8000 \
  -t 1 -pix_fmt yuv420p -c:a aac "$ORIENTATION_FAKE"
TEST_RUNNER_TAKES_FAKE_TAKE="$FAKE" TEST_RUNNER_TAKES_ORIENTATION_TAKE="$ORIENTATION_FAKE" \
  TEST_RUNNER_TAKES_SHOTS="$SHOTS" TEST_RUNNER_TAKES_SERVER="${SERVER:-http://127.0.0.1:8797}" \
  TEST_RUNNER_TAKES_REAL_MAC="${REAL_MAC:-0}" \
  ./xcodebuild.sh -project TakesPhone.xcodeproj -scheme TakesPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build.noindex CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ${ONLY[@]+"${ONLY[@]}"} -test-timeouts-enabled YES -maximum-test-execution-time-allowance 400 test -quiet
echo "Screens in $SHOTS"
