#!/bin/bash
# Builds both app bundles. They have to be bundled and signed, not bare
# binaries: the audio tap's permission and the local network permission are both
# granted to the app that launches the process, and a bare binary gets silence
# and "No route to host" with no error.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p bin

plist() {
	cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$2</string>
	<key>CFBundleIdentifier</key>
	<string>$3</string>
	<key>CFBundleName</key>
	<string>$4</string>
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
$5
</dict>
</plist>
PLIST
}

# --- StereoPair.app: tap, split, play one channel, ship the other ------------

APP="bin/StereoPair.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/stereopair" src/stereopair.swift
plist "$APP" stereopair com.emre.stereopair StereoPair '	<key>NSAudioCaptureUsageDescription</key>
	<string>StereoPair captures the audio your apps are playing so it can split it across two Macs.</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>StereoPair sends the right channel to the second Mac.</string>'
codesign --force --sign - --identifier com.emre.stereopair "$APP"

# --- StereoMenu.app: the menu bar toggles ------------------------------------

MENU="bin/StereoMenu.app"
rm -rf "$MENU"
mkdir -p "$MENU/Contents/MacOS"
swiftc -O -o "$MENU/Contents/MacOS/StereoMenu" src/StereoMenu.swift
plist "$MENU" StereoMenu com.emre.stereomenu StereoMenu ''
codesign --force --sign - --identifier com.emre.stereomenu "$MENU"

echo "built $APP and $MENU"
echo "menu bar app: open $MENU"
