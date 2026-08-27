#!/bin/bash
# Builds StereoPair.app. It has to be a bundle and it has to be signed: both the
# audio tap and the local network permission are granted to the app that
# launches a process, and a bare binary silently gets neither.
set -euo pipefail
cd "$(dirname "$0")"

APP="bin/StereoPair.app"
VERSION="${VERSION:-0.0}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Sparkle handles updates. Fetched by pinned hash rather than checked in.
tools/fetch-sparkle.sh

swiftc -O -F vendor \
	-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	-o "$APP/Contents/MacOS/stereopair" \
	src/stereopair.swift src/menu.swift src/main.swift -framework Sparkle

mkdir -p "$APP/Contents/Frameworks"
cp -R vendor/Sparkle.framework "$APP/Contents/Frameworks/"

# The icon is generated rather than checked in, so it stays editable as code.
mkdir -p "$APP/Contents/Resources"
if [ ! -f build/StereoPair.icns ] || [ tools/make-icon.swift -nt build/StereoPair.icns ]; then
	mkdir -p build
	swiftc -O -o build/makeicon tools/make-icon.swift
	./build/makeicon > /dev/null
	iconutil -c icns build/StereoPair.iconset -o build/StereoPair.icns
fi
cp build/StereoPair.icns "$APP/Contents/Resources/StereoPair.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
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
	<key>CFBundleIconFile</key>
	<string>StereoPair</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>SUFeedURL</key>
	<string>https://github.com/gecitemre/stereopair/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>nsjuwmX79QbjlehnePvkNRZ7nBOjUWtipBlxxNVy5ek=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
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

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
sign_nested() {
	# Innermost first; the XPC services keep their sandbox entitlements.
	codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
		--sign "$1" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
	codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
		--sign "$1" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
	codesign --force --timestamp --options runtime \
		--sign "$1" "$FRAMEWORK/Versions/B/Autoupdate"
	codesign --force --timestamp --options runtime \
		--sign "$1" "$FRAMEWORK/Versions/B/Updater.app"
	codesign --force --timestamp --options runtime --sign "$1" "$FRAMEWORK"
}

if [ -n "$IDENTITY" ]; then
	sign_nested "$IDENTITY"
	codesign --force --timestamp --options runtime \
		--sign "$IDENTITY" --identifier com.emre.stereopair "$APP"
	echo "built $APP"
	echo "signed with: $IDENTITY"
else
	sign_nested -
	codesign --force --sign - --identifier com.emre.stereopair "$APP"
	echo "built $APP"
	echo "ad-hoc signed: runs here, but will not open on another Mac."
	echo "for that, create a Developer ID Application certificate and re-run."
fi
