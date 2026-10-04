#!/bin/bash
# Builds the iPhone app and stages it: the phone shows Update, and the user's tap makes the Mac
# install it (Sources/Takes/PhoneUpdate.swift), so a build never ends the app while he uses it.
#   ./install.sh         build and stage
#   ./install.sh --now   build and install at once (refresh.sh, or when the user asks)
# The iPhone is reached by USB, or the same Wi-Fi once paired in Xcode.
# Once: Xcode > Settings > Accounts > add your Apple ID. Then TAKES_TEAM is its team id
# A free account works: the app stops after 7 days, and refresh.sh (hourly LaunchAgent) renews it.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TAKES_TEAM="${TAKES_TEAM:?Set TAKES_TEAM to your Apple developer team id}"