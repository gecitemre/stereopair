#!/bin/bash
# The second Mac has no Homebrew, so ship snapclient as a self-contained .app:
# the Homebrew dylibs travel with it and the load commands are repointed at
# @loader_path. It has to be a bundle, not a bare binary, because macOS gates
# LAN connections behind Local Network privacy — an unbundled binary's SYNs are
# dropped by NECP with EHOSTUNREACH and it can never appear in Settings to be
# allowed. Nothing on it needs installing and no admin password is required.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

APP="build/SnapRight.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS/lib"
cp /opt/homebrew/bin/snapclient "$MACOS/snapclient"
chmod u+w "$MACOS/snapclient"

homebrew_deps() {
	otool -L "$1" | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew' || true
}

collect() {
	local dep name
	for dep in $(homebrew_deps "$1"); do
		name=$(basename "$dep")
		if [ ! -f "$MACOS/lib/$name" ]; then
			cp "$dep" "$MACOS/lib/$name"
			chmod u+w "$MACOS/lib/$name"
			collect "$MACOS/lib/$name"
		fi
	done
}
collect "$MACOS/snapclient"

for lib in "$MACOS"/lib/*.dylib; do
	install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null
	for dep in $(homebrew_deps "$lib"); do
		install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$lib" 2>/dev/null
	done
	codesign --force --sign - "$lib" 2>/dev/null
done

for dep in $(homebrew_deps "$MACOS/snapclient"); do
	install_name_tool -change "$dep" "@loader_path/lib/$(basename "$dep")" "$MACOS/snapclient" 2>/dev/null
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>snapclient</string>
	<key>CFBundleIdentifier</key>
	<string>com.emre.snapright</string>
	<key>CFBundleName</key>
	<string>SnapRight</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>SnapRight receives the right speaker channel from the other Mac over your local network.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

codesign --force --sign - --identifier com.emre.snapright "$APP"

echo "bundled $(ls "$MACOS/lib" | wc -l | tr -d ' ') libraries"

ssh "$PEER" 'mkdir -p ~/stereo-right'
rsync -a --delete "$APP" "$PEER:stereo-right/"
ssh "$PEER" '~/stereo-right/SnapRight.app/Contents/MacOS/snapclient --version | head -1'
