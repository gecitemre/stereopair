// Two Macs as one stereo pair, without snapcast.
//
//   stereopair --send <host> [--port 4711] [--target-ms 20] [--io-frames 128]
//   stereopair --recv          [--port 4711] [--target-ms 20] [--io-frames 128]
//
// The sender taps system audio, plays the left channel through its own output
// and ships the right channel to the receiver. Both sides hold the same target
// buffer before playing, so they stay aligned: the network adds well under a
// millisecond over a Thunderbolt link, which is nothing next to the target.
//
// Clock drift is corrected by resampling. The two machines' audio crystals
// differ — measured at 8.3 ppm here — so a receiver playing back at exactly its
// own rate walks its buffer to empty and glitches every 40 minutes or so.
// Playback runs at a ratio a few ppm off 1.0, adjusted by a slow loop on the
// buffer level, which holds latency at the target indefinitely.

import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

let sampleRate = 48000

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stereopair: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("stereopair: \(message)\n".utf8))
}

// MARK: - Core Audio plumbing

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioObjectID {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    return device
}

func deviceUID(_ device: AudioObjectID) -> String {
    var out: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    var addr = address(kAudioDevicePropertyDeviceUID)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &out)
    return (out as String?) ?? ""
}

/// snapclient's ~100 ms output queue was the largest single term in the old
/// design's latency, and it was a software choice: the hardware goes to 15.
func setIOBufferFrames(_ device: AudioObjectID, _ frames: UInt32) -> UInt32 {
    var value = frames
    var addr = address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput)
    AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    var actual: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &actual)
    return actual
}

func processObject(for pid: pid_t) -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var input = pid
    var out = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                               UInt32(MemoryLayout<pid_t>.size), &input, &size, &out)
    return out
}

// MARK: - Ring buffer

final class Ring: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)
    let trimmed = Atomic<Int>(0)

    init(frames: Int) {
        capacity = frames
        mask = frames - 1
        storage = .allocate(capacity: frames)
        storage.initialize(repeating: 0, count: frames)
    }

    var fill: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }

    func write(_ source: UnsafePointer<Int16>, _ count: Int) {
        let h = head.load(ordering: .relaxed)
        let room = capacity - (h - tail.load(ordering: .acquiring))
        let n = min(count, room)
        for i in 0 ..< n { storage[(h + i) & mask] = source[i] }
        head.store(h + n, ordering: .releasing)
    }

    /// Without pulling the level back, any startup burst or accumulated drift
    /// becomes permanent latency.
    func trim(to frames: Int) {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        guard h - t > frames else { return }
        trimmed.add((h - t) - frames, ordering: .relaxed)
        tail.store(h - frames, ordering: .releasing)
    }

    /// Reads `count` output samples while consuming `count * ratio` input
    /// samples, interpolating between neighbours. Holding the ratio a few ppm
    /// off 1.0 is what lets a receiver track a sender whose audio clock runs at
    /// a slightly different rate; without it the buffer walks to empty and
    /// glitches, measured here at 8.3 ppm, about once every 40 minutes.
    func readResampled(_ destination: UnsafeMutablePointer<Int16>, _ count: Int,
                       ratio: Double, phase: inout Double) -> Bool
    {
        let t = tail.load(ordering: .relaxed)
        let available = head.load(ordering: .acquiring) - t
        // One extra for the interpolation's right-hand neighbour.
        let needed = Int(phase + ratio * Double(count)) + 2
        guard available >= needed else {
            underruns.add(count, ordering: .relaxed)
            return false
        }

        var cursor = phase
        for i in 0 ..< count {
            let index = Int(cursor)
            let fraction = cursor - Double(index)
            let a = Double(storage[(t + index) & mask])
            let b = Double(storage[(t + index + 1) & mask])
            destination[i] = Int16((a + (b - a) * fraction).rounded())
            cursor += ratio
        }

        let consumed = Int(cursor)
        tail.store(t + consumed, ordering: .releasing)
        phase = cursor - Double(consumed)
        return true
    }

    func read(_ destination: UnsafeMutablePointer<Int16>, _ count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let n = min(count, head.load(ordering: .acquiring) - t)
        for i in 0 ..< n { destination[i] = storage[(t + i) & mask] }
        tail.store(t + n, ordering: .releasing)
        if n < count { underruns.add(count - n, ordering: .relaxed) }
        return n
    }
}

// MARK: - Playback

/// Plays a mono ring through the default output, on every channel of the
/// device. Holds silence until the ring first reaches `targetFrames`, so the
/// two machines start from the same depth rather than whatever the first
/// callback happened to find.
final class Player {
    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    let ring = Ring(frames: 1 << 16)

    init(targetFrames: Int, ioFrames: UInt32) {
        device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { die("no default output device") }
        let actual = setIOBufferFrames(device, ioFrames)
        log("output \(deviceUID(device)), io buffer \(actual) frames (\(String(format: "%.2f", Double(actual) / 48.0)) ms)")

        let ring = self.ring
        let primed = Atomic<Bool>(false)
        // Playback rate, nudged towards whatever keeps the buffer at target.
        // Bounded well under a tenth of a percent, far below audible pitch
        // change, and the loop is deliberately slow so it tracks clock drift
        // rather than chasing normal jitter.
        nonisolated(unsafe) var ratio = 1.0
        nonisolated(unsafe) var phase = 0.0

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, outputData, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let first = buffers.first else { return }
            let frames = Int(first.mDataByteSize)
                / (MemoryLayout<Float>.size * max(Int(first.mNumberChannels), 1))

            if !primed.load(ordering: .acquiring) {
                if ring.fill >= targetFrames { primed.store(true, ordering: .releasing) }
                for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                return
            }

            // A burst still needs discarding; the rate loop only handles slow drift.
            if ring.fill > targetFrames * 3 { ring.trim(to: targetFrames) }

            let error = Double(ring.fill - targetFrames) / Double(targetFrames)
            let target = 1.0 + max(-0.0008, min(0.0008, error * 0.0008))
            ratio += (target - ratio) * 0.02

            let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
            defer { scratch.deallocate() }
            if !ring.readResampled(scratch, frames, ratio: ratio, phase: &phase) {
                scratch.update(repeating: 0, count: frames)
            }

            for buffer in buffers {
                guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                for frame in 0 ..< frames {
                    let value = Float(scratch[frame]) / 32767
                    for channel in 0 ..< channels {
                        base[frame * channels + channel] = value
                    }
                }
            }
        }
        guard status == noErr else { die("output IOProc: \(status)") }
        AudioDeviceStart(device, procID)
    }

    func stop() {
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
    }
}

nonisolated(unsafe) var tapLayoutReports = 0

// MARK: - Tap

/// Taps everything except this process. Excluding ourselves matters twice: our
/// own left-channel playback would otherwise be captured straight back into the
/// stream, and `mutedWhenTapped` would silence it at the speakers.
final class Tap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let uuid = UUID()

    init(left: Ring, right: Ring, muteBehavior: CATapMuteBehavior = .mutedWhenTapped) {
        let output = defaultOutputDevice()
        let outputUID = deviceUID(output)

        // Our output IOProc is already running, so this resolves.
        let ourselves = processObject(for: getpid())
        let excluded = ourselves == kAudioObjectUnknown ? [] : [ourselves]
        if excluded.isEmpty { log("warning: could not exclude self from the tap") }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Stereo Pair"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = muteBehavior

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            die("""
            could not create the audio tap.
              Run this as a signed .app via `open` and allow it under System
              Settings > Privacy & Security > Screen & System Audio Recording.
            """)
        }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stereo Pair Capture",
            kAudioAggregateDeviceUIDKey: "com.emre.stereopair.\(uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            destroy()
            die("could not create the capture device")
        }
        aggregateID = device

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, first.mDataByteSize > 0,
                  let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }

            if tapLayoutReports > 0 {
                tapLayoutReports -= 1
                var report = "tap input: \(buffers.count) buffer(s)"
                for (index, buffer) in buffers.enumerated() {
                    var peak: Float = 0
                    if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0 ..< Int(buffer.mDataByteSize) / 4 { peak = max(peak, abs(data[i])) }
                    }
                    report += " [\(index) ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize) peak=\(peak)]"
                }
                log(report)
            }

            @inline(__always) func pcm(_ value: Float) -> Int16 {
                Int16(max(-1, min(1, value)) * 32767)
            }

            if buffers.count >= 2,
               let second = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let l = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                let r = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                defer { l.deallocate(); r.deallocate() }
                for i in 0 ..< frames { l[i] = pcm(base[i]); r[i] = pcm(second[i]) }
                left.write(l, frames)
                right.write(r, frames)
            } else {
                let channels = Int(first.mNumberChannels)
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
                let l = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                let r = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
                defer { l.deallocate(); r.deallocate() }
                for i in 0 ..< frames {
                    l[i] = pcm(base[i * channels])
                    r[i] = pcm(base[i * channels + (channels >= 2 ? 1 : 0)])
                }
                left.write(l, frames)
                right.write(r, frames)
            }
        }
        guard status == noErr else { destroy(); die("tap IOProc: \(status)") }
        AudioDeviceStart(device, procID)
    }

    /// Taps and aggregate devices outlive the process unless destroyed. Leaked
    /// ones pile up inside coreaudiod until every AudioDeviceStart blocks
    /// forever and only `sudo killall coreaudiod` clears it.
    func destroy() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// MARK: - Sockets

func readAll(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ bytes: Int) -> Bool {
    var offset = 0
    while offset < bytes {
        let n = recv(fd, buffer.advanced(by: offset), bytes - offset, 0)
        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

func writeAll(_ fd: Int32, _ buffer: UnsafeRawPointer, _ bytes: Int) -> Bool {
    var offset = 0
    while offset < bytes {
        let n = send(fd, buffer.advanced(by: offset), bytes - offset, 0)
        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

func disableNagle(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
}

// MARK: - Teardown

nonisolated(unsafe) var liveTap: Tap?
nonisolated(unsafe) var livePlayer: Player?

func teardown() {
    liveTap?.destroy()
    liveTap = nil
    livePlayer?.stop()
    livePlayer = nil
}

func installTeardownHandlers() {
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { teardown(); exit(0) }
        source.resume()
        _ = Unmanaged.passRetained(source as AnyObject)
    }
    atexit { teardown() }
}

func startStatsThread(_ label: String, _ ring: Ring) {
    Thread {
        while true {
            Thread.sleep(forTimeInterval: 10)
            log("\(label) buffer \(ring.fill * 1000 / sampleRate) ms, "
                + "underruns \(ring.underruns.load(ordering: .relaxed)), "
                + "trimmed \(ring.trimmed.load(ordering: .relaxed))")
        }
    }.start()
}

// MARK: - Modes

func runSender(host: String, port: UInt16, targetMs: Int, ioFrames: UInt32) -> Never {
    installTeardownHandlers()

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { die("bad host \(host)") }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        die("""
        connect to \(host): \(String(cString: strerror(errno)))
          "No route to host" here usually means macOS blocked the connection.
          Allow this app under System Settings > Privacy & Security > Local Network.
        """)
    }
    disableNagle(fd)
    log("connected to \(host):\(port)")

    let targetFrames = targetMs * sampleRate / 1000

    // Output first, tap second: the tap can only exclude this process once it
    // has an output device open, and being excluded is what keeps our own
    // playback out of the capture.
    let player = Player(targetFrames: targetFrames, ioFrames: ioFrames)
    livePlayer = player
    let outbound = Ring(frames: 1 << 16)
    liveTap = Tap(left: player.ring, right: outbound)
    log("tapping; left here, right to \(host), target \(targetMs) ms")
    startStatsThread("left", player.ring)

    // Send exactly one chunk per chunk-period, against a monotonic deadline.
    // Waiting for a full chunk instead would stop the stream dead whenever
    // nothing is playing — the tap produces nothing during silence — and the
    // receiver would drain, then take a burst when audio resumed. Padding
    // without the deadline is the opposite mistake: a chunk per gap *and* a
    // chunk per capture is twice real time.
    let chunk = 256
    let chunkNanos = UInt64(chunk) * 1_000_000_000 / UInt64(sampleRate)
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    var deadline = DispatchTime.now().uptimeNanoseconds

    while true {
        deadline &+= chunkNanos
        let got = outbound.read(buffer, chunk)
        if got < chunk {
            buffer.advanced(by: got).update(repeating: 0, count: chunk - got)
        }
        guard writeAll(fd, buffer, chunk * MemoryLayout<Int16>.size) else {
            log("receiver gone")
            teardown()
            exit(0)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline > now {
            usleep(useconds_t((deadline - now) / 1000))
        } else {
            deadline = now // fell behind; do not try to catch up in a burst
        }
    }
}

func runReceiver(port: UInt16, targetMs: Int, ioFrames: UInt32) -> Never {
    installTeardownHandlers()

    let targetFrames = targetMs * sampleRate / 1000
    let player = Player(targetFrames: targetFrames, ioFrames: ioFrames)
    livePlayer = player
    startStatsThread("right", player.ring)

    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { die("bind: \(String(cString: strerror(errno)))") }
    listen(listener, 1)
    log("listening on \(port), target \(targetMs) ms")

    let chunk = 256
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { continue }
        disableNagle(client)
        log("sender connected")
        while readAll(client, buffer, chunk * MemoryLayout<Int16>.size) {
            player.ring.write(buffer, chunk)
        }
        log("sender disconnected")
        close(client)
    }
}

/// Creating a tap succeeds even when the permission is denied — it just returns
/// silence — so the only honest check is to capture and look at the samples.
func runSelfTest(seconds: Double) -> Never {
    installTeardownHandlers()
    let left = Ring(frames: 1 << 16)
    let right = Ring(frames: 1 << 16)
    liveTap = Tap(left: left, right: right, muteBehavior: .unmuted)
    Thread.sleep(forTimeInterval: seconds)

    var peak = 0
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 4096)
    defer { scratch.deallocate() }
    for ring in [left, right] {
        while true {
            let got = ring.read(scratch, 4096)
            if got == 0 { break }
            for i in 0 ..< got { peak = max(peak, abs(Int(scratch[i]))) }
        }
    }
    teardown()
    log("captured peak \(peak)")
    exit(0)
}

// MARK: - Entry

var mode = ""
var host = ""
var port: UInt16 = 4711
var targetMs = 20
var ioFrames: UInt32 = 128

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--recv": mode = "recv"
    case "--selftest": mode = "selftest"
    case "--send":
        mode = "send"
        guard let value = args.first else { die("--send needs a host") }
        args.removeFirst()
        host = value
    case "--port": port = UInt16(args.removeFirst()) ?? 4711
    case "--target-ms": targetMs = Int(args.removeFirst()) ?? 20
    case "--io-frames": ioFrames = UInt32(args.removeFirst()) ?? 128
    case "--debug-tap":
        tapLayoutReports = 3
    case "--log":
        // Launched via `open`, so stderr has nowhere to go.
        freopen(args.removeFirst(), "a", stderr)
    default: die("unknown argument \(arg)")
    }
}

signal(SIGPIPE, SIG_IGN)

switch mode {
case "send": runSender(host: host, port: port, targetMs: targetMs, ioFrames: ioFrames)
case "recv": runReceiver(port: port, targetMs: targetMs, ioFrames: ioFrames)
case "selftest": runSelfTest(seconds: 3)
default: die("need --send <host> or --recv")
}
