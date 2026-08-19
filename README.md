# stereopair

Use two Macs as one stereo pair. The Mac you're working on plays the left
channel, a second Mac plays the right, sample-synced, from whatever audio is
already playing — browser, YouTube Music, Spotify, anything. Nothing to
configure in the app you're listening to.

The two halves of this exist separately (Airfoil syncs audio to several
machines but [doesn't do stereo pairs](https://rogueamoeba.com/support/manuals/airfoil/?page=usage);
Loopback splits channels but only locally). As far as I can tell, nobody has
shipped the combination on macOS.

> **Vibe-coded.** Built with Claude Code (Opus 5). The latency and buffer
> figures are measured on real hardware, not estimated.

```bash
open bin/StereoMenu.app     # menu bar toggles for stereo sync and volume sync
```

or from the terminal:

```bash
./stereo-start
./stereo-stop
```

## Requirements

- Two Macs, both macOS 14.4+ (the audio tap API is new).
- Xcode command line tools, for `swiftc` and `codesign`. Nothing else: no
  Homebrew packages, no runtime dependencies.
- SSH from the first Mac to the second (Remote Login + a key).
- A Thunderbolt cable between them is optional but worth it — see Latency.

## Setup

```bash
# On the second Mac: System Settings > General > Sharing > Remote Login.
ssh-copy-id you@other-mac.local          # once, asks for that Mac's password

cp config.local.sh.example config.local.sh
$EDITOR config.local.sh                  # set PEER=you@other-mac.local

./build.sh          # builds StereoPair.app and StereoMenu.app
./deploy-peer.sh    # copies the same app to the second Mac
open bin/StereoMenu.app
```

Then grant two permissions, both of which are described below. `./stereo-doctor`
checks every prerequisite and tells you exactly which one is missing.

Confirm the channels are the right way round:

```bash
./bin/make-channel-check.sh && afplay channel-check.wav
```

It says "left speaker" out of the first Mac only, then "right speaker" out of
the second.

## How it works

```
apps (browser, …)
   │  Core Audio process tap, muted at the speakers while tapped
   ▼
StereoPair.app ──┬── left  channel ─→ this Mac's speakers
                 └── right channel ─→ tcp ─→ StereoPair.app ─→ second Mac
```

One process on each machine, talking raw PCM over TCP. Both sides hold the same
target buffer before playing, so they stay aligned: the network adds well under
a millisecond over a cable, which is nothing next to the target.

The tap excludes this process. That matters twice — our own left-channel
playback would otherwise be captured straight back into the stream and build
into a feedback howl, and `mutedWhenTapped` would silence it at the speakers.
The output device is opened *before* the tap is created, because a process only
becomes excludable once it has one.

## Latency

**~32 ms end to end**, measured: a 20 ms target, a 2.67 ms output buffer and
roughly one capture period. That is below the ~45 ms at which audio lagging
video becomes noticeable, so video stays watchable.

| | over Thunderbolt | over Wi-Fi |
|---|---|---|
| ping jitter | 0.06 ms stddev | 28.8 ms stddev |
| usable target | **20 ms** | 150 ms+, untuned |

`IFACE` and `TARGET_MS` both default to `auto`: a direct Thunderbolt cable is
used when both Macs can actually reach each other over it, otherwise Wi-Fi, and
the target follows the link — 20 ms cannot survive Wi-Fi, whose jitter alone is
larger than the whole buffer. `bridge0` exists and stays UP with no cable
attached, so detection checks that the peer answers on it, not merely that the
interface exists. `stereo-start` prints what it chose:

```
stereo is up over thunderbolt, 20ms target
```

Pin `IFACE=bridge0` or `IFACE=en0` in `config.local.sh` to decide yourself. ssh
can stay on Wi-Fi either way; only the audio follows `IFACE`.

**Nothing corrects for clock drift.** The two machines' audio crystals differ by
a few ppm, so the receiver's buffer creeps until it is trimmed or briefly runs
dry — a short discontinuity now and then, not a failure. Over six minutes of
continuous audio it did not happen once. Fixing it properly means resampling.

An earlier version of this used snapcast, which does handle drift, at 350–500 ms
of buffer and ~515 ms end to end. Its client could not schedule playback sooner
than its own ~100 ms CoreAudio output queue, and that queue was a software
choice: the hardware floor is 15 frames, 0.31 ms.

## Two macOS permissions, both of which fail silently

These cost most of the development time. Both report success and then do
nothing. `./stereo-doctor` detects both by testing behaviour rather than
trusting a return code.

**1. System audio recording (first Mac).** `AudioHardwareCreateProcessTap`
succeeds, callbacks fire at the right rate, and every sample is zero. The
permission is charged to the app that *launched* the process, so running the
binary from a terminal charges it to the terminal. Fix: ship it as a signed
`.app` and launch it with `open`, giving it its own identity. Confirm a denial:

```bash
log show --last 5m --predicate 'process == "coreaudiod"' --style compact | grep -i "not granted"
```

Allow it under Privacy & Security → Screen & System Audio Recording.

**2. Local Network (first Mac).** A bare binary's outbound LAN connections are
dropped by NECP and surface as `No route to host`, even though `ping` and `nc`
to the same port succeed — Apple's own binaries are exempt, yours is not. Same
fix: a bundled, signed app that can appear in Settings and be allowed.

Rebuilding changes the ad-hoc signature, which macOS treats as a new identity:
the first connection after a build is refused while it re-registers, and the
next succeeds. `stereo-start` retries once for that reason.

```bash
log show --last 5m --style compact --info --debug | grep -iE "NECP|local network"
```

Allow it under Privacy & Security → Local Network. If it never appears in that
list, it hasn't requested access yet — start it, then reopen Settings.

## Volume

`stereo-start` runs a watcher that keeps both machines at the same level,
whichever one you change. Same OS and same hardware means the same slider value
is the same gain, so no curve mapping is involved and there is no software mixer
in the audio path.

```bash
./stereo-volume        # show both, warn if they have drifted apart
./stereo-volume 60     # set both
```

The watcher levels the two to the *quieter* of them when it starts, so enabling
it never raises a machine unexpectedly.

Stereo sync and volume sync are independent — the menu bar app toggles each on
its own, and `SYNC_VOLUME=0 ./stereo-start` skips the watcher from the terminal.

## Placement

Stereo wants an equilateral triangle: the gap between the machines should be
about the distance from each machine to your head — roughly 60–80 cm at a desk —
with you centred between them. Too close and you have rebuilt one laptop's
speaker spacing with extra latency. Too far and centred content (vocals, bass)
stops forming a phantom centre and collapses into two separate sources. Sitting
off to one side is worse than either.

## Files

| | |
|---|---|
| `src/stereopair.swift` | Everything: tap, split, playback, transport |
| `build.sh` | Builds and signs both app bundles |
| `deploy-peer.sh` | Copies the app to the second Mac |
| `stereo-start` / `stereo-stop` | Bring the rig up and down |
| `src/StereoMenu.swift` | Menu bar app: toggles for stereo sync and volume sync |
| `stereo-volume-sync` | `start` / `stop` / `status` the volume watcher on its own |
| `stereo-doctor` | Checks prerequisites and both silent-failure permissions |
| `stereo-volume` | Show/set both levels, per-side trims |
| `config.sh` | Buffer, interface; reads `config.local.sh` for your peer |

Nothing is installed on the second Mac and it needs no admin password.

## Notes

- The tap uses `CATapMutedWhenTapped`, so tapped apps stop reaching the first
  Mac's speakers while the rig runs; you hear only the split output. Stopping
  restores normal audio.
- The sender ships exactly one chunk per chunk-period against a monotonic
  deadline. Waiting for a full chunk instead stops the stream whenever nothing
  is playing — the tap produces nothing during silence — and the receiver drains
  and then takes a burst when audio resumes, which sounds like static. Padding
  without the deadline is the opposite mistake: a chunk per gap *and* a chunk
  per capture is twice real time, and the receiver throws half the stream away.
- Never run two taps over the same audio at once. A second one captures what the
  first is already playing, feeds it back in, and it builds into a rising howl.
- Taps and their aggregate devices outlive the process unless destroyed.
  Leaked ones accumulate in coreaudiod until every `AudioDeviceStart` blocks
  forever and only `sudo killall coreaudiod` clears it, so tear them down on
  every exit path including signals.
- Creating and destroying taps many times in a row can wedge `coreaudiod`, and
  every tap then blocks in `AudioDeviceCreateIOProcIDWithBlock`. Normal playback
  keeps working, which makes it confusing. Fix: `sudo killall coreaudiod`.

## Licence

MIT, see [LICENSE](LICENSE). No third-party code is bundled or required.
