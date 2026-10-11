#!/bin/bash
# Builds "PPT Remote.app" (menu bar helper) using only the Xcode Command Line Tools.
# UNIVERSAL=1 ./build.sh builds for both Apple silicon and Intel Macs (used for the download on GitHub).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PPT Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCHS="arm64 x86_64"
else
  ARCHS="$(uname -m)"
fi

BINS=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    Sources/*.swift \
    -o "build/PPTRemote-$arch"
  BINS+=("build/PPTRemote-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/PPTRemote"
rm -f "${BINS[@]}"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Sounds "$APP/Contents/Resources/"
cp -R ../docs/. "$APP/Contents/Resources/web/"

# Ad-hoc signature so macOS can remember the Bluetooth / Automation / Accessibility permissions.
# The explicit requirement (bundle identifier instead of the default per-build hash) keeps those
# permissions valid after a rebuild.
codesign --force --deep --sign - -r='designated => identifier "local.pptremote.helper"' "$APP"

echo "Built: $(pwd)/$APP ($ARCHS)"
