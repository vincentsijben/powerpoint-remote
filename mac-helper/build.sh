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

# Ad-hoc signature so macOS can remember the Bluetooth / Automation permissions.
codesign --force --deep --sign - "$APP"

echo "Built: $(pwd)/$APP"
