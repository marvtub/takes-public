#!/bin/bash
# Installs Takes and what it needs: the app, ffmpeg, Apple's developer tools and an agent (Claude Code,
# Codex or pi; Claude Code is installed only when none is there). One line in Terminal:
#   curl -fsSL https://gettakes.app/install | bash
# Takes is not notarized (no paid Apple developer account). A browser download gets a quarantine
# flag and macOS blocks the app; a download with curl gets no flag, so Takes opens at once.
# Run it again to update. The export copies it to the root of the public repo; the gettakes.app
# deploy serves this file from origin/main at /install (2026-10-05).
set -euo pipefail

# The command from a link with a source (curl -fsSL https://gettakes.app/install/<ref> | bash) gets
# a random install code on this line (gettakes.app functions/lib/ref.js, 2026-10-20). Takes sends it
# once, with its first update check, so the site can count installs per link. Nothing else.
TAKES_INSTALL_TOKEN=""

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
say "[1/4] Downloading Takes…"
if [ -n "${TAKES_DMG:-}" ]; then cp "$TAKES_DMG" "$tmp/Takes.dmg"  # a local build, for a test
else curl -fL --progress-bar -o "$tmp/Takes.dmg" https://github.com/marvtub/takes-public/releases/latest/download/Takes.dmg; fi
# -noverify: the full check of the image took 3-4 s; TLS already guards the download (2026-10-12).
hdiutil attach -quiet -nobrowse -readonly -noverify -mountpoint "$tmp/mnt" "$tmp/Takes.dmg"
# TAKES_APPS=<dir> installs there for a test and leaves a running Takes alone.
apps=${TAKES_APPS:-/Applications}
[ -w "$apps" ] || { apps="$HOME/Applications"; mkdir -p "$apps"; }
if [ -z "${TAKES_APPS:-}" ] && pgrep -xq -U "$(id -u)" Takes; then
    say "Quitting Takes to replace it…"
    osascript -e 'quit app "Takes"' || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq -U "$(id -u)" Takes || break; sleep 1; done
fi
rm -rf "$apps/Takes.app"
ditto "$tmp/mnt/Takes.app" "$apps/Takes.app"
xattr -dr com.apple.quarantine "$apps/Takes.app" 2>/dev/null || true
echo "Takes is in $apps."
if [[ $TAKES_INSTALL_TOKEN =~ ^[a-km-np-z2-9]{10}$ ]]; then
    support="$HOME/Library/Application Support/Takes"
    mkdir -p "$support" && printf '%s\n' "$TAKES_INSTALL_TOKEN" > "$support/install-ref" || true
fi

# 2. ffmpeg and ffprobe: static builds from ffmpeg.martin-riedl.de (linked from ffmpeg.org),
# checked against their SHA-256. Skipped when ffmpeg is already there (Homebrew or other).
if command -v ffmpeg >/dev/null || [ -x "$bin/ffmpeg" ] || [ -x /opt/homebrew/bin/ffmpeg ]; then
    echo "[2/4] ffmpeg is already installed."
else
    say "[2/4] Downloading ffmpeg (about 57 MB)…"
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

# 3. Apple's developer tools: the takes MCP server, which links Takes to your agents, runs on
# their Python. Apple's dialog installs them in a few minutes; Takes connects the agents after.
if xcode-select -p >/dev/null 2>&1; then
    echo "[3/4] Apple's developer tools are installed."
else
    say "[3/4] Installing Apple's developer tools. Click Install in Apple's dialog; it goes on in the background."
    xcode-select --install 2>/dev/null || echo "Install them later: open Takes and click Finish setup."
fi

# 4. An agent: Claude Code, Codex or pi. One signed-in agent is enough. Claude Code comes, with
# Anthropic's own installer, only when the Mac has none of them (2026-10-12).
agent() { command -v "$1" 2>/dev/null || { [ -x "$bin/$1" ] && echo "$bin/$1"; } || true; }
signed_in() {  # $1: name, $2: path
    case "$1" in
        claude) "$2" auth status 2>/dev/null | grep -q '"loggedIn": *true' ;;
        codex) "$2" login status 2>&1 | grep -qi '^logged in' ;;
        pi) d=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
            /usr/bin/python3 -c 'import json,sys; d=sys.argv[1]
def o(n):
    try: return json.load(open(d+"/"+n))
    except Exception: return {}
sys.exit(0 if len(o("auth.json")) + len(o("models.json").get("providers", {})) else 1)' "$d" 2>/dev/null ;;
    esac
}
name() { case "$1" in claude) echo "Claude Code" ;; codex) echo Codex ;; pi) echo pi ;; esac; }
here=() ready=""
for a in claude codex pi; do
    p=$(agent "$a")
    [ -n "$p" ] || continue
    here+=("$a")
    [ -z "$ready" ] && signed_in "$a" "$p" && ready=$a
done
if [ -n "$ready" ]; then
    echo "[4/4] $(name "$ready") is installed and signed in."
elif [ ${#here[@]} -gt 0 ]; then
    first=${here[0]}; p=$(agent "$first")
    echo "[4/4] $(name "$first") is installed."
    case "$first" in
        claude) say "Sign in to Claude Code. Your browser opens; come back here when you are done."
                "$p" auth login </dev/tty || echo "Sign in later: open Takes and click Finish setup." ;;
        codex) say "Sign in to Codex. Your browser opens; come back here when you are done."
               "$p" login </dev/tty || echo "Sign in later: open Takes and click Finish setup." ;;
        pi) say "Sign in to a model provider for pi: run pi in Terminal and type /login. Takes finds it after." ;;
    esac
else
    say "[4/4] No agent found. Installing Claude Code (about 240 MB, 20-60 s)…"
    curl -fsSL https://claude.ai/install.sh | bash
    claude="$bin/claude"
    say "Sign in to Claude Code. Your browser opens; come back here when you are done."
    "$claude" auth login </dev/tty || echo "Sign in later: open Takes and click Finish setup."
fi

case ":$PATH:" in
    *":$bin:"*) ;;
    *) printf '\nTo use ffmpeg and your agent in Terminal too, add this line to ~/.zshrc:\n  export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

if [ -n "${TAKES_APPS:-}" ]; then
    say "Done. Takes is in $apps."
else
    say "Done. Opening Takes."
    open "$apps/Takes.app"
fi
