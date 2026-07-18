#!/bin/bash
# Dev-only: build, sign with the STABLE self-signed identity, install to /Applications, launch.
# Stable signing keeps TCC (Accessibility/Microphone) grants alive across rebuilds — ad-hoc signing
# changes the signature every build and orphans the grant (the stale-grant trap, ORA-BLD-002 / R11).
#
# One-time setup of the identity (already done; recorded in .signing-identity):
#   openssl req -newkey rsa:2048 -nodes -keyout k.pem -x509 -days 3650 -out c.pem \
#     -subj "/CN=Orator Self-Signed" -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -out o.p12 -inkey k.pem -in c.pem -passout pass:CHANGEME
#   security import o.p12 -k ~/Library/Keychains/login.keychain-db -P CHANGEME -T /usr/bin/codesign
#   security find-certificate -c "Orator Self-Signed" -Z | awk '/SHA-1/{print $3}' > .signing-identity
set -euo pipefail
cd "$(dirname "$0")/.."

IDENT="$(cat .signing-identity 2>/dev/null || echo -)"
echo "Signing identity: $IDENT"

pkill -9 -x Orator 2>/dev/null || true
sleep 1
bash Scripts/bundle.sh release
codesign --force --options runtime --entitlements Resources/Orator.entitlements --sign "$IDENT" Orator.app
codesign -d --requirements - Orator.app 2>&1 | grep designated || true

rm -rf /Applications/Orator.app
cp -R Orator.app /Applications/Orator.app
xattr -dr com.apple.quarantine /Applications/Orator.app 2>/dev/null || true
open /Applications/Orator.app
echo "Installed + launched /Applications/Orator.app"
