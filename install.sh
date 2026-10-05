#!/bin/bash
# Installs Takes and what it needs: the app, ffmpeg and Claude Code. One line in Terminal:
#   curl -fsSL https://gettakes.app/install | bash
# Takes is not notarized (no paid Apple developer account). A browser download gets a quarantine
# flag and macOS blocks the app; a download with curl gets no flag, so Takes opens at once.
# Run it again to update. The export copies it to the root of the public repo; the gettakes.app
# deploy serves this file from origin/main at /install (2026-10-05).
set -euo pipefail

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Takes runs on macOS only."
[ "$(uname -m)" = arm64 ] || fail "Takes needs a Mac with Apple silicon (M1 or later)."
v=$(sw_vers -productVersion)
[ "${v%%.*}" -ge 15 ] || fail "Takes needs macOS 15 or later. This Mac has macOS $v."

tmp=$(mktemp -d)
trap 'hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true; rm -rf "$tmp"' EXIT
bin="$HOME/.local/bin"
mkdir -p "$bin"

# 1. The app.
say "Downloading Takes…"
if [ -n "${TAKES_DMG:-}" ]; then cp "$TAKES_DMG" "$tmp/Takes.dmg"  # a local build, for a test
else curl -fL --progress-bar -o "$tmp/Takes.dmg" https://github.com/marvtub/takes-public/releases/latest/download/Takes.dmg; fi
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$tmp/Takes.dmg"
# TAKES_APPS=<dir> installs there for a test and leaves a running Takes alone.
apps=${TAKES_APPS:-/Applications}
[ -w "$apps" ] || { apps="$HOME/Applications"; mkdir -p "$apps"; }
if [ -z "${TAKES_APPS:-}" ] && pgrep -xq Takes; then
    say "Quitting Takes to replace it…"
    osascript -e 'quit app "Takes"' || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Takes || break; sleep 1; done
fi
rm -rf "$apps/Takes.app"
ditto "$tmp/mnt/Takes.app" "$apps/Takes.app"
xattr -dr com.apple.quarantine "$apps/Takes.app" 2>/dev/null || true
echo "Takes is in $apps."

# 2. ffmpeg and ffprobe: static builds from ffmpeg.martin-riedl.de (linked from ffmpeg.org),
# checked against their SHA-256. Skipped when ffmpeg is already there (Homebrew or other).
if command -v ffmpeg >/dev/null || [ -x "$bin/ffmpeg" ] || [ -x /opt/homebrew/bin/ffmpeg ]; then
    echo "ffmpeg is already installed."
else
    say "Downloading ffmpeg…"
    for tool in ffmpeg ffprobe; do
        url=$(curl -fsL -r 0-0 -o /dev/null -w '%{url_effective}' \
            "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/$tool.zip")
        curl -fL --progress-bar -o "$tmp/$tool.zip" "$url"
        want=$(curl -fsSL "$url.sha256" | awk '{print $1}')
        got=$(shasum -a 256 "$tmp/$tool.zip" | awk '{print $1}')
        [ -n "$want" ] && [ "$want" = "$got" ] || fail "The $tool download does not match its checksum. Try again later."
        ditto -x -k "$tmp/$tool.zip" "$tmp/$tool"
        install -m 755 "$tmp/$tool/$tool" "$bin/$tool"
    done
    echo "ffmpeg is in $bin."
fi

# 3. Claude Code, with Anthropic's own installer, then sign in.
claude=$(command -v claude || true)
[ -n "$claude" ] || { [ -x "$bin/claude" ] && claude="$bin/claude"; } || true
if [ -z "$claude" ]; then
    say "Installing Claude Code…"
    curl -fsSL https://claude.ai/install.sh | bash
    claude="$bin/claude"
fi
if "$claude" auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
    echo "Claude Code is signed in."
else
    say "Sign in to Claude Code. Your browser opens; come back here when you are done."
    "$claude" auth login </dev/tty || echo "Sign in later: open Takes and click Finish setup."
fi

case ":$PATH:" in
    *":$bin:"*) ;;
    *) printf '\nTo use claude and ffmpeg in Terminal too, add this line to ~/.zshrc:\n  export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

if [ -n "${TAKES_APPS:-}" ]; then
    say "Done. Takes is in $apps."
else
    say "Done. Opening Takes."
    open "$apps/Takes.app"
fi
