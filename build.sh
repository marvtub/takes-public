#!/bin/bash
# Build Takes.app. `./build.sh install` copies it to ~/Applications and opens it, or, while Takes
# runs, stages it so Takes shows Update in its sidebar (Sources/Takes/Updater.swift).
set -euo pipefail
cd "$(dirname "$0")"
# Several agents build Takes from their own worktrees, and each install replaces the last one
# (2026-10-04: a branch build dropped a feature that was on main). So install only main as it
# is on GitHub: commit, merge origin/main, push HEAD:main, then install. Each install is then
# all of main at that time, and a later one never drops work. `./build.sh` alone builds anything.
if [[ "${1:-}" == "install" && "${ANY_BRANCH:-}" != 1 ]]; then
  git fetch -q origin main
  if ! git diff --quiet HEAD -- Sources mcp assets Package.swift Info.plist build.sh; then
    echo "Not installed: commit your changes first (install builds only what is on main)." >&2; exit 1
  fi
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    if git merge-base --is-ancestor origin/main HEAD; then
      echo "Not installed: push first (git push origin HEAD:main), then install." >&2
    else
      echo "Not installed: origin/main has commits you don't. git merge origin/main, test, push HEAD:main, then install." >&2
    fi
    exit 1
  fi
fi
# Tests first, so a regression never reaches ~/Applications. SKIP_TESTS=1 skips them.
[[ "${SKIP_TESTS:-}" == 1 ]] || ./test.sh --quiet
swift build -c release
# A .noindex folder: Spotlight skips it, so macOS never registers this copy and never opens it
# in place of ~/Applications/Takes.app (old copies kept opening, 2026-10-01).
APP=build.noindex/Takes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Takes "$APP/Contents/MacOS/Takes"
cp mcp/takes_mcp.py "$APP/Contents/Resources/takes_mcp.py"
cp assets/Takes.icns "$APP/Contents/Resources/Takes.icns"
mkdir -p "$APP/Contents/Resources/Fonts" && cp assets/fonts/*.ttf "$APP/Contents/Resources/Fonts/"
mkdir -p "$APP/Contents/Resources/Onboarding" && cp assets/onboarding/creator.jpg "$APP/Contents/Resources/Onboarding/"
mkdir -p "$APP/Contents/Resources/Article"
mkdir -p "$APP/Contents/Resources/Brand" && cp assets/brand/mascot-512.png "$APP/Contents/Resources/Brand/mascot.png" && cp assets/brand/mascot-body-512.png "$APP/Contents/Resources/Brand/mascot-body.png"
cp Info.plist "$APP/Contents/Info.plist"
# The search helper (embed/, ⌘K by meaning). MLX needs Xcode and its Metal toolchain, which
# `swift build` and the Command Line Tools lack. Without them Takes still builds, and ⌘K matches
# file names and transcripts only. The model itself is never in the app: Takes downloads it.
XCODE=/Applications/Xcode.app/Contents/Developer
if [[ -d embed && -d "$XCODE" ]] && DEVELOPER_DIR="$XCODE" xcrun metal --version >/dev/null 2>&1; then
  (cd embed && DEVELOPER_DIR="$XCODE" xcodebuild -quiet -scheme TakesEmbed -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-xcode build > .build-xcode.log 2>&1) \
    || { tail -30 embed/.build-xcode.log; echo "The search helper did not build (embed/.build-xcode.log)." >&2; exit 1; }
  E=embed/.build-xcode/Build/Products/Release
  cp "$E/takes-embed" "$APP/Contents/MacOS/takes-embed"
  for b in "$E"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
  mkdir -p "$APP/Contents/Resources/Licenses/takes-embed" && cp embed/licenses/* "$APP/Contents/Resources/Licenses/takes-embed/"
else
  echo "No Xcode Metal toolchain: Takes builds without search by meaning (xcodebuild -downloadComponent MetalToolchain)."
fi
# Skills for Claude Code that the app installs at launch (the public copy ships them in skills/).
[[ -d skills ]] && cp -R skills "$APP/Contents/Resources/skills"
# The stamp tells a running Takes that a staged build is new; the changes go in the Update tooltip.
INSTALLED="$HOME/Applications/Takes.app"
STAMP="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Sources Package.swift 2>/dev/null || echo +) $(date '+%b %-d %H:%M')"
WAS="$(/usr/libexec/PlistBuddy -c 'Print :BuildStamp' "$INSTALLED/Contents/Info.plist" 2>/dev/null | cut -d' ' -f1 | tr -d +)" || WAS=""
if [[ -n "$WAS" ]] && git cat-file -e "$WAS^{commit}" 2>/dev/null; then
  CHANGES="$(git log -8 --format=%s "$WAS..HEAD")"  # -8, not | head: pipefail stops on git's SIGPIPE
else
  CHANGES="$(git log -1 --format=%s)"
fi
# The same commits in full for the What's new panel: no merges, no co-author lines.
if [[ -n "$WAS" ]] && git cat-file -e "$WAS^{commit}" 2>/dev/null; then RANGE="$WAS..HEAD"; else RANGE="-1"; fi
git log --no-merges -40 --format='%h%x1f%cI%x1f%s%x1f%b%x1e' $RANGE | python3 -c '
import json, sys
out = []
for rec in sys.stdin.read().split("\x1e"):
    f = rec.strip("\n").split("\x1f")
    if len(f) < 4: continue
    body = "\n".join(l for l in f[3].splitlines() if not l.startswith("Co-Authored-By")).strip()
    out.append({"hash": f[0], "date": f[1], "subject": f[2], "body": body})
json.dump(out, sys.stdout, ensure_ascii=False)' > "$APP/Contents/Resources/changes.json"
plutil -insert BuildStamp -string "$STAMP" "$APP/Contents/Info.plist"
# The version comes from git: the newest commit's date and the commit count (scripts/version.sh).
read -r VERSION BUILD <<< "$(scripts/version.sh)"
if [[ -n "${BUILD:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
fi
plutil -insert BuildChanges -string "$CHANGES" "$APP/Contents/Info.plist"
# The repo Takes > Release to GitHub releases from (only where the release script exists).
if [[ -x scripts/public/release.sh ]]; then
  plutil -insert ReleaseRepo -string "$(git worktree list --porcelain | sed -n 1p | cut -d' ' -f2-)" "$APP/Contents/Info.plist"
fi
# A stable certificate keeps camera, mic and screen permissions across installs (scripts/setup-signing.sh).
# Without it, fall back to ad-hoc signing, and macOS asks for the permissions again after each install.
KC="$HOME/Library/Keychains/takes-signing.keychain-db"
if [[ -f "$KC" && -f "$HOME/.config/takes/keychain-pass" ]]; then
  security unlock-keychain -p "$(cat "$HOME/.config/takes/keychain-pass")" "$KC"
  [[ -f "$APP/Contents/MacOS/takes-embed" ]] && codesign --force --sign "Takes Local Signing" --keychain "$KC" --identifier de.marvinaziz.takes.embed "$APP/Contents/MacOS/takes-embed"
  codesign --force --sign "Takes Local Signing" --keychain "$KC" --identifier de.marvinaziz.takes "$APP"
else
  echo "No signing certificate: run scripts/setup-signing.sh once to keep permissions across installs."
  [[ -f "$APP/Contents/MacOS/takes-embed" ]] && codesign --force --sign - --identifier de.marvinaziz.takes.embed "$APP/Contents/MacOS/takes-embed"
  codesign --force --sign - --identifier de.marvinaziz.takes "$APP"
fi
echo "Built $APP"
if [[ "${1:-}" == "install" ]]; then
  # Once Takes is installed, always stage: never decide by "is it running?". That check failed
  # silently twice (pgrep sees nothing from agent shells; pipefail broke ps | grep -q) and the
  # install overwrote the running app with no Update row (2026-10-06). A staged build waits for
  # the Update click whether Takes is open now or opens later. FRESH_INSTALL=1 copies directly.
  if [[ -d ~/Applications/Takes.app && "${FRESH_INSTALL:-}" != 1 ]]; then
    # Never quit Takes for the user: stage the build, and Takes shows Update in its sidebar.
    # Copy beside the slot, then rename, so Takes never reads a half-copied build.
    STAGE="$HOME/Applications/.update.noindex"
    # A slower agent's older main must not replace a newer staged build.
    STAGED="$(/usr/libexec/PlistBuddy -c 'Print :BuildStamp' "$STAGE/Takes.app/Contents/Info.plist" 2>/dev/null | cut -d' ' -f1 | tr -d +)" || STAGED=""
    if [[ -n "$STAGED" && "${ANY_BRANCH:-}" != 1 ]] && git cat-file -e "$STAGED^{commit}" 2>/dev/null \
       && ! git merge-base --is-ancestor "$STAGED" HEAD; then
      echo "Not staged: the staged build ($STAGED) has commits this one doesn't. git merge origin/main, push, then install." >&2; exit 1
    fi
    mkdir -p "$STAGE"
    rm -rf "$STAGE/incoming.app"
    cp -R "$APP" "$STAGE/incoming.app"
    rm -rf "$STAGE/Takes.app"
    mv "$STAGE/incoming.app" "$STAGE/Takes.app"
    echo "Staged $STAMP: Takes shows Update in its sidebar; the user clicks it when he's ready."
    exit 0
  fi
  mkdir -p ~/Applications
  rm -rf ~/Applications/Takes.app ~/Applications/.update.noindex/Takes.app
  cp -R "$APP" ~/Applications/Takes.app
  open -g ~/Applications/Takes.app
  echo "Installed ~/Applications/Takes.app"
  # MCP server for Claude Code, pointing at the installed copy (stable path).
  if command -v claude >/dev/null && ! claude mcp get takes >/dev/null 2>&1; then
    claude mcp add takes --scope user -- /usr/bin/python3 "$HOME/Applications/Takes.app/Contents/Resources/takes_mcp.py"
  fi
fi
