#!/bin/bash
# Builds "PPT Remote.app" (menu bar helper) using only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PPT Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/PPTRemote"

cp Info.plist "$APP/Contents/Info.plist"
cp -R ../docs/. "$APP/Contents/Resources/web/"

# Ad-hoc signature so macOS can remember the Bluetooth / Automation / Accessibility permissions.
# The explicit requirement (bundle identifier instead of the default per-build hash) keeps those
# permissions valid after a rebuild.
codesign --force --deep --sign - -r='designated => identifier "local.pptremote.helper"' "$APP"

echo "Built: $(pwd)/$APP"
