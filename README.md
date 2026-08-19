# stereopair

Use two Macs as one stereo pair. The Mac you're working on plays the left
channel, a second Mac plays the right, in sync, from whatever audio is already
playing — browser, YouTube Music, Spotify, anything. Nothing to configure in the
app you're listening to.

The two halves of this exist separately (Airfoil syncs audio to several machines
but [doesn't do stereo pairs](https://rogueamoeba.com/support/manuals/airfoil/?page=usage);
Loopback splits channels but only locally). As far as I can tell, nobody has
shipped the combination on macOS.

> **Vibe-coded.** Built with Claude Code (Opus 5). The latency and buffer
> figures are measured on real hardware, not estimated.

## Use

Put `StereoPair.app` on both Macs and open it on both. On the one you listen
from, click the menu bar item and pick the other Mac under **Play On**.

```
L·R
├─ Play On  ▸  Emre's MacBook Pro (2)
├─ Stop
│  Left: this Mac · Right: Emre's MacBook Pro (2)
├─ Open at Login
└─ Quit
```

That is the whole thing. No terminal, no ssh, no addresses: each copy advertises
itself over Bonjour, so they find each other. Whichever Mac you press Play On
from becomes the left channel.

macOS will ask twice, once per machine: for **system audio recording** on the
sending Mac, and for **local network** on both. Both are required and both fail
silently if refused — see below.

## Build

```bash
./build.sh          # produces bin/StereoPair.app
```

Needs the Xcode command line tools and nothing else: no Homebrew packages, no
runtime dependencies. Copy the built app to the second Mac however you like;
AirDrop is fine.

`build.sh` signs with a **Developer ID Application** certificate if there is one
in the keychain, and falls back to an ad-hoc signature otherwise. Ad-hoc is fine
for your own machines but will not open on anyone else's.

## Releasing

```bash
./release.sh        # signed, notarised, stapled DMG
```

Two one-time prerequisites:

1. A **Developer ID Application** certificate: Xcode → Settings → Accounts →
   your team → Manage Certificates → +. An *Apple Distribution* certificate is a
   different thing and does not work outside the App Store.
2. Notarisation credentials:
   ```bash
   xcrun notarytool store-credentials stereopair \
     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
   ```
   The password is an app-specific one from appleid.apple.com, not your Apple ID
   password.

The App Store is not an option: it requires the sandbox, and there is no
entitlement that lets a sandboxed app create a Core Audio process tap.

## How it works

```
apps (browser, …)
   │  Core Audio process tap, muted at the speakers while tapped
   ▼
StereoPair ──┬── left  channel ─→ this Mac's speakers
             └── right channel ─→ tcp ─→ StereoPair ─→ second Mac
```

Every copy listens and advertises as `_stereopair._tcp`, so either Mac can start
the pair. One connection carries everything — audio, volume and the target — as
framed messages, `[type][length][payload]`. That is why volume mirrors both ways
with nothing running on the other machine: change it on either Mac and the other
follows.

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
| target | **20 ms** | 150 ms, untuned |

A direct Thunderbolt cable between the Macs is worth having: it cuts jitter
~490× and is what makes 20 ms possible. It needs no setup — macOS brings up the
bridge by itself — but it must be a real Thunderbolt/USB4 cable, not a charging
cable.

The link is chosen by trying the addresses the receiver advertises. A Mac
publishes one per interface, and a direct Thunderbolt bridge self-assigns a
`169.254.x` because nothing serves DHCP on it, so those are tried first.

Two details that are easy to get wrong. Discovery has to resolve the advertised
*hostname* rather than trust `NetService`'s own addresses, which only cover the
interface the service happened to be found on — a browse that lands on Wi-Fi
never sees the cable. And "starts with 169.254" does not identify the cable,
because other interfaces carry link-local addresses too and will happily accept
the connection; the sender checks `getsockname` after connecting and prefers the
candidate that actually leaves through the bridge.

**Clock drift is corrected by resampling.** The two machines' audio crystals
differ — measured at **8.3 ppm** on this pair, over 2.7 hours of continuous
audio — so a receiver playing at exactly its own rate walks its buffer to empty
and glitches roughly every 40 minutes. Playback runs at a ratio a few ppm off
1.0, adjusted by a slow loop on the buffer level, bounded to 0.08%: far below
audible pitch change, and slow enough to track drift rather than chase jitter.
Bursts are still discarded outright; the loop only handles slow drift.

An earlier version used snapcast, at 350–500 ms of buffer and ~515 ms end to
end. Its client could not schedule playback sooner than its own ~100 ms
CoreAudio output queue, and that queue was a software choice: the hardware floor
is 15 frames, 0.31 ms.

## Two macOS permissions, both of which fail silently

Both report success and then do nothing, which is why they cost most of the
development time.

**System audio recording**, on the Mac you listen from.
`AudioHardwareCreateProcessTap` succeeds, callbacks fire at the right rate, and
every sample is zero. The permission is charged to the app that *launches* the
process, so running the binary from a terminal charges it to the terminal — the
app runs its audio work as child processes of itself for exactly this reason.

```bash
log show --last 5m --predicate 'process == "coreaudiod"' --style compact | grep -i "not granted"
```

Allow it under Privacy & Security → Screen & System Audio Recording.

**Local network**, on both Macs. Outbound connections are dropped by NECP and
surface as `No route to host`, even though `ping` and `nc` to the same port
succeed — Apple's own binaries are exempt, yours is not. Advertising over
Bonjour needs it too, which plain listening does not.

```bash
log show --last 5m --style compact --info --debug | grep -iE "NECP|local network"
```

Allow it under Privacy & Security → Local Network. If the app never appears in
that list, it has not requested access yet — start it, then reopen Settings.

Note that an ad-hoc signature changes on every build, and macOS treats that as a
new identity: the first connection after a rebuild is refused while it
re-registers, and the next one succeeds.

## Placement

Stereo wants an equilateral triangle: the gap between the machines should be
about the distance from each machine to your head — roughly 60–80 cm at a desk —
with you centred between them. Too close and you have rebuilt one laptop's
speaker spacing with extra latency. Too far and centred content (vocals, bass)
stops forming a phantom centre and collapses into two separate sources. Sitting
off to one side is worse than either.

Be aware that each Mac now plays mono. A MacBook Pro's speaker array is a tuned
stereo system, and feeding it one channel throws that away in exchange for
width. On material without real stereo separation there is nothing to gain.

## Files

| | |
|---|---|
| `src/stereopair.swift` | Tap, split, playback, resampling, discovery, wire protocol |
| `src/menu.swift` | The menu bar app |
| `src/main.swift` | Entry point and modes |
| `build.sh` | Builds and signs the app |

For debugging there are headless modes: `--list` shows what is on the network,
`--send <host>` and `--recv` run one side, `--selftest` reports whether the tap
is actually capturing.

## Not done

- The Wi-Fi target of 150 ms is a guess. Only the Thunderbolt path is measured.
- No notarised build has been produced yet, so nobody can install it without
  building it.
- Nobody but the author has installed it.

## Licence

MIT, see [LICENSE](LICENSE). No third-party code is bundled or required.
