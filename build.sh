#!/bin/bash
# Builds StereoPair.app. It has to be a bundle and it has to be signed: both the
# audio tap and the local network permission are granted to the app that
# launches a process, and a bare binary silently gets neither.
set -euo pipefail
cd "$(dirname "$0")"

APP="bin/StereoPair.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/stereopair" \
	src/stereopair.swift src/menu.swift src/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>stereopair</string>
	<key>CFBundleIdentifier</key>
	<string>com.emre.stereopair</string>
	<key>CFBundleName</key>
	<string>StereoPair</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.4</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>StereoPair captures the audio your apps are playing so it can split it across two Macs.</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>StereoPair finds the other Mac and sends it the right channel.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.emre.stereopair "$APP"

echo "built $APP"
echo "open it here, and copy it to the other Mac (AirDrop is fine)"
