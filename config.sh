# Copy config.local.sh.example to config.local.sh and set PEER there.
# config.local.sh is git-ignored, so your machine names stay out of the repo.
#
# Precedence: environment variable > config.local.sh > the defaults below.
# The environment has to be captured here, before the defaults are applied,
# or a default would be indistinguishable from something you actually asked for
# and would override config.local.sh.
_env_peer="${PEER:-}"
_env_buffer="${BUFFER:-}"
_env_iface="${IFACE:-}"
_env_sync_volume="${SYNC_VOLUME:-}"

# The second Mac, as user@host. It plays the right channel.
PEER="${PEER:-}"

# Snapcast playback buffer in ms: how far behind real time both Macs play, and
# the headroom that absorbs network jitter. Too low and a client starves and
# exits. "auto" follows the link, which matters because a value tuned for the
# wired link will starve clients over Wi-Fi.
BUFFER="${BUFFER:-auto}"
BUFFER_WIRED="${BUFFER_WIRED:-350}"      # measured floor over Thunderbolt
BUFFER_WIRELESS="${BUFFER_WIRELESS:-500}" # measured floor over Wi-Fi

# Interface the second Mac connects back on. "auto" uses a direct Thunderbolt
# cable when both Macs can actually reach each other over it, else Wi-Fi.
# Force it with bridge0 or en0 if you would rather decide yourself.
IFACE="${IFACE:-auto}"

# Whether stereo-start also starts the volume watcher. The menu bar app sets
# this to 0 and manages the watcher itself, so the two can be toggled apart.
SYNC_VOLUME="${SYNC_VOLUME:-1}"

if [ -f "$(dirname "${BASH_SOURCE[0]}")/config.local.sh" ]; then
	source "$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
fi

[ -n "$_env_peer" ] && PEER="$_env_peer"
[ -n "$_env_buffer" ] && BUFFER="$_env_buffer"
[ -n "$_env_iface" ] && IFACE="$_env_iface"
[ -n "$_env_sync_volume" ] && SYNC_VOLUME="$_env_sync_volume"
unset _env_peer _env_buffer _env_iface _env_sync_volume

if [ -z "$PEER" ]; then
	echo "stereo: PEER is not set. Copy config.local.sh.example to config.local.sh" >&2
	echo "        and set PEER to the second Mac, e.g. PEER=you@other-mac.local" >&2
	exit 1
fi
