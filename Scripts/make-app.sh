#!/bin/sh
# Builds WinDA.app (unsigned beyond an ad-hoc signature) into dist/.
# usage: Scripts/make-app.sh [debug|release]
set -eu
CONFIG="${1:-debug}"
cd "$(dirname "$0")/.."
swift build -c "$CONFIG" --product WinDA
swift build -c "$CONFIG" --product winda-bottle
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/WinDA.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WinDA" "$BIN/winda-bottle" "$APP/Contents/MacOS/"
cp -R "$BIN/WinDACore_WinDACore.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WinDA</string>
  <key>CFBundleDisplayName</key><string>WinDA</string>
  <key>CFBundleIdentifier</key><string>app.winda.WinDA</string>
  <key>CFBundleExecutable</key><string>WinDA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "built $APP"
