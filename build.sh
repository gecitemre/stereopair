#!/bin/bash
# Builds stereotap into a signed .app bundle. Core Audio process taps are gated
# behind a TCC permission that is only grantable to a bundled, signed app —
# a bare binary gets silence with no error.
set -euo pipefail
cd "$(dirname "$0")"

APP="bin/StereoTap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/stereotap" src/stereotap.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>stereotap</string>
	<key>CFBundleIdentifier</key>
	<string>com.emre.stereotap</string>
	<key>CFBundleName</key>
	<string>StereoTap</string>
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
	<string>StereoTap captures the audio your apps are playing so it can send the left channel to this Mac and the right channel to the other one.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.emre.stereotap "$APP"
ln -sf StereoTap.app/Contents/MacOS/stereotap bin/stereotap

echo "built $APP"
