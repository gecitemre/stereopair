# stereopair

Use two Macs as one stereo pair. The Mac you're working on plays the left
channel, a second Mac plays the right, sample-synced, from whatever audio is
already playing — browser, YouTube Music, Spotify, anything. Nothing to
configure in the app you're listening to.

The two halves of this exist separately (Airfoil syncs audio to several
machines but [doesn't do stereo pairs](https://rogueamoeba.com/support/manuals/airfoil/?page=usage);
Loopback splits channels but only locally). As far as I can tell, nobody has
shipped the combination on macOS.

> **Vibe-coded.** This whole repo was built with Claude Code (Opus 5) — the
> Swift, the shell, the Python and this README. I said what I wanted and it
> wrote, ran and debugged the thing against my two MacBook Pros.
>
> The numbers here are real. Every latency and buffer figure was measured on
> that hardware during the build, and where a measurement turned out to be wrong
> it was re-taken and corrected rather than quietly kept. But treat this for
> what it is: it works, it has been tested on exactly one pair of Macs, and
> nobody else has reviewed it.

```bash
open bin/StereoMenu.app     # menu bar toggles for stereo sync and volume sync
```

or from the terminal:

```bash
./stereo-start
./stereo-stop
```

## Requirements

- Two Macs on the same network, both macOS 14.4+ (the audio tap API is new).
- Xcode command line tools, for `swiftc` and `codesign`.
- `brew install snapcast` on the machine that plays the left channel. The
  second Mac needs nothing installed — it receives a self-contained app bundle.
- SSH from the first Mac to the second (Remote Login + a key).

## Setup

```bash
# On the second Mac: System Settings > General > Sharing > Remote Login.
ssh-copy-id you@other-mac.local          # once, asks for that Mac's password

cp config.local.sh.example config.local.sh
$EDITOR config.local.sh                  # set PEER=you@other-mac.local

./build.sh          # builds StereoTap.app and StereoMenu.app
./deploy-peer.sh    # ships snapclient to the second Mac as SnapRight.app
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
StereoTap.app ──┬── left  channel ─→ FIFO ─┐
                └── right channel ─→ FIFO ─┤
                                           ▼
                                      snapserver  (two mono streams)
                                        │      │
                     tcp/1704 ──────────┘      └────────── tcp/1704
                         ▼                                     ▼
                  snapclient (local)                  SnapRight.app (peer)
                   left speaker                        right speaker
```

`snapcast` is what makes this a stereo pair rather than an echo: it timestamps
every chunk against a shared clock so both machines play the same instant
together. There is no delay *between* the two Macs — `BUFFER` is how far behind
the source they both are.

Channel splitting happens on the server, not the client: snapclient has no
per-client channel option, so the tap writes two separate mono streams and each
Mac is assigned to one.

**Buffer**: the single number that decides both stability and how far behind
the source you are. Measured on real hardware, checking *both* clients survive
20–60 s of continuous audio:

| link | ping jitter | tested stable | fails at |
|---|---|---|---|
| Wi-Fi | 28.8 ms stddev, 90 ms worst | 500 ms | 300 ms |
| Thunderbolt bridge | 0.06 ms stddev, 0.43 ms worst | **350 ms** | 300 ms |

A direct Thunderbolt cable between the two Macs cuts jitter ~490× and takes the
buffer from 500 ms to 350 ms.

Both `IFACE` and `BUFFER` default to `auto`: the cable is used when both Macs
can actually reach each other over it, otherwise Wi-Fi, and the buffer follows
the link — a value tuned for the cable starves clients over Wi-Fi. `bridge0`
exists and stays UP with no cable attached, so detection checks that the peer
has a bridge address and answers on it, not merely that the interface is there.
`stereo-start` prints what it chose:

```
stereo: thunderbolt link (169.254.115.177), buffer 350ms
stereo: wi-fi link (192.168.1.24), buffer 500ms
```

Pin `IFACE=bridge0` or `IFACE=en0` in `config.local.sh` to decide yourself. ssh
can stay on Wi-Fi either way; only the audio stream follows `IFACE`.

The gain is real but smaller than the jitter numbers suggest, because below
~300 ms the limit stops being the network:

```
(Stream) outputBufferDacTime > bufferMs: 115 > 50
```

snapclient cannot schedule playback sooner than its own CoreAudio output buffer,
about 115 ms, and it needs headroom above that to refill without starving. A
faster link cannot fix that.

**End-to-end delay** is the buffer plus the tap's backlog (~60 ms) plus the
client's output queue (~100 ms): roughly **515 ms wired, 650 ms on Wi-Fi**.
Audio lagging video is noticeable past ~45 ms and objectionable past ~125 ms, so
**this is for music — video will never lip-sync**, on any link. Toggle stereo
sync off in the menu bar to watch something.

When testing buffer values, verify *both* clients survive. The local one dies of
the same starvation as the remote one, and checking only the remote will tell
you a setting works when it does not.

Ignore `diff to server [ms]: 2.0e+09` in the client logs. snapcast times against
a monotonic clock, so that figure is just the two machines' uptime difference,
which it measures and subtracts. It is not drift.

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

**2. Local Network (second Mac).** A bare binary's outbound LAN connections are
dropped by NECP and surface as `No route to host`, even though `ping` and `nc`
to the same port succeed — Apple's own binaries are exempt, yours is not. Same
fix: a bundled, signed app that can appear in Settings and be allowed.

```bash
log show --last 5m --style compact --info --debug | grep -iE "NECP|local network"
```

Allow it under Privacy & Security → Local Network. If it never appears in that
list, it hasn't requested access yet — start it, then reopen Settings.

## Volume

`stereo-start` runs a watcher that keeps both machines at the same level,
whichever one you change. Same OS and same hardware means the same slider value
is the same gain, so no curve mapping is involved.

```bash
./stereo-volume                      # show both, warn if they have drifted apart
./stereo-volume 60                   # set both through snapcast's mixer
./stereo-volume 60 --trim-right -8   # keep the right side 8 points quieter
```

Trims persist in `run/trim.json`. The watcher levels the two machines to the
*quieter* of them when it starts, so enabling it never raises a machine
unexpectedly.

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
| `src/stereotap.swift` | Core Audio tap: captures system audio, splits L/R into two FIFOs |
| `build.sh` | Builds and signs both app bundles |
| `deploy-peer.sh` | Bundles snapclient + dylibs into `SnapRight.app`, ships it to the peer |
| `stereo-start` / `stereo-stop` | Bring the rig up and down |
| `src/StereoMenu.swift` | Menu bar app: toggles for stereo sync and volume sync |
| `stereo-volume-sync` | `start` / `stop` / `status` the volume watcher on its own |
| `stereo-doctor` | Checks prerequisites and both silent-failure permissions |
| `stereo-volume` | Show/set both levels, per-side trims |
| `bin/assign.py` | Puts each client in its own group and points it at its channel |
| `config.sh` | Buffer, interface; reads `config.local.sh` for your peer |

Nothing is installed on the second Mac and it needs no admin password —
`SnapRight.app` carries its own libraries.

## Notes

- The tap uses `CATapMutedWhenTapped`, so tapped apps stop reaching the first
  Mac's speakers while the rig runs; you hear only the split output. Stopping
  restores normal audio.
- The local snapclient is excluded from the tap by PID, or its own playback
  would be captured back into the stream. That exclusion can't be resolved until
  the client has opened an output device, which it won't do until audio reaches
  it — so the tap feeds silence into the pipes first and waits. Skip that and
  the exclusion list comes back empty and the tap mutes the client it is
  feeding.
- The writer always emits a full chunk, padding with silence when the tap is
  idle, and sleeps for the span it invents. Let the stream run dry and the
  clients replay their last buffer until they time out, which sounds like the
  audio sticking in a loop where you pressed stop. Omit the sleep and a reader
  that never blocks lets the loop spin and write gigabytes per second.
- `http://localhost:1780` is snapcast's control UI — per-client volume and a
  latency slider if the two speakers need trimming against each other.
- Creating and destroying taps many times in a row can wedge `coreaudiod`, and
  every tap then blocks in `AudioDeviceCreateIOProcIDWithBlock`. Normal playback
  keeps working, which makes it confusing. Fix: `sudo killall coreaudiod`.

## Licence

MIT, see [LICENSE](LICENSE). snapcast is GPL-3.0 and is *not* bundled here — it
is installed separately via Homebrew and invoked as a separate process. If you
ever redistribute a prebuilt bundle containing snapcast, its licence applies to
what you ship.
