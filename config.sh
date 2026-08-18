# Copy config.local.sh.example to config.local.sh and set PEER there.
# config.local.sh is git-ignored, so your machine names stay out of the repo.

# The second Mac, as user@host. It plays the right channel.
PEER="${PEER:-}"

# Snapcast playback buffer in ms. How far behind real time both Macs play, and
# the headroom that absorbs Wi-Fi jitter. Lower feels more responsive; too low
# and the remote client starves and exits. 500 is a tested floor over Wi-Fi.
BUFFER="${BUFFER:-500}"

# Network interface used to reach the second Mac.
IFACE="${IFACE:-en0}"

if [ -f "$(dirname "${BASH_SOURCE[0]}")/config.local.sh" ]; then
	source "$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
fi

if [ -z "$PEER" ]; then
	echo "stereo: PEER is not set. Copy config.local.sh.example to config.local.sh" >&2
	echo "        and set PEER to the second Mac, e.g. PEER=you@other-mac.local" >&2
	exit 1
fi
