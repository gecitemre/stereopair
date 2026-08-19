#!/bin/bash
# Ships the same app to the second Mac, where it runs as the receiver. It has to
# be a bundle there too, not a bare binary, or macOS drops its network traffic.
# Nothing is installed and no admin password is needed.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

[ -d bin/StereoPair.app ] || ./build.sh

ssh "$PEER" 'mkdir -p ~/stereopair'
rsync -a --delete bin/StereoPair.app "$PEER:stereopair/"
ssh "$PEER" 'test -x ~/stereopair/StereoPair.app/Contents/MacOS/stereopair' \
	&& echo "deployed to $PEER"
