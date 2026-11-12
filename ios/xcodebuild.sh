#!/bin/bash
# xcodebuild that never runs while the Mac is locked. Xcode keeps the Apple ID login in the
# protected keychain, unreadable while the screen is locked; xcodebuild then reads the account as
# broken and deletes it from Xcode ("No Accounts" on every phone build after, 2026-10-12 to 10-30).
# Locked: wait for an unlock up to XCODEBUILD_LOCK_WAIT seconds (default 900), then exit 75.
# ioreg's output is read whole: `ioreg | grep -q` under pipefail read a locked screen as unlocked.
locked() {
  local s
  s=$(ioreg -n Root -d1 2>/dev/null) || return 0   # a failed ioreg counts as locked
  [[ $s == *'"CGSSessionScreenIsLocked"=Yes'* ]]
}
wait=${XCODEBUILD_LOCK_WAIT:-900}
while locked; do
  if (( wait <= 0 )); then
    echo "xcodebuild: the Mac is locked; not building (it would delete Xcode's Apple ID). Try again once it is unlocked." >&2
    exit 75
  fi
  (( wait == ${XCODEBUILD_LOCK_WAIT:-900} )) && echo "xcodebuild: the Mac is locked; waiting for an unlock." >&2
  sleep 15; wait=$(( wait - 15 ))
done
exec /usr/bin/xcodebuild "$@"
