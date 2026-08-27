#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT="${ROOT:h}/build"
APP="$OUTPUT/ResourceLens.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

xcrun clang \
  -fobjc-arc \
  -O2 \
  -framework Cocoa \
  -framework QuartzCore \
  -framework IOKit \
  -framework ServiceManagement \
  "$ROOT/main.m" \
  -o "$APP/Contents/MacOS/MacUsageBar"

chmod +x "$APP/Contents/MacOS/MacUsageBar"
codesign --force --deep --sign - "$APP"
echo "$APP"
