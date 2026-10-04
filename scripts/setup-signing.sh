#!/bin/bash
# One-time: make a self-signed code-signing certificate for Takes, in its own keychain.
#
# Why: an ad-hoc signature (codesign -s -) changes with every build, so macOS asks for camera,
# microphone and screen permission again after each install. A stable certificate keeps the same
# signing identity, and macOS remembers the permissions.
#
# The keychain password lives in ~/.config/takes/keychain-pass (mode 600). It only protects this
# local certificate. Safe to run again: it does nothing when the keychain exists.
set -euo pipefail
NAME="Takes Local Signing"
KC="$HOME/Library/Keychains/takes-signing.keychain-db"
PASSFILE="$HOME/.config/takes/keychain-pass"
if [[ -f "$KC" ]]; then echo "Signing keychain exists: $KC"; exit 0; fi

mkdir -p "$(dirname "$PASSFILE")"
( umask 077; openssl rand -hex 24 > "$PASSFILE" )
PASS="$(cat "$PASSFILE")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

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

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P takes -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
# Add to the search list so codesign finds the identity, keeping the existing keychains.
EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
security list-keychains -d user -s $EXISTING "$KC"
echo "Created $NAME in $KC"
