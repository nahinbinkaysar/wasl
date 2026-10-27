#!/bin/sh
# Builds build/Wasl.app (menu bar app, ad-hoc signed).
set -e
cd "$(dirname "$0")"
APP=build/Wasl.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 *.swift -o "$APP/Contents/MacOS/Wasl"
cp Info.plist "$APP/Contents/"
codesign --force -s - "$APP"
echo "$APP"
