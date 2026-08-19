#!/bin/bash
# Builds a signed, notarized, stapled DMG that opens on anyone's Mac.
#
# Needs, once:
#   1. A "Developer ID Application" certificate in the keychain. Xcode >
#      Settings > Accounts > your team > Manage Certificates > + . An
#      "Apple Distribution" certificate is not the same thing and will not work
#      outside the App Store.
#   2. Notarisation credentials stored under a profile name:
#      xcrun notarytool store-credentials stereopair \
#        --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#      The password comes from appleid.apple.com, not your Apple ID password.
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-stereopair}"
VERSION="${VERSION:-1.0}"
APP="bin/StereoPair.app"
DMG="bin/StereoPair-$VERSION.dmg"

IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
if [ -z "$IDENTITY" ]; then
	echo "release: no Developer ID Application certificate found." >&2
	echo "         Apple Distribution certificates do not work for this." >&2
	exit 1
fi

SIGN_ID="$IDENTITY" ./build.sh
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$DMG"
# A bare disk image shows the app on its own with no hint of what to do with it.
# create-dmg lays out the familiar window: the app on the left, an Applications
# shortcut on the right, drag one onto the other.
if command -v create-dmg >/dev/null; then
	create-dmg \
		--volname "StereoPair" \
		--window-size 520 340 \
		--icon-size 110 \
		--icon "StereoPair.app" 130 150 \
		--app-drop-link 390 150 \
		--hide-extension "StereoPair.app" \
		--no-internet-enable \
		"$DMG" "$APP" >/dev/null
else
	echo "release: create-dmg not found (brew install create-dmg); falling back" >&2
	STAGE=$(mktemp -d)
	cp -R "$APP" "$STAGE/"
	ln -s /Applications "$STAGE/Applications"
	hdiutil create -quiet -volname StereoPair -srcfolder "$STAGE" -ov -format UDZO "$DMG"
	rm -rf "$STAGE"
fi
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "notarising, this usually takes a few minutes…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Staple so it opens with no network round trip on the user's machine.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "$DMG is ready to hand out"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  /'
