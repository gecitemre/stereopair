#!/bin/bash
# Builds channel-check.wav: speaks "left" on the left channel only and "right"
# on the right only, so you can confirm each Mac is playing its own side.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say -o "$TMP/l.aiff" "left speaker, this is the first mac"
say -o "$TMP/r.aiff" "right speaker, this is the second mac"
ffmpeg -hide_banner -loglevel error -i "$TMP/l.aiff" -i "$TMP/r.aiff" -filter_complex \
"[0:a]aformat=channel_layouts=mono,pan=stereo|c0=c0|c1=0*c0,apad=pad_dur=0.5[a];\
[1:a]aformat=channel_layouts=mono,pan=stereo|c0=0*c0|c1=c0,apad=pad_dur=0.5[b];\
[a][b]concat=n=2:v=0:a=1[o]" -map "[o]" -ar 48000 -y channel-check.wav
echo "built channel-check.wav — play it with: afplay channel-check.wav"
