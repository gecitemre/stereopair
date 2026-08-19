# Copy config.local.sh.example to config.local.sh if you need to override any of
# this. It is git-ignored, so your machine names stay out of the repo.
#
# Precedence: environment variable > config.local.sh > the defaults below. The
# environment has to be captured before the defaults are applied, or a default
# would be indistinguishable from something you actually asked for.
_env_peer="${PEER:-}"
_env_target="${TARGET_MS:-}"
_env_io="${IO_FRAMES:-}"

# The second Mac, as user@host. Only deploy-peer.sh needs it: once the receiver
# is installed there it starts at login and is found over Bonjour, so running
# the rig needs no ssh and no address.
PEER="${PEER:-}"

# How much audio each Mac holds before playing, in ms — the whole latency budget
# and the only thing absorbing network jitter. "auto" lets the sender decide
# once it sees which link it got: 20 ms over a Thunderbolt cable, 150 ms
# otherwise, because Wi-Fi's jitter alone is larger than a 20 ms buffer.
TARGET_MS="${TARGET_MS:-auto}"

# Output IO buffer in frames. 128 = 2.67 ms. The hardware floor is 15.
IO_FRAMES="${IO_FRAMES:-128}"

if [ -f "$(dirname "${BASH_SOURCE[0]}")/config.local.sh" ]; then
	source "$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
fi

[ -n "$_env_peer" ] && PEER="$_env_peer"
[ -n "$_env_target" ] && TARGET_MS="$_env_target"
[ -n "$_env_io" ] && IO_FRAMES="$_env_io"
unset _env_peer _env_target _env_io
