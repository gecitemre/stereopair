// Latency floor probe. Sender taps system audio and ships the right channel
// over raw TCP; receiver plays it through a Core Audio IOProc with a small IO
// buffer. No resampling, no clock sync — the point is to find out what the
// pipeline costs when nothing is added for safety, and to watch whether the two
// machines' audio clocks drift apart once nothing is correcting for it.
//
//   lowlat --recv [--port 4711] [--io-frames 128] [--target-ms 20]
//   lowlat --send <host> [--port 4711]

import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

let sampleRate = 48000

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lowlat: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("lowlat: \(message)\n".utf8))
}

// MARK: - Core Audio helpers

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

/// The IO buffer is the dominant term in playback latency and snapclient's
/// ~100 ms is a software choice, not a hardware limit.
func setIOBufferFrames(_ device: AudioObjectID, _ frames: UInt32) -> UInt32 {
    var value = frames
    var addr = address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput)
    AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    var actual: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &actual)
    return actual
}

// MARK: - Ring buffer

final class Ring: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)

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

    /// Two independent audio clocks drift, and any startup burst lands in the
    /// buffer permanently: without pulling the level back to target, whatever
    /// depth it happens to reach becomes the latency forever.
    func trim(to frames: Int) -> Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        guard h - t > frames else { return 0 }
        tail.store(h - frames, ordering: .releasing)
        return (h - t) - frames
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

// MARK: - Receiver

func runReceiver(port: UInt16, ioFrames: UInt32, targetMs: Int) -> Never {
    let device = defaultOutputDevice()
    guard device != kAudioObjectUnknown else { die("no default output device") }
    let actualIO = setIOBufferFrames(device, ioFrames)
    log("output \(deviceUID(device)) io buffer \(actualIO) frames (\(Double(actualIO) / 48.0) ms)")

    let ring = Ring(frames: 1 << 16)
    let targetFrames = targetMs * sampleRate / 1000

    // Hold playback until the buffer has reached its target once, otherwise the
    // first callbacks underrun and the measurement starts from a false floor.
    let primed = Atomic<Bool>(false)
    let dropped = Atomic<Int>(0)

    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, outputData, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let first = buffers.first else { return }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))

        if !primed.load(ordering: .acquiring) {
            if ring.fill >= targetFrames { primed.store(true, ordering: .releasing) }
            for buffer in buffers {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return
        }

        if ring.fill > targetFrames * 3 {
            dropped.add(ring.trim(to: targetFrames), ordering: .relaxed)
        }

        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
        defer { scratch.deallocate() }
        let got = ring.read(scratch, frames)
        if got < frames {
            scratch.advanced(by: got).update(repeating: 0, count: frames - got)
        }

        for buffer in buffers {
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let bufferChannels = Int(buffer.mNumberChannels)
            for frame in 0 ..< frames {
                let value = Float(scratch[frame]) / 32767
                for channel in 0 ..< bufferChannels {
                    base[frame * bufferChannels + channel] = value
                }
            }
        }
    }
    guard status == noErr else { die("AudioDeviceCreateIOProcIDWithBlock: \(status)") }
    AudioDeviceStart(device, procID)

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

    Thread {
        while true {
            let fill = ring.fill * 1000 / sampleRate
            log("fill \(fill) ms, underruns \(ring.underruns.load(ordering: .relaxed)), trimmed \(dropped.load(ordering: .relaxed))")
            Thread.sleep(forTimeInterval: 2)
        }
    }.start()

    let chunk = 256
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { continue }
        disableNagle(client)
        log("sender connected")
        primed.store(false, ordering: .releasing)
        while readAll(client, buffer, chunk * MemoryLayout<Int16>.size) {
            ring.write(buffer, chunk)
        }
        log("sender disconnected")
        close(client)
    }
}

// MARK: - Sender

/// A tap and its aggregate device outlive the process unless they are destroyed
/// explicitly. Leaked ones accumulate inside coreaudiod and after a handful of
/// runs every AudioDeviceStart blocks forever, which needs `sudo killall
/// coreaudiod` to clear. So tear them down on every exit path, including signals.
nonisolated(unsafe) var liveTap = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var liveAggregate = AudioObjectID(kAudioObjectUnknown)
nonisolated(unsafe) var liveProc: AudioDeviceIOProcID?

func teardown() {
    if let proc = liveProc, liveAggregate != kAudioObjectUnknown {
        AudioDeviceStop(liveAggregate, proc)
        AudioDeviceDestroyIOProcID(liveAggregate, proc)
        liveProc = nil
    }
    if liveAggregate != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(liveAggregate)
        liveAggregate = AudioObjectID(kAudioObjectUnknown)
    }
    if liveTap != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(liveTap)
        liveTap = AudioObjectID(kAudioObjectUnknown)
    }
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

func runSender(host: String, port: UInt16) -> Never {
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
    guard connected == 0 else { die("connect: \(String(cString: strerror(errno)))") }
    disableNagle(fd)
    log("connected to \(host):\(port)")

    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "Lowlat Probe"
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .unmuted

    var tap = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
        die("AudioHardwareCreateProcessTap failed")
    }
    liveTap = tap

    let output = defaultOutputDevice()
    let outputUID = deviceUID(output)
    let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Lowlat Probe",
        kAudioAggregateDeviceUIDKey: "com.emre.lowlat.\(description.uuid.uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: description.uuid.uuidString,
        ]],
    ]
    var device = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
        teardown()
        die("AudioHardwareCreateAggregateDevice failed")
    }
    liveAggregate = device

    let ring = Ring(frames: 1 << 16)
    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, inputData, _, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, first.mDataByteSize > 0,
              let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }

        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: frames)
        defer { scratch.deallocate() }
        // Right channel only; that is what the second Mac plays.
        let offset = channels >= 2 ? 1 : 0
        for frame in 0 ..< frames {
            let value = base[frame * channels + offset]
            scratch[frame] = Int16(max(-1, min(1, value)) * 32767)
        }
        ring.write(scratch, frames)
    }
    guard status == noErr else { teardown(); die("sender IOProc: \(status)") }
    liveProc = procID
    AudioDeviceStart(device, procID)
    log("tapping, sending right channel")

    let chunk = 256
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    while true {
        // Only ever send what the tap actually produced. Padding a short read
        // with silence and sleeping for it sends a full chunk per gap *and* a
        // full chunk per capture, which is exactly twice real time — the
        // receiver then throws half the stream away keeping its buffer at target.
        while ring.fill < chunk {
            usleep(1000)
        }
        _ = ring.read(buffer, chunk)
        guard writeAll(fd, buffer, chunk * MemoryLayout<Int16>.size) else {
            log("receiver gone")
            teardown()
            exit(0)
        }
    }
}

// MARK: - Entry

var mode = ""
var host = ""
var port: UInt16 = 4711
var ioFrames: UInt32 = 128
var targetMs = 20

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--recv": mode = "recv"
    case "--send":
        mode = "send"
        guard let value = args.first else { die("--send needs a host") }
        args.removeFirst()
        host = value
    case "--port":
        port = UInt16(args.removeFirst()) ?? 4711
    case "--io-frames":
        ioFrames = UInt32(args.removeFirst()) ?? 128
    case "--log":
        // Launched via `open`, so stderr has nowhere to go.
        freopen(args.removeFirst(), "a", stderr)
    case "--target-ms":
        targetMs = Int(args.removeFirst()) ?? 20
    default: die("unknown argument \(arg)")
    }
}

switch mode {
case "recv": runReceiver(port: port, ioFrames: ioFrames, targetMs: targetMs)
case "send": runSender(host: host, port: port)
default: die("need --recv or --send <host>")
}
