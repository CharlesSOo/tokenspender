#!/bin/sh
# Build a size-optimized release, assemble Tokenmeter.app, install to /Applications, launch.
set -eu
cd "$(dirname "$0")"

swift build -c release -Xswiftc -Osize -Xlinker -dead_strip

APP=build/Tokenmeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tokenmeter "$APP/Contents/MacOS/Tokenmeter"
strip -x "$APP/Contents/MacOS/Tokenmeter"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>so.charles.tokenmeter</string>
  <key>CFBundleName</key><string>Tokenmeter</string>
  <key>CFBundleExecutable</key><string>Tokenmeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"

pkill -x Tokenmeter 2>/dev/null || true
rm -rf "/Applications/Tokenmeter.app"
cp -R "$APP" "/Applications/"
open "/Applications/Tokenmeter.app"
