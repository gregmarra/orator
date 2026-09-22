#!/bin/bash
# Assemble (and optionally sign + notarize) Orator.app from the SwiftPM release build.
# ORA-BLD-001/003; signing keeps TCC grants stable across rebuilds (ORA-BLD-002 / R11).
#
# Usage:
#   Scripts/bundle.sh [config]                                  # assemble only
#   SIGN_ID="Developer ID Application: You (TEAMID)" \
#     NOTARY_PROFILE="orator" Scripts/bundle.sh release         # sign + notarize + staple + zip
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_DIR="Orator.app"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG" --product Orator
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Orator" "$APP_DIR/Contents/MacOS/Orator"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Stamp the build fingerprint into the copied plist (ORA-BLD-005; the template in Resources/ stays clean, so a
# build never dirties the tree it is fingerprinting). Read back at runtime by `AppVersion` and shown
# at the bottom of the settings pane. Must run BEFORE codesign below — the plist is sealed into the
# signature. Outside a git checkout every value falls back and the footer just shows less.
GIT_REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git status --porcelain 2>/dev/null)" ] && GIT_REV="$GIT_REV-dirty"
# Commit count as CFBundleVersion: monotonic, which is what macOS and any updater require of it.
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
plutil -replace CFBundleVersion -string "$BUILD_NUM"  "$APP_DIR/Contents/Info.plist"
plutil -replace ORAGitRevision  -string "$GIT_REV"    "$APP_DIR/Contents/Info.plist"
plutil -replace ORABuildDate    -string "$BUILD_DATE" "$APP_DIR/Contents/Info.plist"
echo "Version stamp: $(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist") ($BUILD_NUM) $GIT_REV"
# App icon. Ship the prebuilt layered Liquid Glass asset (Assets.car, referenced by
# CFBundleIconName) + a fallback AppIcon.icns. Both are compiled from Resources/AppIcon.icon via
# `Scripts/build-icon.sh` (actool). We copy the prebuilt outputs rather than run actool here because
# ibtoold crashes intermittently on repo paths; regenerate with build-icon.sh when the art changes.
[ -f Resources/Assets.car ] && cp Resources/Assets.car "$APP_DIR/Contents/Resources/Assets.car"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

if [ -n "${SIGN_ID:-}" ]; then
  echo "Signing with Hardened Runtime + entitlements..."
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Orator.entitlements \
    --sign "$SIGN_ID" "$APP_DIR"
  codesign --verify --strict --verbose=2 "$APP_DIR"

  ZIP="Orator.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"   # re-zip the stapled app for distribution
  else
    echo "SIGN_ID set but NOTARY_PROFILE not — signed but NOT notarized (dev only)."
  fi
  echo "Done: $APP_DIR (+ $ZIP)"
else
  echo "Unsigned dev bundle (set SIGN_ID to sign). Done: $APP_DIR"
fi
