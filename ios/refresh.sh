#!/bin/bash
# Keeps Takes alive on the iPhone with a free Apple ID. A free signing profile stops after 7 days,
# so this gets a new one and installs the app again before that. It runs every hour (LaunchAgent);
# it only builds when the profile has less than 3 days left and the iPhone answers (Wi-Fi or cable).
#   ./refresh.sh          check now, renew if needed
#   ./refresh.sh --force  renew now
#   ./refresh.sh --setup  install the hourly LaunchAgent
set -uo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
BUNDLE=de.marvinaziz.takes.phone
LABEL=de.marvinaziz.takes.phone-refresh
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
RENEW_DAYS=3
# When the profile on the iPhone stops (epoch seconds), written after each install.
STATE="$HOME/Library/Application Support/Takes/phone-app-expires"
log() { echo "$(date '+%F %T') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Takes iPhone app\"" >/dev/null 2>&1 || true; }

if [[ "${1:-}" == "--setup" ]]; then
  # launchd cannot read ~/Documents, so the agent runs the copy that install.sh keeps here.
  MIRROR="$HOME/Library/Application Support/Takes/phone-src"
  mkdir -p "$MIRROR"
  rsync -a --delete --exclude build.noindex --exclude TakesPhone.xcodeproj ./ "$MIRROR/"
  P="$HOME/Library/LaunchAgents/$LABEL.plist"
  cat > "$P" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$MIRROR/refresh.sh</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/takes-phone-refresh.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/takes-phone-refresh.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$P" && echo "LaunchAgent on: $P"
  exit 0
fi

# Our profiles and the hours the newest one has left.
mine=()
left=-1
for f in "$PROFILES"/*.mobileprovision; do
  [[ -f "$f" ]] || continue
  plist=$(security cms -D -i "$f" 2>/dev/null) || continue
  id=$(plutil -extract Entitlements.application-identifier raw - <<<"$plist" 2>/dev/null)
  [[ "$id" == *".$BUNDLE" ]] || continue
  mine+=("$f")
  exp=$(plutil -extract ExpirationDate raw - <<<"$plist")
  h=$(( ($(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s) - $(date +%s)) / 3600 ))
  (( h > left )) && left=$h
done

# Trust what was installed last, not the newest local profile: a build can fetch a new profile
# and then fail to install.
if [[ -s "$STATE" ]]; then left=$(( ($(cat "$STATE") - $(date +%s)) / 3600 )); fi

if [[ "${1:-}" != "--force" ]] && (( left > RENEW_DAYS * 24 )); then
  exit 0   # Plenty of time. Stay quiet: this runs every hour.
fi

# The paired iPhone, and whether it answers now.
J=$(mktemp)
xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1
DEVICE=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["result"]["devices"]; print(next((x["hardwareProperties"]["udid"] for x in d if x["hardwareProperties"].get("platform")=="iOS" and x["hardwareProperties"].get("reality")=="physical"),""))' "$J" 2>/dev/null)
rm -f "$J"
if [[ -z "$DEVICE" ]] || ! xcrun devicectl device info details --device "$DEVICE" --timeout 30 >/dev/null 2>&1; then
  log "iPhone not reachable; profile has ${left}h left. Trying again in an hour."
  # Warn once a day in the last day, at 9 in the morning.
  if (( left >= 0 && left < 24 )) && [[ "$(date +%H)" == "09" ]]; then
    notify "Takes stops on the iPhone in ${left}h. Put the iPhone on the Mac's Wi-Fi, unlocked."
  fi
  exit 0
fi

log "Renewing (profile has ${left}h left)."
# Remove the old profile so Xcode fetches a new 7-day one instead of reusing it.
for f in ${mine[@]+"${mine[@]}"}; do rm -f "$f"; done
if DEVICE="$DEVICE" ./install.sh --now >>"$HOME/Library/Logs/takes-phone-refresh.build.log" 2>&1; then
  exp=$(security cms -D -i build.noindex/Build/Products/Release-iphoneos/Takes.app/embedded.mobileprovision 2>/dev/null | plutil -extract ExpirationDate raw -)
  mkdir -p "$(dirname "$STATE")"
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s > "$STATE"
  log "Renewed. Takes runs on the iPhone until $exp."
else
  log "Renew failed. See ~/Library/Logs/takes-phone-refresh.build.log"
  notify "Could not renew Takes on the iPhone. See takes-phone-refresh.build.log."
fi
