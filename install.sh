#!/bin/sh
# Build a size-optimized release, assemble tokenspender.app, install to ~/Applications, launch.
set -eu
cd "$(dirname "$0")"

swift build -c release -Xswiftc -Osize -Xlinker -dead_strip

APP=build/tokenspender.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TokenSpender "$APP/Contents/MacOS/tokenspender"
strip -x "$APP/Contents/MacOS/tokenspender"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>so.charles.tokenspender</string>
  <key>CFBundleName</key><string>tokenspender</string>
  <key>CFBundleExecutable</key><string>tokenspender</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"

pkill -x tokenspender 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/tokenspender.app"
cp -R "$APP" "$HOME/Applications/"
open "$HOME/Applications/tokenspender.app"
