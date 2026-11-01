#!/bin/bash
#
# Builds the macOS app (ad-hoc signed, sandboxed) and an unsigned iOS IPA.
# Usage: ./scripts/build.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Release}"

echo "==> Generating Xcode project"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
else
  echo "    xcodegen not found; using the committed GameSaveSync.xcodeproj"
fi

echo "==> Building macOS app ($CONFIG)"
xcodebuild -project GameSaveSync.xcodeproj \
  -scheme GameSaveSync-macOS \
  -configuration "$CONFIG" \
  -derivedDataPath build/mac \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build | tail -3

MAC_APP="build/mac/Build/Products/$CONFIG/GameSaveSync.app"
mkdir -p dist
rm -rf "dist/GameSaveSync.app"
cp -R "$MAC_APP" "dist/GameSaveSync.app"
echo "    macOS app: $ROOT/dist/GameSaveSync.app"

echo "==> Building iOS app for device (unsigned)"
xcodebuild -project GameSaveSync.xcodeproj \
  -scheme GameSaveSync-iOS \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-device \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build | tail -3

IOS_APP="build/ios-device/Build/Products/$CONFIG-iphoneos/GameSaveSync.app"
if [ ! -d "$IOS_APP" ]; then
  echo "iOS build product not found at $IOS_APP" >&2
  exit 1
fi

echo "==> Packaging unsigned IPA"
rm -rf build/ipa-stage
mkdir -p build/ipa-stage/Payload
cp -R "$IOS_APP" build/ipa-stage/Payload/
rm -f dist/GameSaveSync-unsigned.ipa
(cd build/ipa-stage && /usr/bin/zip -qry "$ROOT/dist/GameSaveSync-unsigned.ipa" Payload)
rm -rf build/ipa-stage

echo "    IPA: $ROOT/dist/GameSaveSync-unsigned.ipa"
echo
echo "The IPA is unsigned. Sign it with your own Apple ID using Xcode,"
echo "Sideloadly or AltStore before installing. See README.md."
