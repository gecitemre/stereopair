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
├─ Effects  ▸  Narrow · Normal · Wide
│              Rotate
│              Off · Room · Concert Hall
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

## Latency and sync

| | over Thunderbolt | over Wi-Fi |
|---|---|---|
| ping jitter | 0.06 ms stddev | 28.8 ms stddev, 86 ms worst |
| buffer | **20 ms** | **300 ms** |
| end to end | **~32 ms** | ~310 ms, up to ~600 ms |
| channel offset | ~1 ms | ~1 ms |

A direct Thunderbolt cable is what makes the low figure possible: it cuts jitter
~490×. It needs no setup — macOS brings the bridge up by itself — but it must be
a real Thunderbolt/USB4 cable, not a charging cable. At 32 ms video stays
watchable; at 310 ms it does not, so over Wi-Fi this is for music. The Wi-Fi
figure is a floor, not a fixed number — see the adaptive buffer below. On a bad
link it has settled as high as 600 ms here.

**Playback follows a schedule, not the buffer.** Each chunk carries the time it
should be heard, in the sender's clock. The receiver works out the offset
between the two machines' monotonic clocks by round-tripping readings and
keeping the fastest exchange in a sliding window — the quickest round trip is
the one least distorted by queueing, which is exactly what Wi-Fi does badly. It
then slews towards that estimate at 200 µs per exchange rather than jumping,
because a step in the offset moves the whole schedule and is audible.

Holding a fixed buffer level instead, which is the obvious approach, does not
survive Wi-Fi. Measured with both sides logging: the left channel sat at 149 ms
while the right wandered between 164 and 236 ms, so the speakers were ~70 ms
apart and moving — the stereo image slides around. With scheduling the same link
holds ~1 ms.

Buffer size is a separate matter from sync: it only decides whether the audio
has arrived by the time its schedule comes due. At 150 ms over Wi-Fi the sync
was right and the sound still broke up, which is why the wireless buffer starts
at 300 ms.

**It also adapts.** The receiver watches how much time each chunk has to spare
before it is due. If that margin runs out it takes on extra delay immediately —
the alternative is a dropout — and gives it back at 10 ms per 20 s once the link
has been comfortable for a while. Growing fast and shrinking slowly is
deliberate: reclaimed latency is worth nothing if finding out costs a dropout.

Any extra delay is applied on *both* machines. Delaying only the receiver would
turn a dropout into a channel offset of exactly the amount taken — 302 ms in the
first version of this — and the logged timing error would still read zero,
because it is measured against the shifted schedule. Ears caught that one, not
the numbers.

Errors under 100 ms are corrected by playing fractionally faster or slower,
bounded to 0.08% and inaudible. Past that it steps, with a cooldown: a reconnect
or a machine waking leaves a gap that a 0.08% correction would take minutes to
close, sounding wrong the whole way.

The two machines' audio crystals differ — 8.3 ppm measured here — which the same
mechanism absorbs. Before it existed, a receiver playing at exactly its own rate
walked its buffer to empty and glitched about every 40 minutes.

The link is chosen by trying the addresses the receiver advertises. A Mac
publishes one per interface, and a direct Thunderbolt bridge self-assigns a
`169.254.x` because nothing serves DHCP on it, so those are tried first. That
prefix alone does not identify the cable, though: other interfaces carry
link-local addresses too and will happily accept the connection, so the sender
checks `getsockname` after connecting and prefers the one that actually leaves
through the bridge. Discovery also resolves the advertised *hostname* rather
than trusting `NetService`'s own addresses, which only cover the interface the
service happened to be found on — a browse that lands on Wi-Fi never sees the
cable.

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

## Effects

All optional, all off by default, and all applied on the sending Mac *before*
the channels are split — anything applied to one side alone would be a channel
offset by another name. They can be changed while playing; the settings live in
a small file the sender polls, so they survive a restart and need no live
connection.

**Stereo width** works on mid and side rather than on left and right. Every
stereo signal splits into what the two channels share (the middle — usually
vocals, bass, kick) and what they differ by (the sides). *Narrow* attenuates the
sides and pulls everything towards a single point between the machines; *Wide*
attenuates the middle so what is common recedes and what differs stands out.

Widening cuts the middle rather than boosting the sides on purpose. The first
version did boost the sides and normalised afterwards, which a level test caught
letting out-of-phase material through 23% louder. Since `|mid| + |side|` is
exactly the larger of the two input samples, attenuating either one puts a hard
ceiling on the output. The cost is that *Wide* is about 4 dB quieter on centred
material — that is what widening means, and reaching for the volume knob to
compensate defeats it.

**Rotate** is the "8D audio" effect: a slow constant-power pan, one turn every
twelve seconds. Be aware that the illusion of sound orbiting your head is a
headphone effect and depends on your ears being isolated from each other; on two
speakers it reads as movement from side to side. It never closes a channel down
by more than 90%, because full travel silences a laptop once a cycle and that
reads as a fault rather than an effect.

**Reverb** is a Schroeder reverb in the Freeverb arrangement — eight comb
filters in parallel into four allpasses in series, per channel, with the right
channel's delays offset so the two sides decorrelate. Room size is only how much
each comb feeds back, so both rooms share one set of buffers and switching
allocates nothing.

Unlike width and rotation, reverb cannot promise never to raise the level: it
adds energy, which is what it is for. A comb filter resonates, and a note
sustained on one of those resonances measured **7× the input** — 17 dB, arriving
gradually, which is the shape of thing that hurts. So the output passes through
a soft limiter: everything below 0.8 is untouched (with reverb off the signal is
unchanged to the bit), and above that the excess bends into the last fifth.
Swept from 20 Hz to 4 kHz the worst case is now 1.000.

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

- Nobody but the author has installed it, on the author's two machines and one
  Wi-Fi network.
- The buffer sizes itself from the worst chunk it has seen, so a single 260 ms
  straggler buys permanent latency, and it is released at 10 ms per 20 s — ten
  minutes to give back 300 ms.
- Wi-Fi still drops the occasional burst. Rarer than it was, not gone.

## Licence

MIT, see [LICENSE](LICENSE). No third-party code is bundled or required.
