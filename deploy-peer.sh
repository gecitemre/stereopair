#!/bin/bash
# Puts the app on the second Mac and makes it run at login, so from then on it
# is simply there: the sender finds it over Bonjour and no shell access is
# needed to use it. This one-time copy is the only thing ssh is required for.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

if [ -z "${PEER:-}" ]; then
	echo "deploy: PEER is not set. Copy config.local.sh.example to config.local.sh" >&2
	echo "        and set PEER, e.g. PEER=you@other-mac.local" >&2
	exit 1
fi

[ -d bin/StereoPair.app ] || ./build.sh

ssh "$PEER" 'mkdir -p ~/stereopair ~/Library/LaunchAgents'
rsync -a --delete bin/StereoPair.app "$PEER:stereopair/"

# `open` rather than running the binary: the audio and local-network permissions
# are granted to the app that launches the process, and launchd running the bare
# executable would not carry the app's identity.
ssh "$PEER" 'cat > ~/Library/LaunchAgents/com.emre.stereopair.receiver.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.emre.stereopair.receiver</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-n</string>
		<string>-a</string>
		<string>StereoPair</string>
		<string>--args</string>
		<string>--recv</string>
		<string>--log</string>
		<string>LOGPATH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST

ssh "$PEER" '
	set -e
	HOME_DIR=$HOME
	sed -i "" "s|LOGPATH|$HOME_DIR/stereopair/recv.log|" ~/Library/LaunchAgents/com.emre.stereopair.receiver.plist
	# Register the app with LaunchServices so `open -a StereoPair` resolves it.
	/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
		-f ~/stereopair/StereoPair.app
	# Kill any running copy first: it holds port 4711, so a freshly launched
	# one cannot bind and exits immediately, leaving the old binary serving.
	pkill -f "StereoPair[.]app/Contents/MacOS/stereopair" 2>/dev/null || true
	sleep 1
	launchctl bootout gui/$UID/com.emre.stereopair.receiver 2>/dev/null || true
	launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.emre.stereopair.receiver.plist
	launchctl kickstart -k gui/$UID/com.emre.stereopair.receiver
'

echo "deployed to $PEER, receiver runs at login"
