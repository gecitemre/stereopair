// Two Macs as one stereo pair, without snapcast.
//
//   stereopair --send [host]  [--peer-name <name>]   (finds the receiver if omitted)
//   stereopair --list [--target-ms 20] [--io-frames 128]
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
import Network
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

// MARK: - System volume

/// Read and write the output slider directly. Both machines run the same OS on
/// the same hardware, so the same scalar is the same loudness and no mapping
/// between volume curves is needed.
func systemVolume() -> Float? {
    let device = defaultOutputDevice()
    guard device != kAudioObjectUnknown else { return nil }
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { continue }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return value
        }
    }
    return nil
}

func setSystemVolume(_ level: Float) {
    let device = defaultOutputDevice()
    guard device != kAudioObjectUnknown else { return }
    var value = Float32(max(0, min(1, level)))
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { continue }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
        else { continue }
        AudioObjectSetPropertyData(device, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &value)
    }
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
    func clear() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
        underruns.store(0, ordering: .releasing)
        trimmed.store(0, ordering: .releasing)
    }

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

/// Atomic is non-copyable, so a realtime callback cannot capture one directly.
final class AtomicBool: @unchecked Sendable {
    private let storage = Atomic<Bool>(false)
    init(_ value: Bool) { storage.store(value, ordering: .releasing) }
    var value: Bool {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
}

final class AtomicInt: @unchecked Sendable {
    private let storage = Atomic<Int>(0)
    init(_ value: Int) { storage.store(value, ordering: .releasing) }
    var value: Int {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
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
    /// The sender picks this once it knows which link it got, so the receiver
    /// has to be able to change it after the fact.
    let target = AtomicInt(0)
    private let primedFlag = AtomicBool(false)

    func setTarget(ms: Int) {
        target.value = ms * sampleRate / 1000
    }

    init(targetFrames: Int, ioFrames: UInt32) {
        target.value = targetFrames
        device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { die("no default output device") }
        let actual = setIOBufferFrames(device, ioFrames)
        log("output \(deviceUID(device)), io buffer \(actual) frames (\(String(format: "%.2f", Double(actual) / 48.0)) ms)")

        let ring = self.ring
        let target = self.target
        let primed = primedFlag
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

            let targetFrames = target.value

            if !primed.value {
                if ring.fill >= targetFrames { primed.value = true }
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

    /// The receiver is a login item, so it outlives every sender session and
    /// keeps pulling from an empty ring in between. Without clearing that, the
    /// counters report the idle time as underruns and hide the real ones.
    func reset() {
        ring.clear()
        primedFlag.value = false
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

// MARK: - Wire protocol

// One connection carries both audio and control, so volume can travel with the
// sound instead of needing a second channel or a shell on the other machine.
//   [type: UInt8][length: UInt32 big-endian][payload]
enum Frame: UInt8 {
    case audio = 0      // Int16 mono PCM
    case volume = 1     // Float32 scalar, 0...1
    case target = 2     // UInt32 ms; the sender decides once it knows the link
}

func sendFrame(_ fd: Int32, _ kind: Frame, _ bytes: UnsafeRawPointer, _ count: Int,
               _ lock: NSLock) -> Bool
{
    lock.lock()
    defer { lock.unlock() }
    var header = [UInt8](repeating: 0, count: 5)
    header[0] = kind.rawValue
    let length = UInt32(count).bigEndian
    withUnsafeBytes(of: length) { raw in
        for i in 0 ..< 4 { header[1 + i] = raw[i] }
    }
    return writeAll(fd, header, 5) && (count == 0 || writeAll(fd, bytes, count))
}

func sendVolume(_ fd: Int32, _ level: Float, _ lock: NSLock) -> Bool {
    var value = Float32(level)
    return withUnsafeBytes(of: &value) { raw in
        sendFrame(fd, .volume, raw.baseAddress!, raw.count, lock)
    }
}

/// Reads frames until the connection ends, handing each to the caller.
func readFrames(_ fd: Int32, onAudio: (UnsafePointer<Int16>, Int) -> Void,
                onVolume: (Float) -> Void,
                onTarget: (Int) -> Void = { _ in })
{
    var header = [UInt8](repeating: 0, count: 5)
    var payload = [UInt8](repeating: 0, count: 1 << 16)
    while readAll(fd, &header, 5) {
        let length = (UInt32(header[1]) << 24) | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 8) | UInt32(header[4])
        guard Int(length) <= payload.count else { return }
        guard length == 0 || readAll(fd, &payload, Int(length)) else { return }

        switch Frame(rawValue: header[0]) {
        case .audio:
            payload.withUnsafeBytes { raw in
                let samples = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
                onAudio(samples, Int(length) / MemoryLayout<Int16>.size)
            }
        case .volume:
            let level = payload.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
            onVolume(level)
        case .target:
            let ms = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            onTarget(Int(UInt32(bigEndian: ms)))
        case nil:
            return          // unknown frame type: the stream is no longer trustworthy
        }
    }
}

/// Mirrors the system volume in both directions over the link. Whichever Mac
/// you change wins; the other follows. The quiet period after applying a remote
/// change stops the two bouncing a value back and forth forever.
final class VolumeSync {
    private let fd: Int32
    private let lock: NSLock
    private var lastSeen: Float
    private var quietUntil = Date.distantPast
    private let running = Atomic<Bool>(true)

    init(fd: Int32, lock: NSLock) {
        self.fd = fd
        self.lock = lock
        lastSeen = systemVolume() ?? 0
    }

    func applyRemote(_ level: Float) {
        guard abs(level - (systemVolume() ?? level)) > 0.01 else { return }
        setSystemVolume(level)
        lastSeen = level
        quietUntil = Date().addingTimeInterval(1.0)
    }

    func start() {
        Thread { [self] in
            _ = sendVolume(fd, lastSeen, lock)
            while running.load(ordering: .acquiring) {
                Thread.sleep(forTimeInterval: 0.3)
                guard Date() > quietUntil, let now = systemVolume() else { continue }
                if abs(now - lastSeen) > 0.01 {
                    lastSeen = now
                    _ = sendVolume(fd, now, lock)
                }
            }
        }.start()
    }

    /// The receiver takes a new connection each time the sender restarts, so a
    /// watcher left running would keep writing to a dead socket.
    func stop() { running.store(false, ordering: .releasing) }
}

// MARK: - Discovery

let serviceType = "_stereopair._tcp."

/// The receiver publishes itself so the sender never needs a hostname, an IP or
/// ssh just to find it.
final class Advertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    func start(port: UInt16) {
        let name = Host.current().localizedName ?? "Mac"
        let thread = Thread { [self] in
            let published = NetService(domain: "local.", type: serviceType,
                                       name: name, port: Int32(port))
            published.delegate = self
            published.publish()
            service = published
            RunLoop.current.run()
        }
        thread.name = "advertise"
        thread.start()
    }

    func netServiceDidPublish(_ sender: NetService) {
        log("advertising as \"\(sender.name)\"")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        log("could not advertise: \(errorDict)")
    }
}

struct Peer {
    let name: String
    let addresses: [String]
    let port: Int
}

func ipv4(_ data: Data) -> String? {
    data.withUnsafeBytes { raw -> String? in
        guard let base = raw.baseAddress,
              raw.count >= MemoryLayout<sockaddr>.size,
              base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == sa_family_t(AF_INET)
        else { return nil }
        var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }
}

/// NetService hands back only the address for the interface it happened to be
/// discovered on, but mDNS publishes one per interface. Resolving the advertised
/// hostname instead returns all of them, which is the only way to see the
/// Thunderbolt address when the service was found over Wi-Fi.
func addresses(ofHost host: String) -> [String] {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                         ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
    defer { freeaddrinfo(head) }

    var found: [String] = []
    var node: UnsafeMutablePointer<addrinfo>? = head
    while let current = node {
        if let raw = current.pointee.ai_addr {
            var sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let address = String(cString: text)
            if address != "0.0.0.0" { found.append(address) }
        }
        node = current.pointee.ai_next
    }
    return found
}

final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    func search(timeout: TimeInterval) -> [Peer] {
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
        RunLoop.current.run(until: Date().addingTimeInterval(timeout))
        browser.stop()

        // Read the addresses at the end rather than in the resolve callback. A
        // Mac on both Wi-Fi and a Thunderbolt bridge has an address per
        // interface, they arrive separately, and the callback fires before they
        // are all in — which loses exactly the link worth having.
        return resolving.compactMap { service in
            var found = (service.addresses ?? []).compactMap(ipv4)
            if let host = service.hostName {
                found += addresses(ofHost: host)
            }
            found = Array(Set(found))
            guard !found.isEmpty else { return nil }
            return Peer(name: service.name, addresses: found, port: service.port)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool)
    {
        service.delegate = self
        resolving.append(service)      // must outlive the resolve
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {}
}

/// A direct Thunderbolt link self-assigns 169.254.x addresses because there is
/// no DHCP on it, and that link is the one worth having: two orders of
/// magnitude less jitter than Wi-Fi. So try those first and fall back.
func preferredOrder(_ addresses: [String]) -> [String] {
    addresses.sorted { a, b in
        a.hasPrefix("169.254.") && !b.hasPrefix("169.254.")
    }
}

/// Our own address on the Thunderbolt bridge, if the cable is attached.
func bridgeAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let head = list else { return nil }
    defer { freeifaddrs(head) }

    var node: UnsafeMutablePointer<ifaddrs>? = head
    while let current = node {
        defer { node = current.pointee.ifa_next }
        guard String(cString: current.pointee.ifa_name).hasPrefix("bridge"),
              let raw = current.pointee.ifa_addr,
              raw.pointee.sa_family == sa_family_t(AF_INET)
        else { continue }
        var sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }
    return nil
}

/// Which of our addresses a connected socket is actually using. Two link-local
/// addresses can both accept a connection while only one of them is the cable,
/// and this is the only way to tell them apart from the outside.
func localAddress(of fd: Int32) -> String? {
    var addr = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard ok == 0 else { return nil }
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
    return String(cString: text)
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

func connectTo(_ host: String, _ port: UInt16) -> Int32? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connected == 0 { return fd }
    log("  \(host): \(String(cString: strerror(errno)))")
    close(fd)
    return nil
}

func runSender(host: String, port: UInt16, targetMs: Int, ioFrames: UInt32,
               peerName: String?) -> Never
{
    installTeardownHandlers()

    var candidates: [(String, UInt16)] = []
    if host.isEmpty || host == "auto" {
        log("looking for a receiver…")
        let peers = Discovery().search(timeout: 4)
        let chosen = peerName.map { wanted in peers.filter { $0.name == wanted } } ?? peers
        guard let peer = chosen.first else {
            die("""
            found no receiver on the network.
              Start StereoPair on the other Mac, or pass its address directly.
              If nothing is ever found, allow this app under System Settings >
              Privacy & Security > Local Network.
            """)
        }
        if peers.count > 1 {
            log("found \(peers.count) receivers, using \"\(peer.name)\"")
        } else {
            log("found \"\(peer.name)\"")
        }
        candidates = preferredOrder(peer.addresses).map { ($0, UInt16(peer.port)) }
    } else {
        candidates = [(host, port)]
    }

    // Prefer whichever candidate actually routes over the Thunderbolt bridge,
    // keeping the first that connects as the fallback.
    let ourBridge = bridgeAddress()
    var connection: Int32?
    var reached = ""
    for (address, candidatePort) in candidates {
        guard let fd = connectTo(address, candidatePort) else { continue }
        if let bridge = ourBridge, localAddress(of: fd) == bridge {
            connection.map { close($0) }
            connection = fd
            reached = address
            break
        }
        if connection == nil {
            connection = fd
            reached = address
        } else {
            close(fd)
        }
    }
    guard let fd = connection else {
        die("""
        could not reach the receiver.
          "No route to host" above usually means macOS blocked the connection.
          Allow this app under System Settings > Privacy & Security > Local Network.
        """)
    }
    disableNagle(fd)
    let wired = ourBridge != nil && localAddress(of: fd) == ourBridge
    let link = wired ? "thunderbolt" : "network"

    // Only now is the link known, and it decides the target: 20 ms cannot
    // survive Wi-Fi, whose jitter alone is larger than the whole buffer.
    let negotiated = targetMs > 0 ? targetMs : (wired ? 20 : 150)
    log("connected to \(reached):\(port) over \(link), target \(negotiated) ms")

    let targetFrames = negotiated * sampleRate / 1000

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
    let writeLock = NSLock()
    var announced = UInt32(negotiated).bigEndian
    _ = withUnsafeBytes(of: &announced) {
        sendFrame(fd, .target, $0.baseAddress!, $0.count, writeLock)
    }

    let volumes = VolumeSync(fd: fd, lock: writeLock)
    volumes.start()

    Thread {
        readFrames(fd, onAudio: { _, _ in }, onVolume: { volumes.applyRemote($0) })
        log("receiver gone")
        teardown()
        exit(0)
    }.start()

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
        guard sendFrame(fd, .audio, buffer, chunk * MemoryLayout<Int16>.size, writeLock) else {
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

    let advertiser = Advertiser()
    advertiser.start(port: port)

    while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { continue }
        disableNagle(client)
        log("sender connected")
        player.reset()

        let writeLock = NSLock()
        let volumes = VolumeSync(fd: client, lock: writeLock)
        volumes.start()

        readFrames(client,
                   onAudio: { samples, count in player.ring.write(samples, count) },
                   onVolume: { volumes.applyRemote($0) },
                   onTarget: { ms in
                       log("target set to \(ms) ms by the sender")
                       player.setTarget(ms: ms)
                   })

        volumes.stop()
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

func runList() -> Never {
    let peers = Discovery().search(timeout: 4)
    // log(), not print(): launched via `open` there is nowhere for stdout to go.
    if peers.isEmpty {
        log("no receivers found")
    }
    for peer in peers {
        log("\(peer.name)  \(preferredOrder(peer.addresses).joined(separator: " "))  port \(peer.port)")
    }
    exit(0)
}

// MARK: - Entry

var mode = ""
var host = ""
var port: UInt16 = 4711
var targetMs = 0   // 0 = decide from the link
var ioFrames: UInt32 = 128
var peerName: String?

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--recv": mode = "recv"
    case "--selftest": mode = "selftest"
    case "--send":
        mode = "send"
        // Optional: with no address, or "auto", the receiver is found over Bonjour.
        if let value = args.first, !value.hasPrefix("--") {
            args.removeFirst()
            host = value
        }
    case "--peer-name":
        peerName = args.removeFirst()
    case "--list":
        mode = "list"
    case "--port": port = UInt16(args.removeFirst()) ?? 4711
    case "--target-ms":
        let value = args.removeFirst()
        targetMs = value == "auto" ? 0 : (Int(value) ?? 0)
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
case "send": runSender(host: host, port: port, targetMs: targetMs, ioFrames: ioFrames, peerName: peerName)
case "recv": runReceiver(port: port, targetMs: targetMs > 0 ? targetMs : 150, ioFrames: ioFrames)
case "selftest": runSelfTest(seconds: 3)
case "list": runList()
default: die("need --send [host], --recv, or --list")
}
