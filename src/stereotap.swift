import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

// MARK: - Core Audio plumbing

struct CAError: Error, CustomStringConvertible {
    let op: String
    let status: OSStatus
    var description: String { "\(op) failed: \(fourCC(status)) (\(status))" }
}

func fourCC(_ value: some BinaryInteger) -> String {
    let bytes = withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian) { Array($0) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(value)" }
    return String(decoding: bytes, as: UTF8.self)
}

@inline(__always)
func ca(_ op: String, _ body: () -> OSStatus) throws {
    let status = body()
    guard status == noErr else { throw CAError(op: op, status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func getValue<T>(_ object: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 initial: T) throws -> T
{
    var addr = address(selector, scope)
    var out = initial
    var size = UInt32(MemoryLayout<T>.size)
    try ca("get \(fourCC(selector))") {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out)
    }
    return out
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var addr = address(selector)
    var out: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    try ca("get \(fourCC(selector))") {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out)
    }
    guard let string = out as String? else {
        throw CAError(op: "get \(fourCC(selector))", status: kAudioHardwareUnspecifiedError)
    }
    return string
}

func processObject(for pid: pid_t) throws -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var input = pid
    var out = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try ca("translate pid \(pid)") {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), &input, &size, &out)
    }
    return out
}

// MARK: - Ring buffer

/// Single-producer (Core Audio's realtime thread) / single-consumer (the FIFO
/// writer thread) buffer. The realtime callback must never block, so it only
/// ever does pointer arithmetic and one atomic store.
final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)

    init(frames: Int) {
        precondition(frames > 0 && frames & (frames - 1) == 0, "capacity must be a power of two")
        capacity = frames
        mask = frames - 1
        storage = .allocate(capacity: frames * 2)
        storage.initialize(repeating: 0, count: frames * 2)
    }

    @inline(__always)
    private static func toPCM(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * 32767)
    }

    func write(left: UnsafePointer<Float>, leftStride: Int,
               right: UnsafePointer<Float>, rightStride: Int,
               frames: Int)
    {
        let h = head.load(ordering: .relaxed)
        let available = capacity - (h - tail.load(ordering: .acquiring))
        let count = min(frames, available)
        for i in 0 ..< count {
            let slot = ((h + i) & mask) * 2
            storage[slot] = Self.toPCM(left[i * leftStride])
            storage[slot + 1] = Self.toPCM(right[i * rightStride])
        }
        head.store(h + count, ordering: .releasing)
        if count < frames {
            dropped.add(frames - count, ordering: .relaxed)
        }
    }

    /// Frames captured but not yet written. This is latency on top of
    /// snapcast's buffer, so it wants to stay near zero.
    var backlog: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }

    func read(left: UnsafeMutablePointer<Int16>,
              right: UnsafeMutablePointer<Int16>,
              maxFrames: Int) -> Int
    {
        let t = tail.load(ordering: .relaxed)
        let count = min(maxFrames, head.load(ordering: .acquiring) - t)
        for i in 0 ..< count {
            let slot = ((t + i) & mask) * 2
            left[i] = storage[slot]
            right[i] = storage[slot + 1]
        }
        tail.store(t + count, ordering: .releasing)
        return count
    }
}

nonisolated(unsafe) var debugCallbacks = 0

// MARK: - The tap

final class StereoTap {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    let uuid = UUID()

    let format: AudioStreamBasicDescription

    init(excludedPIDs: [pid_t], muteBehavior: CATapMuteBehavior) throws {
        let outputDevice: AudioObjectID = try getValue(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown))
        guard outputDevice != kAudioObjectUnknown else {
            throw CAError(op: "find default output device", status: kAudioHardwareBadObjectError)
        }
        let outputUID = try getString(outputDevice, kAudioDevicePropertyDeviceUID)

        let excluded = try excludedPIDs.map { try processObject(for: $0) }
            .filter { $0 != kAudioObjectUnknown }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Stereo Split"
        description.uuid = uuid
        description.isPrivate = true
        // Tapped apps stop reaching the speakers directly while we are reading,
        // so the local snapclient (excluded above) is the only thing audible.
        description.muteBehavior = muteBehavior

        var tap = AudioObjectID(kAudioObjectUnknown)
        try ca("AudioHardwareCreateProcessTap") {
            AudioHardwareCreateProcessTap(description, &tap)
        }
        tapID = tap

        format = try getValue(tap, kAudioTapPropertyFormat,
                              initial: AudioStreamBasicDescription())

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stereo Split Capture",
            kAudioAggregateDeviceUIDKey: "com.stereo.split.\(uuid.uuidString)",
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
        try ca("AudioHardwareCreateAggregateDevice") {
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        }
        aggregateID = device
    }

    func start(into ring: RingBuffer) throws {
        try ca("AudioDeviceCreateIOProcIDWithBlock") {
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData))
                if debugCallbacks > 0 {
                    debugCallbacks -= 1
                    var report = "stereotap: \(buffers.count) buffer(s)"
                    for (index, buffer) in buffers.enumerated() {
                        var peak: Float = 0
                        if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                            for i in 0 ..< Int(buffer.mDataByteSize) / 4 { peak = max(peak, abs(data[i])) }
                        }
                        report += " [\(index) ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize) peak=\(peak)]"
                    }
                    FileHandle.standardError.write(Data((report + "\n").utf8))
                }
                guard let first = buffers.first, first.mDataByteSize > 0,
                      let base = first.mData?.assumingMemoryBound(to: Float.self)
                else { return }

                if buffers.count >= 2, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    ring.write(left: base, leftStride: 1, right: second, rightStride: 1, frames: frames)
                } else {
                    let channels = Int(first.mNumberChannels)
                    let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
                    if channels >= 2 {
                        ring.write(left: base, leftStride: channels,
                                   right: base + 1, rightStride: channels, frames: frames)
                    } else {
                        ring.write(left: base, leftStride: 1, right: base, rightStride: 1, frames: frames)
                    }
                }
            }
        }
        try ca("AudioDeviceStart") { AudioDeviceStart(aggregateID, ioProcID) }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
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

// MARK: - FIFO output

func openFIFO(_ path: String) throws -> Int32 {
    let fd = open(path, O_WRONLY)
    guard fd >= 0 else {
        throw CAError(op: "open \(path): \(String(cString: strerror(errno)))",
                      status: kAudioHardwareUnspecifiedError)
    }
    return fd
}

func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ bytes: Int) -> Bool {
    var offset = 0
    while offset < bytes {
        let written = write(fd, pointer.advanced(by: offset), bytes - offset)
        if written > 0 {
            offset += written
        } else if written < 0 && errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

/// A process only appears to Core Audio once it actually opens an output
/// device, and snapclient will not do that until audio reaches it — which
/// cannot happen until this process feeds the pipes. So push silence until
/// every PID we mean to exclude resolves; otherwise the exclusion list comes
/// back empty and the tap mutes the very client it is feeding.
func primeUntilExcludable(_ pids: [pid_t], writingTo fds: [Int32],
                          sampleRate: Int, timeout: Double) -> Bool
{
    if pids.isEmpty { return true }

    let resolved = {
        pids.allSatisfy { pid in
            let object = (try? processObject(for: pid)) ?? AudioObjectID(kAudioObjectUnknown)
            return object != AudioObjectID(kAudioObjectUnknown)
        }
    }

    let silence = [Int16](repeating: 0, count: sampleRate / 50) // 20 ms
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if resolved() { return true }
        silence.withUnsafeBytes { raw in
            for fd in fds { _ = writeAll(fd, raw.baseAddress!, raw.count) }
        }
        usleep(20_000)
    }
    return resolved()
}

// MARK: - Entry point

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stereotap: \(message)\n".utf8))
    exit(1)
}

var excludedPIDs: [pid_t] = []
var leftPath: String?
var rightPath: String?
var probeOnly = false
var debugFrames = 0
var muteBehavior = CATapMuteBehavior.mutedWhenTapped

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--debug":
        debugFrames = 5
    case "--log":
        guard let path = arguments.first else { fail("--log needs a path") }
        arguments.removeFirst()
        // The app is launched detached via `open`, so stderr has nowhere to go.
        freopen(path, "a", stderr)
    case "--mute":
        switch arguments.first {
        case "unmuted": muteBehavior = .unmuted
        case "muted": muteBehavior = .muted
        case "when-tapped": muteBehavior = .mutedWhenTapped
        default: fail("--mute needs unmuted|muted|when-tapped")
        }
        arguments.removeFirst()
    case "--probe":
        probeOnly = true
    case "--exclude-pid":
        guard let raw = arguments.first, let pid = pid_t(raw) else { fail("--exclude-pid needs a number") }
        arguments.removeFirst()
        excludedPIDs.append(pid)
    case "--left":
        leftPath = arguments.first
        arguments.removeFirst()
    case "--right":
        rightPath = arguments.first
        arguments.removeFirst()
    default:
        fail("unknown argument \(argument)")
    }
}

debugCallbacks = debugFrames
signal(SIGPIPE, SIG_IGN)

func makeTap() -> StereoTap {
    do {
        return try StereoTap(excludedPIDs: excludedPIDs, muteBehavior: muteBehavior)
    } catch {
        fail("""
        \(error)
          A process tap needs system-audio-recording permission, and it is granted
          to the app that launched this process. Run it as a signed .app via `open`
          so it has its own identity, then allow it under System Settings >
          Privacy & Security > Screen & System Audio Recording.
        """)
    }
}

if probeOnly {
    let probe = makeTap()
    let rate = Int(probe.format.mSampleRate.rounded())
    let channels = probe.format.mChannelsPerFrame
    probe.stop()
    print("\(rate) \(channels)")
    exit(0)
}

guard let leftPath, let rightPath else {
    fail("need --left and --right FIFO paths (or --probe)")
}

let leftFD: Int32
let rightFD: Int32
do {
    leftFD = try openFIFO(leftPath)
    rightFD = try openFIFO(rightPath)
} catch {
    fail("\(error)")
}

if !primeUntilExcludable(excludedPIDs, writingTo: [leftFD, rightFD],
                         sampleRate: 48000, timeout: 20)
{
    FileHandle.standardError.write(Data(
        "stereotap: warning: excluded pid never opened an audio device; it will be muted\n".utf8))
}

let tap = makeTap()
let sampleRate = Int(tap.format.mSampleRate.rounded())

if debugFrames > 0 {
    let reported = (try? getString(tap.tapID, kAudioTapPropertyUID)) ?? "<unavailable>"
    FileHandle.standardError.write(Data("""
    stereotap: description uuid \(tap.uuid.uuidString)
    stereotap: tap uid        \(reported)

    """.utf8))
}

FileHandle.standardError.write(Data("stereotap: tap format \(sampleRate) Hz, \(tap.format.mChannelsPerFrame) ch\n".utf8))

let ring = RingBuffer(frames: 1 << 18)

do {
    try tap.start(into: ring)
} catch {
    tap.stop()
    fail("\(error)")
}

let drainThread = Thread {
    let chunk = 2048
    let left = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    let right = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    var reportedDrops = 0
    var statsCountdown = 0
    while true {
        // Always emit a full chunk, padding with silence when the tap is idle.
        // If the stream is allowed to run dry the clients keep replaying their
        // last buffer until they time out, which sounds like the audio sticking
        // in a loop at the point playback stopped. Writes to the pipe block, so
        // the reader's cadence is what paces this loop.
        let frames = ring.read(left: left, right: right, maxFrames: chunk)
        if frames < chunk {
            // Sleep for the span we are about to invent. Captured audio is
            // paced by the tap, but synthesised silence is not, and a reader
            // that never blocks (a regular file rather than a pipe) would
            // otherwise let this loop spin and write gigabytes per second.
            let missing = chunk - frames
            usleep(useconds_t(missing * 1_000_000 / sampleRate))
            left.advanced(by: frames).update(repeating: 0, count: missing)
            right.advanced(by: frames).update(repeating: 0, count: missing)
        }
        let bytes = chunk * MemoryLayout<Int16>.size
        guard writeAll(leftFD, left, bytes), writeAll(rightFD, right, bytes) else {
            FileHandle.standardError.write(Data("stereotap: downstream closed, stopping\n".utf8))
            tap.stop()
            exit(0)
        }
        let drops = ring.dropped.load(ordering: .relaxed)
        if drops > reportedDrops + sampleRate / 10 {
            reportedDrops = drops
            FileHandle.standardError.write(Data("stereotap: dropped \(drops) frames (downstream too slow)\n".utf8))
        }

        // Backlog here is latency on top of snapcast's buffer, and it is the
        // one part of the delay that can creep up without anything failing.
        statsCountdown -= 1
        if statsCountdown <= 0 {
            statsCountdown = sampleRate * 5 / chunk
            let backlogMs = ring.backlog * 1000 / sampleRate
            FileHandle.standardError.write(Data("stereotap: backlog \(backlogMs) ms\n".utf8))
        }
    }
}
drainThread.qualityOfService = .userInitiated
drainThread.start()

for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        tap.stop()
        exit(0)
    }
    source.resume()
    // Keep the source alive for the life of the process.
    _ = Unmanaged.passRetained(source as AnyObject)
}

dispatchMain()
