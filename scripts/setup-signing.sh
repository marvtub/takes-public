#!/bin/bash
# One-time: make a self-signed code-signing certificate for Takes, in its own keychain.
#
# Why: an ad-hoc signature (codesign -s -) changes with every build, so macOS asks for camera,
# microphone and screen permission again after each install. A stable certificate keeps the same
# signing identity, and macOS remembers the permissions.
#
# The keychain password lives in ~/.config/takes/keychain-pass (mode 600). It only protects this
# local certificate. Safe to run again: it verifies a completed keychain before returning.
set -euo pipefail
NAME="Takes Local Signing"
KC="$HOME/Library/Keychains/takes-signing.keychain-db"
PASSFILE="$HOME/.config/takes/keychain-pass"

user_keychains() {
  security list-keychains -d user 2>/dev/null \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

keychain_is_ready() {
  local saved_password
  [[ -f "$KC" && -s "$PASSFILE" ]] || return 1
  saved_password="$(<"$PASSFILE")"
  [[ -n "$saved_password" ]] || return 1
  security unlock-keychain -p "$saved_password" "$KC" >/dev/null 2>&1 || return 1
  security find-identity -p codesigning "$KC" 2>/dev/null \
    | grep -F "\"$NAME\"" >/dev/null || return 1
  user_keychains | grep -Fx "$KC" >/dev/null
}

if [[ -e "$KC" || -L "$KC" ]]; then
  if keychain_is_ready; then
    echo "Signing keychain is ready: $KC"
    exit 0
  fi
  echo "Signing keychain is not ready: $KC" >&2
  echo "Delete it with: security delete-keychain \"$KC\"" >&2
  echo "Then run this script again." >&2
  exit 1
fi

TMP="$(mktemp -d)"
CREATED_KEYCHAIN=""
CREATED_PASSFILE=""
FINISHED=""
cleanup() {
  local status=$? keychain_removed=1
  # bash 3.2 runs this trap with $? = 0 after a fatal expansion error (an unbound variable), so a
  # run that never reached the end counts as failed (2026-11-06).
  [[ $status -ne 0 || -n "$FINISHED" ]] || status=1
  rm -rf "$TMP"
  if [[ $status -ne 0 ]]; then
    if [[ -n "$CREATED_KEYCHAIN" ]]; then
      security delete-keychain "$KC" >/dev/null 2>&1 || keychain_removed=""
    fi
    if [[ -n "$CREATED_PASSFILE" && ( -z "$CREATED_KEYCHAIN" || -n "$keychain_removed" ) ]]; then
      rm -f "$PASSFILE"
    fi
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$(dirname "$PASSFILE")"
if [[ -e "$PASSFILE" ]]; then
  if [[ ! -f "$PASSFILE" || ! -s "$PASSFILE" || ! -r "$PASSFILE" ]]; then
    echo "Signing password file is not usable: $PASSFILE" >&2
    exit 1
  fi
else
  CREATED_PASSFILE=1
  ( umask 077; openssl rand -hex 24 > "$PASSFILE" )
fi
PASS="$(cat "$PASSFILE")"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:takes 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
       -out "$TMP/id.p12" -passout pass:takes

CREATED_KEYCHAIN=1
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P takes -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
# Add to the search list so codesign finds the identity, keeping the existing keychains.
if ! CURRENT_KEYCHAINS="$(user_keychains)"; then
  echo "Could not read the user keychain search list." >&2
  exit 1
fi
EXISTING=()
while IFS= read -r keychain; do
  [[ -z "$keychain" || "$keychain" == "$KC" ]] || EXISTING+=("$keychain")
done <<< "$CURRENT_KEYCHAINS"
# An empty list is unbound under set -u in bash 3.2: expand it only when it has entries.
security list-keychains -d user -s ${EXISTING[@]+"${EXISTING[@]}"} "$KC"
if ! keychain_is_ready; then
  echo "Signing keychain setup did not complete: $KC" >&2
  exit 1
fi
FINISHED=1
echo "Created $NAME in $KC"
