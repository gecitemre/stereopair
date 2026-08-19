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

# A Developer ID signature is what lets the app open on someone else's Mac, and
# notarization requires the hardened runtime. Fall back to ad-hoc so a plain
# build still works without a certificate — it just will not travel.
IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"

if [ -n "$IDENTITY" ]; then
	codesign --force --timestamp --options runtime \
		--sign "$IDENTITY" --identifier com.emre.stereopair "$APP"
	echo "built $APP"
	echo "signed with: $IDENTITY"
else
	codesign --force --sign - --identifier com.emre.stereopair "$APP"
	echo "built $APP"
	echo "ad-hoc signed: runs here, but will not open on another Mac."
	echo "for that, create a Developer ID Application certificate and re-run."
fi
